import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _original = RecoveryAudioVersion(
  id: 'original',
  label: '原始备份',
  sha256: 'original-sha',
  sizeBytes: 4096,
);
const _current = RecoveryAudioVersion(
  id: 'current',
  label: '当前文件',
  sha256: 'current-sha',
  sizeBytes: 8192,
);
const _preserved = RecoveryAudioVersion(
  id: 'preserved-uuid',
  label: '先前保留版本',
  sha256: 'earlier-sha',
  sizeBytes: 2048,
);

OriginalRecoveryState _state({
  bool canRestore = true,
  bool canFinish = false,
}) => OriginalRecoveryState(
  status: 'opaque-native-status',
  targetUri: 'content://media/external/audio/media/7',
  canRestore: canRestore,
  canFinish: canFinish,
  versions: const [_original, _current, _preserved],
);

class _RecoveryExporter
    implements AudioCopyExporter, AudioExportRecovery, AudioOriginalRecovery {
  OriginalRecoveryState? state = _state();
  int checks = 0;
  int restores = 0;
  int finishes = 0;
  int acknowledgements = 0;
  final exported = <String>[];
  PlatformException? restoreError;
  static const notice = '恢复记录仍然保留，请核对版本。';

  @override
  bool supports(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => null;
  @override
  Future<String?> recoverInterruptedExport() async =>
      state == null ? null : notice;
  @override
  Future<void> acknowledgeExportRecovery() async {
    acknowledgements++;
  }

  @override
  Future<void> confirmExportRecorded(String uri) async {}
  @override
  Future<OriginalRecoveryState?> getOriginalRecoveryState() async => state;
  @override
  Future<String?> retryOriginalRecovery() async {
    checks++;
    return notice;
  }

  @override
  Future<String?> restoreOriginalBackup() async {
    restores++;
    if (restoreError != null) throw restoreError!;
    return notice;
  }

  @override
  Future<String?> exportOriginalRecoveryVersion(String versionId) async {
    exported.add(versionId);
    final previous = state!;
    state = OriginalRecoveryState(
      status: previous.status,
      targetUri: previous.targetUri,
      canRestore: previous.canRestore,
      canFinish: true,
      versions: previous.versions
          .map(
            (version) => version.id != versionId
                ? version
                : RecoveryAudioVersion(
                    id: version.id,
                    label: version.label,
                    sha256: version.sha256,
                    sizeBytes: version.sizeBytes,
                    exportedUri: 'content://exports/$versionId',
                  ),
          )
          .toList(),
    );
    return 'content://exports/$versionId';
  }

  @override
  Future<void> finishOriginalRecovery() async {
    finishes++;
    state = null;
  }
}

Future<LibraryController> _openRecovery(
  WidgetTester tester,
  _RecoveryExporter exporter, {
  bool largeText = false,
}) async {
  tester.view.physicalSize = largeText
      ? const Size(320, 740)
      : const Size(900, 1100);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = largeText ? 2 : 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final controller = LibraryController(
    store: MemoryStore(),
    picker: FakePicker(),
    importer: FakeImporter(),
    completion: CompletionService(),
    exporter: exporter,
  );
  await tester.pumpWidget(AudioFixerApp(controller: controller));
  await tester.pumpAndSettle();
  await tester.tap(find.text('恢复提醒 · 查看说明'));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'structured recovery recheck never restores and exports opaque retained versions',
    (tester) async {
      final exporter = _RecoveryExporter();
      await _openRecovery(tester, exporter);
      expect(find.text('已查看保存结果'), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('finish-original-recovery')),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('结束恢复前，请先导出'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('retry-original-recovery')));
      expect(exporter.checks, 1);
      expect(exporter.restores, 0);
      expect(exporter.acknowledgements, 0);
      for (final id in ['original', 'current', 'preserved-uuid']) {
        await _tap(tester, find.byKey(ValueKey('export-recovery-$id')));
      }
      expect(exporter.exported, ['original', 'current', 'preserved-uuid']);
      expect(find.text('content://exports/preserved-uuid'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restoring a conflicting file needs explicit confirmation and cancellation preserves state',
    (tester) async {
      final exporter = _RecoveryExporter();
      await _openRecovery(tester, exporter);
      await _tap(tester, find.byKey(const ValueKey('restore-original-backup')));
      expect(find.text('恢复原始备份并替换当前文件？'), findsOneWidget);
      expect(find.textContaining('当前文件可能已被其他应用更换。继续后会先单独保留'), findsOneWidget);
      expect(exporter.restores, 0);
      await _tap(tester, find.text('取消'));
      expect(exporter.restores, 0);
      expect(exporter.state, isNotNull);
      await _tap(tester, find.byKey(const ValueKey('restore-original-backup')));
      await _tap(
        tester,
        find.byKey(const ValueKey('confirm-restore-original')),
      );
      expect(exporter.restores, 1);
      expect(exporter.finishes, 0);
      expect(find.text('原文件恢复'), findsOneWidget);
      expect(exporter.state!.versions, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'permission failure retains recovery and no generic acknowledgement can discard it',
    (tester) async {
      final exporter = _RecoveryExporter()
        ..restoreError = PlatformException(
          code: 'original_recovery_required',
          message: '未取得授权，所有版本继续保留。',
        );
      await _openRecovery(tester, exporter);
      await _tap(tester, find.byKey(const ValueKey('restore-original-backup')));
      await _tap(
        tester,
        find.byKey(const ValueKey('confirm-restore-original')),
      );
      expect(exporter.state, isNotNull);
      expect(find.text('原文件恢复'), findsOneWidget);
      expect(find.text(_RecoveryExporter.notice), findsOneWidget);
      expect(find.text('已查看保存结果'), findsNothing);
      expect(exporter.acknowledgements, 0);
      expect(exporter.finishes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'finishing recovery separately confirms irreversible internal-backup cleanup',
    (tester) async {
      final exporter = _RecoveryExporter()..state = _state(canFinish: true);
      await _openRecovery(tester, exporter);
      await _tap(
        tester,
        find.byKey(const ValueKey('finish-original-recovery')),
      );
      expect(find.textContaining('当前文件不会更改'), findsOneWidget);
      expect(find.textContaining('无法撤销'), findsOneWidget);
      await _tap(tester, find.text('继续保留备份'));
      expect(exporter.finishes, 0);
      expect(exporter.state, isNotNull);
      await _tap(
        tester,
        find.byKey(const ValueKey('finish-original-recovery')),
      );
      await _tap(tester, find.byKey(const ValueKey('confirm-finish-recovery')));
      expect(exporter.finishes, 1);
      expect(exporter.state, isNull);
      expect(find.text('恢复提醒 · 查看说明'), findsNothing);
      expect(exporter.restores, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text recovery retains available decisions and version exports',
    (tester) async {
      final exporter = _RecoveryExporter()..state = _state(canRestore: false);
      await _openRecovery(tester, exporter, largeText: true);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('restore-original-backup')),
            )
            .onPressed,
        isNull,
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('export-recovery-preserved-uuid')),
      );
      expect(exporter.exported, ['preserved-uuid']);
      await _tap(tester, find.text('稍后决定'));
      expect(exporter.state, isNotNull);
      expect(exporter.restores, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
