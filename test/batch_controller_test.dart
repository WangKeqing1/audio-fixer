import 'dart:async';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _lyrics = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'Synthetic reviewed lyrics',
  source: 'Offline fixture',
);
const _album = FieldSuggestion(
  field: AudioField.album,
  value: 'Synthetic reviewed album',
  source: 'Offline fixture',
);

CompletionTask _review(String id) => CompletionTask(
  trackId: id,
  trackTitle: 'Song $id',
  createdAt: DateTime(2026, 1, 1),
  status: TaskStatus.needsReview,
  message: 'Synthetic candidates need explicit review.',
  suggestions: const [_lyrics, _album],
);

class _Writer
    implements AudioCopyExporter, AudioOriginalSaver, AudioBatchExporter {
  final originals = <String>[];
  final copies = <String>[];
  final directoryCopies = <String>[];
  final selected = <String, List<FieldSuggestion>>{};
  final failIds = <String>{};
  final unsupportedIds = <String>{};
  String? directory = 'content://fixture/chosen-directory';
  final usedDirectories = <String>[];
  int directoryChoices = 0;
  String? pauseId;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  bool supports(AudioTrack track) => !unsupportedIds.contains(track.id);

  @override
  bool supportsOriginal(AudioTrack track) => supports(track);

  Future<String?> _write(
    AudioTrack track,
    List<FieldSuggestion> values,
    List<String> calls,
    String prefix,
  ) async {
    calls.add(track.id);
    selected[track.id] = List.of(values);
    if (track.id == pauseId) {
      if (!started.isCompleted) started.complete();
      await release.future;
    }
    if (failIds.contains(track.id)) {
      throw ExportException('Synthetic failure for ${track.id}');
    }
    return '$prefix/${track.id}';
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) => _write(track, selected, originals, 'content://fixture/original');

  @override
  Future<String?> export(AudioTrack track, List<FieldSuggestion> selected) =>
      _write(track, selected, copies, 'content://fixture/copy');

  @override
  Future<String?> chooseExportDirectory() async {
    directoryChoices++;
    return directory;
  }

  @override
  Future<String?> exportToDirectory(
    AudioTrack track,
    List<FieldSuggestion> selected,
    String directoryUri,
  ) {
    usedDirectories.add(directoryUri);
    return _write(track, selected, directoryCopies, '$directoryUri/copy');
  }
}

class _BatchPermissionWriter extends _Writer
    implements AudioBatchOriginalSaver {
  final authorizationRequests = <List<String>>[];
  final events = <String>[];
  bool permissionGranted = true;
  bool waitForPermission = false;
  final permissionRequested = Completer<void>();
  final permissionResponse = Completer<void>();

  @override
  Future<bool> authorizeOriginalWrites(List<AudioTrack> tracks) async {
    final ids = tracks.map((track) => track.id).toList();
    authorizationRequests.add(ids);
    events.add('authorize:${ids.join(',')}');
    if (!permissionRequested.isCompleted) permissionRequested.complete();
    if (waitForPermission) await permissionResponse.future;
    return permissionGranted;
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) {
    events.add('save:${track.id}');
    return super.saveOriginal(track, selected);
  }
}

class _Source implements MetadataSource {
  final calls = <String>[];
  final failIds = <String>{};

  @override
  String get name => 'Offline fixture';

  @override
  Set<AudioField> get supportedFields => {AudioField.lyrics};

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    calls.add(track.id);
    if (failIds.contains(track.id)) {
      throw StateError('Synthetic source failure');
    }
    return const [_lyrics];
  }
}

class _FailFirstOriginalRecordStore extends MemoryStore {
  _FailFirstOriginalRecordStore(super.snapshot);
  bool failNextSavedOriginalRecord = true;

  @override
  Future<void> save(LibrarySnapshot value) async {
    if (failNextSavedOriginalRecord &&
        value.tasks.any((task) => task.status == TaskStatus.savedOriginal)) {
      failNextSavedOriginalRecord = false;
      throw StateError(
        'Synthetic catalog failure after verified original save',
      );
    }
    await super.save(value);
  }
}

Future<LibraryController> _controller(
  _Writer writer, {
  List<String> ids = const ['a', 'b', 'c'],
  bool reviewTasks = true,
  _Source? source,
  MemoryStore? store,
}) async {
  final controller = LibraryController(
    store:
        store ??
        MemoryStore(
          LibrarySnapshot(
            tracks: ids
                .map((id) => fixtureTrack(id: id, title: 'Song $id'))
                .toList(),
            tasks: reviewTasks ? ids.map(_review).toList() : [],
            settings: const AppSettings(metadata: false, artwork: false),
          ),
        ),
    picker: FakePicker(),
    importer: FakeImporter(),
    completion: CompletionService(sources: [?source]),
    exporter: writer,
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

Future<void> _approveAll(LibraryController controller) async {
  for (final task in controller.tasks.toList()) {
    expect(await controller.approveCandidates(task, const [_lyrics]), isTrue);
  }
  controller.selectTracks(controller.tracks.map((track) => track.id));
}

Map<String, String> _statuses(LibraryController controller) => {
  for (final item in controller.batchOperation!.items)
    item.trackId: item.status.name,
};

void main() {
  test('selection adds valid IDs and keeps songs hidden by another filter', () async {
    final controller = await _controller(_Writer());
    controller.toggleTrackSelection('a');
    controller.selectTracks(['b', 'missing']);
    // A UI filter supplies only its visible IDs; prior selections must remain.
    controller.selectTracks(['c']);
    expect(controller.selectedTrackIds, {'a', 'b', 'c'});
    expect(controller.selectedCount, 3);
    controller.toggleTrackSelection('missing');
    expect(controller.selectedCount, 3);
    controller.toggleTrackSelection('b');
    expect(controller.selectedTrackIds, {'a', 'c'});
    controller.clearSelection();
    expect(controller.selectedTrackIds, isEmpty);
    expect(controller.selectedCount, 0);
  });

  test(
    'selected identify processes only requested songs and never writes',
    () async {
      final writer = _Writer();
      final source = _Source();
      final controller = await _controller(
        writer,
        source: source,
        reviewTasks: false,
      );
      await controller.complete(trackIds: {'a', 'c', 'missing'});
      expect(source.calls, ['a', 'c']);
      expect(
        controller.tasks.map((task) => task.trackId),
        unorderedEquals(['a', 'c']),
      );
      expect(
        controller.tasks.every((task) => task.status == TaskStatus.needsReview),
        isTrue,
      );
      expect(
        controller.tasks.every((task) => task.approvedSuggestions.isEmpty),
        isTrue,
      );
      expect(controller.batchOperation!.kind.name, 'identify');
      expect(_statuses(controller), {'a': 'needsReview', 'c': 'needsReview'});
      expect(writer.originals, isEmpty);
      expect(writer.copies, isEmpty);
    },
  );

  test(
    'identify continues after one song fails and retry targets only failure',
    () async {
      final source = _Source()..failIds.add('b');
      final controller = await _controller(
        _Writer(),
        source: source,
        reviewTasks: false,
      );
      await controller.complete(trackIds: {'a', 'b', 'c'});
      expect(source.calls, ['a', 'b', 'c']);
      expect(_statuses(controller), {
        'a': 'needsReview',
        'b': 'failed',
        'c': 'needsReview',
      });
      expect(controller.hasRetryableBatchFailures, isTrue);
      source.failIds.clear();
      await controller.retryFailedBatch();
      expect(source.calls, ['a', 'b', 'c', 'b']);
      expect(controller.hasRetryableBatchFailures, isFalse);
      expect(_statuses(controller)['b'], 'needsReview');
    },
  );

  test(
    'approval records only explicitly selected fields without writing',
    () async {
      final writer = _Writer();
      final controller = await _controller(writer, ids: ['a']);
      final task = controller.tasks.single;
      expect(controller.approvedSuggestionsFor(task), isEmpty);
      expect(await controller.approveCandidates(task, const [_lyrics]), isTrue);
      final approved = controller.tasks.single;
      expect(approved.status, TaskStatus.readyToSave);
      expect(approved.approvedSuggestions.map((item) => item.field), [
        AudioField.lyrics,
      ]);
      expect(
        controller.approvedSuggestionsFor(approved).map((item) => item.value),
        [_lyrics.value],
      );
      expect(writer.originals, isEmpty);
      expect(writer.copies, isEmpty);
      controller.selectTracks(['a']);
      await controller.saveSelectedCandidates();
      expect(writer.originals, ['a']);
      expect(writer.selected['a']!.map((item) => item.field), [
        AudioField.lyrics,
      ]);
    },
  );

  test('batch save cannot silently approve review candidates', () async {
    final writer = _Writer();
    final controller = await _controller(writer);
    controller.selectTracks(['a', 'b', 'c']);
    await controller.saveSelectedCandidates();
    expect(writer.originals, isEmpty);
    expect(writer.copies, isEmpty);
    expect(writer.directoryChoices, 0);
    expect(
      controller.tasks.every((task) => task.approvedSuggestions.isEmpty),
      isTrue,
    );
    expect(
      controller.tasks.every((task) => task.status == TaskStatus.needsReview),
      isTrue,
    );
  });

  test('original is default save and copy status remains distinct', () async {
    final writer = _Writer();
    final controller = await _controller(writer, ids: ['a', 'b']);
    expect(
      await controller.saveCandidates(controller.taskForTrack('a')!, const [
        _lyrics,
      ]),
      isTrue,
    );
    expect(writer.originals, ['a']);
    expect(writer.copies, isEmpty);
    expect(controller.taskForTrack('a')!.status, TaskStatus.savedOriginal);
    expect(controller.taskForTrack('a')!.exportedCopyUri, isNull);
    expect(controller.trackById('a')!.lyrics, _lyrics.value);
    expect(
      await controller.exportCandidates(controller.taskForTrack('b')!, const [
        _lyrics,
      ]),
      isTrue,
    );
    expect(writer.copies, ['b']);
    expect(controller.taskForTrack('b')!.status, TaskStatus.exported);
    expect(controller.taskForTrack('b')!.exportedCopyUri, contains('/copy/b'));
    expect(controller.trackById('b')!.lyrics, isNull);
  });

  test('one save failure does not block later songs; retry never repeats successes', () async {
    final writer = _Writer()..failIds.add('b');
    final controller = await _controller(writer);
    await _approveAll(controller);
    await controller.saveSelectedCandidates();
    expect(writer.originals, ['a', 'b', 'c']);
    expect(_statuses(controller), {
      'a': 'savedOriginal',
      'b': 'failed',
      'c': 'savedOriginal',
    });
    expect(controller.taskForTrack('b')!.writeError, isNotNull);
    expect(controller.hasRetryableBatchFailures, isTrue);
    expect(controller.batchOperation!.isRunning, isFalse);
    writer.failIds.clear();
    await controller.retryFailedBatch();
    expect(writer.originals, ['a', 'b', 'c', 'b']);
    expect(controller.hasRetryableBatchFailures, isFalse);
    expect(controller.taskForTrack('b')!.status, TaskStatus.savedOriginal);
    expect(controller.taskForTrack('b')!.writeError, isNull);
  });

  test(
    'stop waits for current save then cancels every remaining song',
    () async {
      final writer = _Writer()..pauseId = 'a';
      final controller = await _controller(writer);
      await _approveAll(controller);
      final work = controller.saveSelectedCandidates();
      await writer.started.future.timeout(const Duration(seconds: 5));
      expect(controller.batchOperation!.isRunning, isTrue);
      controller.stopBatch();
      expect(controller.batchOperation!.stopRequested, isTrue);
      expect(writer.originals, ['a']);
      writer.release.complete();
      await work;
      expect(writer.originals, ['a']);
      expect(_statuses(controller), {
        'a': 'savedOriginal',
        'b': 'cancelled',
        'c': 'cancelled',
      });
      expect(controller.batchOperation!.isRunning, isFalse);
      expect(controller.hasRetryableBatchFailures, isFalse);
      expect(controller.isBusy, isFalse);
    },
  );

  test('batch exports ask for one directory and preserve originals', () async {
    final writer = _Writer();
    final controller = await _controller(writer);
    await _approveAll(controller);
    await controller.saveSelectedCandidates(exportCopies: true);
    expect(writer.directoryChoices, 1);
    expect(writer.directoryCopies, ['a', 'b', 'c']);
    expect(writer.usedDirectories, everyElement(writer.directory));
    expect(writer.copies, isEmpty);
    expect(writer.originals, isEmpty);
    expect(controller.batchOperation!.kind.name, 'exportCopies');
    expect(_statuses(controller), {
      'a': 'exported',
      'b': 'exported',
      'c': 'exported',
    });
    expect(controller.tracks.every((track) => track.lyrics == null), isTrue);
  });

  test(
    'cancelled batch destination creates no output and keeps approvals',
    () async {
      final writer = _Writer()..directory = null;
      final controller = await _controller(writer);
      await _approveAll(controller);
      await controller.saveSelectedCandidates(exportCopies: true);
      expect(writer.directoryChoices, 1);
      expect(writer.directoryCopies, isEmpty);
      expect(writer.copies, isEmpty);
      expect(writer.originals, isEmpty);
      expect(
        controller.tasks.every((task) => task.status == TaskStatus.readyToSave),
        isTrue,
      );
      expect(
        controller.tasks.every((task) => task.approvedSuggestions.length == 1),
        isTrue,
      );
      expect(controller.isBusy, isFalse);
      expect(controller.batchOperation!.isRunning, isFalse);
    },
  );

  test(
    'empty, modified, duplicate-field and stale approvals cannot write',
    () async {
      final writer = _Writer();
      final controller = await _controller(writer, ids: ['a']);
      final task = controller.tasks.single;
      expect(await controller.approveCandidates(task, []), isFalse);
      const altered = FieldSuggestion(
        field: AudioField.lyrics,
        value: 'Unreviewed replacement',
        source: 'Offline fixture',
      );
      expect(
        await controller.approveCandidates(task, const [altered]),
        isFalse,
      );
      expect(
        await controller.approveCandidates(task, const [_lyrics, _lyrics]),
        isFalse,
      );
      final stale = CompletionTask(
        trackId: 'a',
        trackTitle: 'Song a',
        createdAt: DateTime(2025),
        status: TaskStatus.needsReview,
        message: '',
        suggestions: const [_lyrics],
      );
      expect(
        await controller.approveCandidates(stale, const [_lyrics]),
        isFalse,
      );
      expect(await controller.saveCandidates(stale, const [_lyrics]), isFalse);
      expect(await controller.saveCandidates(task, const [altered]), isFalse);
      expect(writer.originals, isEmpty);
      expect(writer.copies, isEmpty);
    },
  );

  test(
    'query replacement revokes prior approval and stale task cannot save',
    () async {
      final writer = _Writer();
      final controller = await _controller(
        writer,
        source: _Source(),
        ids: ['a'],
      );
      final old = controller.tasks.single;
      expect(await controller.approveCandidates(old, const [_lyrics]), isTrue);
      await controller.complete(track: controller.tracks.single);
      expect(controller.tasks.single.status, TaskStatus.needsReview);
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(controller.approvedSuggestionsFor(old), isEmpty);
      expect(await controller.saveCandidates(old, const [_lyrics]), isFalse);
      controller.selectTracks(['a']);
      await controller.saveSelectedCandidates();
      expect(writer.originals, isEmpty);
    },
  );

  test(
    'device changes revoke explicit approval before any batch save',
    () async {
      final device = fixtureDeviceTrack(id: 'a');
      final readDevice = device.withDetails(
        title: device.title,
        artist: device.artist,
        album: null,
        year: null,
        durationMs: 60000,
        lyrics: null,
        artworkPath: null,
      );
      final library = FakeDeviceLibrary()..songs = [device];
      final writer = _Writer();
      final controller = LibraryController(
        store: MemoryStore(
          LibrarySnapshot(tracks: [readDevice], tasks: [_review(device.id)]),
        ),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(),
        deviceLibrary: library,
        exporter: writer,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final old = controller.tasks.single;
      expect(await controller.approveCandidates(old, const [_lyrics]), isTrue);
      controller.selectTracks([device.id]);
      library.songs = [fixtureDeviceTrack(id: 'a', modified: 2000)];
      await controller.refreshLibrary();
      expect(controller.tasks.single.status, TaskStatus.outdated);
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(controller.approvedSuggestionsFor(old), isEmpty);
      await controller.saveSelectedCandidates();
      expect(writer.originals, isEmpty);
      expect(await controller.saveCandidates(old, const [_lyrics]), isFalse);
      expect(writer.originals, isEmpty);
    },
  );

  test('verified original is never written again after task-record failure', () async {
    final store = _FailFirstOriginalRecordStore(
      LibrarySnapshot(
        tracks: ['a', 'b'].map((id) => fixtureTrack(id: id)).toList(),
        tasks: ['a', 'b'].map(_review).toList(),
      ),
    );
    final writer = _Writer();
    final controller = await _controller(writer, store: store);
    await _approveAll(controller);
    await controller.saveSelectedCandidates();
    expect(writer.originals, ['a']);
    expect(_statuses(controller), {'a': 'savedOriginal', 'b': 'cancelled'});
    expect(controller.hasRetryableBatchFailures, isFalse);
    await controller.retryFailedBatch();
    expect(writer.originals, ['a']);
    // Even an explicit subsequent batch must recognize the already-saved source
    // instead of trusting a stale ready-to-save task left by catalog failure.
    await controller.saveSelectedCandidates();
    expect(writer.originals.where((id) => id == 'a'), hasLength(1));
    expect(writer.originals, ['a', 'b']);
    expect(controller.taskForTrack('a')!.status, TaskStatus.savedOriginal);
    expect(controller.taskForTrack('a')!.approvedSuggestions, isEmpty);
  });

  test('single source save reports success despite catalog failure without allowing a duplicate', () async {
    final store = _FailFirstOriginalRecordStore(
      LibrarySnapshot(
        tracks: [fixtureTrack(id: 'a')],
        tasks: [_review('a')],
      ),
    );
    final writer = _Writer();
    final controller = await _controller(writer, store: store);
    final reviewed = controller.tasks.single;
    expect(await controller.saveCandidates(reviewed, const [_lyrics]), isTrue);
    expect(writer.originals, ['a']);
    expect(controller.notice, contains('原文件已保存'));
    expect(controller.notice, contains('任务记录保存失败'));
    expect(controller.tasks.single.status, TaskStatus.savedOriginal);
    expect(await controller.saveCandidates(reviewed, const [_lyrics]), isFalse);
    expect(writer.originals, ['a']);
  });

  group('batch original permission', () {
    test('one permission preparation precedes every original write', () async {
      final writer = _BatchPermissionWriter();
      final controller = await _controller(writer);
      await _approveAll(controller);
      await controller.saveSelectedCandidates();
      expect(writer.authorizationRequests, [
        ['a', 'b', 'c'],
      ]);
      expect(writer.events, ['authorize:a,b,c', 'save:a', 'save:b', 'save:c']);
      expect(writer.originals, ['a', 'b', 'c']);
      expect(controller.batchOperation!.savedOriginalCount, 3);
    });

    test(
      'permission includes only selected approved supported originals',
      () async {
        final writer = _BatchPermissionWriter()..unsupportedIds.add('c');
        final controller = await _controller(writer, ids: ['a', 'b', 'c', 'd']);
        for (final id in ['a', 'c', 'd']) {
          expect(
            await controller.approveCandidates(
              controller.taskForTrack(id)!,
              const [_lyrics],
            ),
            isTrue,
          );
        }
        controller.selectTracks(['a', 'b', 'c']);
        await controller.saveSelectedCandidates();
        expect(writer.authorizationRequests, [
          ['a'],
        ]);
        expect(writer.originals, ['a']);
        expect(_statuses(controller), {
          'a': 'savedOriginal',
          'b': 'skipped',
          'c': 'skipped',
        });
        expect(controller.taskForTrack('b')!.status, TaskStatus.needsReview);
        expect(controller.taskForTrack('d')!.status, TaskStatus.readyToSave);
      },
    );

    test(
      'declining batch permission cancels all without touching any original',
      () async {
        final writer = _BatchPermissionWriter()..permissionGranted = false;
        final controller = await _controller(writer);
        await _approveAll(controller);
        await controller.saveSelectedCandidates();
        expect(writer.authorizationRequests, [
          ['a', 'b', 'c'],
        ]);
        expect(writer.originals, isEmpty);
        expect(writer.copies, isEmpty);
        expect(writer.directoryCopies, isEmpty);
        expect(_statuses(controller), {
          'a': 'cancelled',
          'b': 'cancelled',
          'c': 'cancelled',
        });
        expect(controller.batchOperation!.isRunning, isFalse);
        expect(controller.batchOperation!.cancelledCount, 3);
        expect(
          controller.tasks.every(
            (task) => task.status == TaskStatus.readyToSave,
          ),
          isTrue,
        );
        expect(
          controller.tasks.every(
            (task) => task.approvedSuggestions.length == 1,
          ),
          isTrue,
        );
        expect(controller.isBusy, isFalse);
      },
    );

    test('copy export never requests original-write permission', () async {
      final writer = _BatchPermissionWriter();
      final controller = await _controller(writer);
      await _approveAll(controller);
      await controller.saveSelectedCandidates(exportCopies: true);
      expect(writer.authorizationRequests, isEmpty);
      expect(writer.originals, isEmpty);
      expect(writer.directoryChoices, 1);
      expect(writer.directoryCopies, ['a', 'b', 'c']);
      expect(controller.batchOperation!.exportedCount, 3);
    });

    test('no eligible originals means no permission request', () async {
      final writer = _BatchPermissionWriter()..unsupportedIds.add('a');
      final controller = await _controller(writer, ids: ['a', 'b']);
      expect(
        await controller.approveCandidates(
          controller.taskForTrack('a')!,
          const [_lyrics],
        ),
        isTrue,
      );
      controller.selectTracks(['a', 'b']);
      await controller.saveSelectedCandidates();
      expect(writer.authorizationRequests, isEmpty);
      expect(writer.originals, isEmpty);
      expect(_statuses(controller), {'a': 'skipped', 'b': 'skipped'});
    });

    test(
      'stopping during permission preparation prevents all later writes',
      () async {
        final writer = _BatchPermissionWriter()..waitForPermission = true;
        final controller = await _controller(writer);
        await _approveAll(controller);
        final work = controller.saveSelectedCandidates();
        await writer.permissionRequested.future.timeout(
          const Duration(seconds: 5),
        );
        expect(writer.originals, isEmpty);
        controller.stopBatch();
        writer.permissionResponse.complete();
        await work;
        expect(writer.authorizationRequests, hasLength(1));
        expect(writer.originals, isEmpty);
        expect(controller.batchOperation!.cancelledCount, 3);
        expect(controller.batchOperation!.isRunning, isFalse);
      },
    );
  });
}
