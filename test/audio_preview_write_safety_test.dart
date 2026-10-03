import 'dart:async';

import 'package:audio_fixer/app/app_shell.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_preview_service.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _candidate = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'Explicitly reviewed synthetic lyrics',
  source: 'Offline fixture',
);

class _Backend implements AudioPreviewBackend {
  final updates = StreamController<AudioPreviewEvent>.broadcast(sync: true);
  final calls = <String>[];
  Completer<void>? release;
  bool failStop = false;

  @override
  Stream<AudioPreviewEvent> get events => updates.stream;
  @override
  Future<AudioPreviewEvent?> getState() async => null;
  @override
  Future<void> play({
    required int requestId,
    required String trackId,
    required String uri,
  }) async {
    calls.add('play:$trackId');
    updates.add(
      AudioPreviewEvent(
        requestId: requestId,
        trackId: trackId,
        status: AudioPreviewStatus.playing,
        durationMs: 90000,
      ),
    );
  }

  @override
  Future<void> pause({required int requestId}) async {}
  @override
  Future<void> seek({required int requestId, required int positionMs}) async {}
  @override
  Future<void> stop() async {
    calls.add('stop');
    if (failStop) throw PlatformException(code: 'release_failed');
    await release?.future;
    calls.add('released');
  }
}

class _Writer
    implements
        AudioCopyExporter,
        AudioOriginalSaver,
        AudioBatchOriginalSaver,
        AudioExportRecovery,
        AudioOriginalRecovery {
  final calls = <String>[];
  Completer<void>? writeRelease;
  final writeStarted = Completer<void>();
  OriginalRecoveryState? recoveryState;

  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<bool> authorizeOriginalWrites(List<AudioTrack> tracks) async {
    calls.add('authorize');
    return true;
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) => _write('original');
  @override
  Future<String?> export(AudioTrack track, List<FieldSuggestion> selected) =>
      _write('copy');
  Future<String?> _write(String type) async {
    calls.add(type);
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeRelease?.future;
    return 'content://fixture/$type';
  }

  @override
  Future<String?> recoverInterruptedExport() async {
    calls.add('recover');
    return null;
  }

  @override
  Future<void> acknowledgeExportRecovery() async {}
  @override
  Future<void> confirmExportRecorded(String uri) async {}
  @override
  Future<OriginalRecoveryState?> getOriginalRecoveryState() async =>
      recoveryState;
  @override
  Future<String?> retryOriginalRecovery() async {
    calls.add('retry');
    return null;
  }

  @override
  Future<String?> restoreOriginalBackup() async {
    calls.add('restore');
    return null;
  }

  @override
  Future<String?> exportOriginalRecoveryVersion(String versionId) async {
    calls.add('recovery-copy');
    return null;
  }

  @override
  Future<void> finishOriginalRecovery() async {
    calls.add('finish');
  }
}

void main() {
  late _Backend backend;
  late AudioPreviewController preview;
  late _Writer writer;
  late LibraryController controller;
  late CompletionTask task;
  late AudioTrack track;

  setUp(() async {
    backend = _Backend();
    preview = AudioPreviewController(backend: backend);
    writer = _Writer();
    track = fixtureTrack();
    task = CompletionTask(
      trackId: track.id,
      trackTitle: track.displayTitle,
      createdAt: DateTime(2026),
      status: TaskStatus.needsReview,
      message: 'Synthetic review',
      suggestions: const [_candidate],
    );
    controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [track], tasks: [task])),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
      exporter: writer,
      preview: preview,
    );
    await controller.initialize();
    writer.calls.clear();
    await preview.play(track);
  });
  tearDown(() async {
    backend.failStop = false;
    if (backend.release case final pending?) {
      if (!pending.isCompleted) pending.complete();
    }
    if (writer.writeRelease case final pending?) {
      if (!pending.isCompleted) pending.complete();
    }
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    await backend.updates.close();
  });

  for (final copy in [false, true]) {
    test(
      '${copy ? 'copy' : 'original'} write awaits release and blocks new playback throughout',
      () async {
        backend.release = Completer<void>();
        writer.writeRelease = Completer<void>();
        final saved = copy
            ? controller.exportCandidates(task, [_candidate])
            : controller.saveCandidates(task, [_candidate]);
        expect(preview.isBlocked, isTrue);
        expect(preview.track, isNull);
        await Future<void>.delayed(Duration.zero);
        expect(writer.calls, isEmpty);
        await preview.play(fixtureTrack(id: 'other'));
        expect(backend.calls, ['play:fixture', 'stop']);
        backend.release!.complete();
        await writer.writeStarted.future;
        expect(backend.calls.last, 'released');
        expect(preview.isBlocked, isTrue);
        await preview.play(track);
        expect(
          backend.calls.where((value) => value.startsWith('play:')),
          hasLength(1),
        );
        writer.writeRelease!.complete();
        expect(await saved, isTrue);
        expect(preview.isBlocked, isFalse);
        expect(preview.track, isNull);
      },
    );
  }

  test(
    'failed release prevents every writer call and a safe retry works',
    () async {
      backend.failStop = true;
      expect(await controller.saveCandidates(task, [_candidate]), isFalse);
      expect(writer.calls, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.needsReview);
      expect(preview.isBlocked, isFalse);
      expect(controller.notice, contains('试听'));
      backend.failStop = false;
      expect(await controller.saveCandidates(task, [_candidate]), isTrue);
      expect(backend.calls.where((value) => value == 'stop'), hasLength(2));
      expect(writer.calls, contains('original'));
    },
  );

  test(
    'batch cannot ask write permission until preview has released',
    () async {
      await controller.approveCandidates(task, [_candidate]);
      controller.selectTracks([track.id]);
      backend.release = Completer<void>();
      final saving = controller.saveSelectedCandidates();
      await Future<void>.delayed(Duration.zero);
      expect(writer.calls, isEmpty);
      expect(preview.isBlocked, isTrue);
      backend.release!.complete();
      await saving;
      expect(writer.calls, containsAllInOrder(['authorize', 'original']));
      expect(preview.isBlocked, isFalse);
    },
  );

  test(
    'refresh rollback waits for release and retains nested lock discipline',
    () async {
      backend.release = Completer<void>();
      final refreshing = controller.refreshLibrary();
      await Future<void>.delayed(Duration.zero);
      expect(writer.calls, isEmpty);
      expect(preview.isBlocked, isTrue);
      backend.release!.complete();
      await refreshing;
      expect(writer.calls, ['recover']);
      expect(preview.isBlocked, isFalse);
    },
  );

  test(
    'restore, retry, and recovery export all reject uncertain player release',
    () async {
      writer.recoveryState = const OriginalRecoveryState(
        status: 'conflict',
        targetUri: 'content://fixture/original',
        canRestore: true,
        canFinish: false,
        versions: [],
      );
      await controller.refreshLibrary();
      writer.calls.clear();
      await preview.play(track);
      backend.failStop = true;
      await controller.restoreOriginalBackup();
      await controller.retryOriginalRecovery();
      await controller.exportOriginalRecoveryVersion('original');
      expect(writer.calls, isEmpty);
      expect(preview.isBlocked, isFalse);
      expect(controller.originalRecoveryState?.canRestore, isTrue);
      backend.failStop = false;
      await controller.restoreOriginalBackup();
      expect(writer.calls, contains('restore'));
      expect(preview.isBlocked, isFalse);
    },
  );

  test('selection and metadata query do not stop active preview', () async {
    controller.toggleTrackSelection(track.id);
    await controller.complete(trackIds: {track.id});
    expect(controller.selectedTrackIds, {track.id});
    expect(backend.calls, ['play:fixture']);
    expect(preview.isPlaying, isTrue);
  });

  testWidgets('leaving library tab stops preview without clearing selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    controller.selectTracks([track.id]);
    await tester.pumpWidget(
      MaterialApp(home: AppShell(controller: controller)),
    );
    await tester.pump();
    expect(preview.isPlaying, isTrue);
    await tester.tap(find.widgetWithText(NavigationDestination, '设置'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(preview.track, isNull);
    expect(backend.calls, containsAllInOrder(['stop', 'released']));
    expect(controller.selectedTrackIds, {track.id});
    await tester.tap(find.widgetWithText(NavigationDestination, '音乐库'));
    await tester.pumpAndSettle();
    expect(
      backend.calls.where((value) => value.startsWith('play:')),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('background stops preview and foreground never auto-resumes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: AppShell(controller: controller)),
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(preview.track, isNull);
    expect(backend.calls, contains('released'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      backend.calls.where((value) => value.startsWith('play:')),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
