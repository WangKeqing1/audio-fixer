import 'dart:io';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _RecoverableExporter implements AudioCopyExporter, AudioExportRecovery {
  String? recovery;
  bool failRecovery = false;
  bool failConfirmation = false;
  int exports = 0;
  int acknowledgements = 0;
  final confirmed = <String>[];
  void Function()? onConfirm;
  @override
  bool supports(AudioTrack track) => true;
  @override
  Future<String?> export(AudioTrack track, List<FieldSuggestion> values) async {
    exports++;
    return 'content://test/new-copy';
  }

  @override
  Future<String?> recoverInterruptedExport() async {
    if (failRecovery) throw const FileSystemException('storage unavailable');
    return recovery;
  }

  @override
  Future<void> acknowledgeExportRecovery() async {
    acknowledgements++;
    recovery = null;
  }

  @override
  Future<void> confirmExportRecorded(String uri) async {
    onConfirm?.call();
    if (failConfirmation) {
      throw const FileSystemException('storage unavailable');
    }
    confirmed.add(uri);
  }
}

const _candidate = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'reviewed lyrics',
  source: 'Fixture',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryStore store;
  late LibraryController controller;
  late _RecoverableExporter exporter;
  late CompletionTask task;
  var appOwnsController = false;
  setUp(() {
    appOwnsController = false;
    task = CompletionTask(
      trackId: 'fixture',
      trackTitle: 'Fixture',
      createdAt: DateTime(2026),
      status: TaskStatus.needsReview,
      message: 'Review',
      suggestions: const [_candidate],
    );
    store = MemoryStore(
      LibrarySnapshot(tracks: [fixtureTrack()], tasks: [task]),
    );
    exporter = _RecoverableExporter();
    controller = LibraryController(
      store: store,
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
      exporter: exporter,
    );
  });
  tearDown(() {
    if (!appOwnsController) controller.dispose();
  });

  test(
    'startup recovery persists notice without inventing task success',
    () async {
      exporter.recovery = '上次副本已保存，任务记录可能尚未更新。';
      await controller.initialize();
      expect(controller.recoveryNotice, exporter.recovery);
      expect(controller.tasks.single.status, TaskStatus.needsReview);
      expect(controller.tasks.single.exportedCopyUri, isNull);
      expect(controller.tracks.single.lyrics, isNull);
      await controller.refreshLibrary();
      expect(controller.recoveryNotice, exporter.recovery);
      await controller.acknowledgeExportRecovery();
      expect(controller.recoveryNotice, isNull);
      expect(exporter.acknowledgements, 1);
    },
  );

  test('resume refresh observes a late orphan-picker notice', () async {
    await controller.initialize();
    expect(controller.recoveryNotice, isNull);
    exporter.recovery = '未完成的新副本已移除，请重新导出。';
    await controller.refreshLibrary();
    expect(controller.recoveryNotice, exporter.recovery);
    expect(controller.tasks.single.status, TaskStatus.needsReview);
  });

  test('native journal acknowledged only after durable task save', () async {
    await controller.initialize();
    exporter.onConfirm = () {
      expect(store.snapshot.tasks.single.status, TaskStatus.exported);
      expect(
        store.snapshot.tasks.single.exportedCopyUri,
        'content://test/new-copy',
      );
    };
    expect(await controller.exportCandidates(task, [_candidate]), isTrue);
    expect(exporter.confirmed, ['content://test/new-copy']);
  });

  test('failed task persistence leaves native journal recoverable', () async {
    await controller.initialize();
    store.failSave = true;
    expect(await controller.exportCandidates(task, [_candidate]), isTrue);
    expect(exporter.confirmed, isEmpty);
    expect(controller.notice, contains('副本已保存'));
    expect(controller.tasks.single.status, TaskStatus.needsReview);
  });

  test('failed native acknowledgement preserves saved success', () async {
    await controller.initialize();
    exporter.failConfirmation = true;
    expect(await controller.exportCandidates(task, [_candidate]), isTrue);
    expect(controller.tasks.single.status, TaskStatus.exported);
    expect(controller.notice, contains('已导出校验通过'));
  });

  test(
    'unreadable journal blocks new export but leaves catalog browsable',
    () async {
      exporter.failRecovery = true;
      await controller.initialize();
      expect(controller.loadError, isNull);
      expect(controller.recoveryNotice, contains('无法检查'));
      expect(await controller.exportCandidates(task, [_candidate]), isFalse);
      expect(exporter.exports, 0);
    },
  );

  test(
    'acknowledging export warning preserves catalog recovery notice',
    () async {
      store.snapshot = LibrarySnapshot(
        tracks: [fixtureTrack()],
        tasks: [task],
        recoveredFromBackup: true,
      );
      exporter.recovery = '导出中断';
      await controller.initialize();
      await controller.acknowledgeExportRecovery();
      expect(controller.exportRecoveryNotice, isNull);
      expect(controller.recoveryNotice, contains('已恢复本地目录'));
      expect(store.snapshot.recoveredFromBackup, isTrue);
    },
  );

  testWidgets('recovery notice remains visible until explicit acknowledgement', (
    tester,
  ) async {
    appOwnsController = true;
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    exporter.recovery =
        '上次保存中断，原音频未修改。保存位置：content://documents/${List.filled(20, 'long-audio-location').join('/')}';
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复提醒 · 查看说明'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.text(exporter.recovery!), findsWidgets);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(controller.exportRecoveryNotice, isNotNull);
    await tester.tap(find.text('恢复提醒 · 查看说明'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已查看保存结果'));
    await tester.pumpAndSettle();
    expect(find.text('恢复提醒 · 查看说明'), findsNothing);
    expect(exporter.acknowledgements, 1);
    expect(tester.takeException(), isNull);
  });

  test('optional recovery protocol uses exact channel and URI', () async {
    const channel = MethodChannel('test/export-recovery');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'recoverExport' ? 'interrupted' : null;
        });
    final native = SafeAudioCopyExporter(
      () async => Directory.systemTemp,
      channel: channel,
    );
    expect(await native.recoverInterruptedExport(), 'interrupted');
    await native.confirmExportRecorded('content://test/verified-copy');
    await native.acknowledgeExportRecovery();
    expect(calls.map((call) => call.method), [
      'recoverExport',
      'confirmExportRecorded',
      'acknowledgeExportRecovery',
    ]);
    expect(calls[1].arguments, {'uri': 'content://test/verified-copy'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
