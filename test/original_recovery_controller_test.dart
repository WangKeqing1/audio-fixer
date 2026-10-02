import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _targetUri = 'content://fixture/audio/original';
const _unknownCurrentWarning =
    'Synthetic recovery: current bytes differ from the retained original and prepared output.';
const _original = RecoveryAudioVersion(
  id: 'original',
  label: 'Synthetic original backup',
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  sizeBytes: 1024,
);
const _current = RecoveryAudioVersion(
  id: 'retained-current',
  label: 'Synthetic current version',
  sha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  sizeBytes: 2048,
);
const _candidate = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'Synthetic explicitly approved lyrics',
  source: 'Offline fixture',
);

OriginalRecoveryState _recoveryState({
  String status = 'conflict',
  bool canRestore = true,
  bool canFinish = false,
  List<RecoveryAudioVersion> versions = const [_original, _current],
}) => OriginalRecoveryState(
  status: status,
  targetUri: _targetUri,
  canRestore: canRestore,
  canFinish: canFinish,
  versions: versions,
);

class _RecoveryExporter
    implements AudioCopyExporter, AudioExportRecovery, AudioOriginalRecovery {
  OriginalRecoveryState? state = _recoveryState();
  String? warning = _unknownCurrentWarning;
  OriginalRecoveryState? stateAfterRestore = _recoveryState(
    status: 'restored',
    canRestore: false,
  );
  String? exportResult;
  bool failRetry = false;
  bool failRestore = false;
  bool failExport = false;
  bool failFinish = false;
  bool failStateRead = false;
  int recoveryChecks = 0;
  int stateReads = 0;
  int permissionRechecks = 0;
  int restores = 0;
  int finishes = 0;
  int acknowledgements = 0;
  int regularExports = 0;
  final exportedVersionIds = <String>[];
  final confirmedUris = <String>[];

  @override
  bool supports(AudioTrack track) => true;

  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    regularExports++;
    return 'content://fixture/regular-copy';
  }

  @override
  Future<String?> recoverInterruptedExport() async {
    recoveryChecks++;
    return warning;
  }

  @override
  Future<OriginalRecoveryState?> getOriginalRecoveryState() async {
    stateReads++;
    if (failStateRead) {
      throw PlatformException(
        code: 'recovery_unavailable',
        message: 'Synthetic recovery state is unavailable',
      );
    }
    return state;
  }

  @override
  Future<String?> retryOriginalRecovery() async {
    permissionRechecks++;
    if (failRetry) {
      throw PlatformException(
        code: 'permission_denied',
        message: 'Synthetic recovery permission denied',
      );
    }
    return warning;
  }

  @override
  Future<String?> restoreOriginalBackup() async {
    restores++;
    if (failRestore) {
      throw PlatformException(
        code: 'restore_failed',
        message: 'Synthetic original restore failed; retained versions remain',
      );
    }
    state = stateAfterRestore;
    warning =
        'Synthetic original restored; retained versions still need review.';
    return warning;
  }

  @override
  Future<String?> exportOriginalRecoveryVersion(String versionId) async {
    exportedVersionIds.add(versionId);
    if (failExport) {
      throw PlatformException(
        code: 'recovery_export_failed',
        message: 'Synthetic version export failed',
      );
    }
    final uri = exportResult;
    final currentState = state;
    if (uri != null && currentState != null) {
      final versions = currentState.versions
          .map(
            (version) => RecoveryAudioVersion(
              id: version.id,
              label: version.label,
              sha256: version.sha256,
              sizeBytes: version.sizeBytes,
              exportedUri: version.id == versionId ? uri : version.exportedUri,
            ),
          )
          .toList();
      state = OriginalRecoveryState(
        status: currentState.status,
        targetUri: currentState.targetUri,
        canRestore: currentState.canRestore,
        canFinish: versions.every((version) => version.exportedUri != null),
        versions: versions,
      );
    }
    return uri;
  }

  @override
  Future<void> finishOriginalRecovery() async {
    finishes++;
    if (failFinish) {
      throw PlatformException(
        code: 'recovery_unfinished',
        message: 'Synthetic retained versions still need export',
      );
    }
    state = null;
    warning = null;
  }

  @override
  Future<void> acknowledgeExportRecovery() async {
    acknowledgements++;
  }

  @override
  Future<void> confirmExportRecorded(String uri) async {
    confirmedUris.add(uri);
  }
}

AudioTrack _track(String id, String uri) => AudioTrack(
  id: id,
  fileName: '$id.mp3',
  contentUri: uri,
  sizeBytes: 1024,
  importedAt: DateTime.utc(2026),
  title: 'Synthetic $id',
  artist: 'Synthetic artist',
);

CompletionTask _approvedTask(AudioTrack track) => CompletionTask(
  trackId: track.id,
  trackTitle: track.displayTitle,
  createdAt: DateTime.utc(2026),
  status: TaskStatus.readyToSave,
  message: 'Synthetic explicit approval',
  suggestions: const [_candidate],
  approvedSuggestions: const [_candidate],
);

Future<LibraryController> _open(_RecoveryExporter exporter) async {
  final tracks = [
    _track('target', _targetUri),
    _track('unrelated', 'content://fixture/audio/unrelated'),
  ];
  final controller = LibraryController(
    store: MemoryStore(
      LibrarySnapshot(
        tracks: tracks,
        tasks: tracks.map(_approvedTask).toList(),
      ),
    ),
    picker: FakePicker(),
    importer: FakeImporter(),
    completion: CompletionService(),
    exporter: exporter,
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

void main() {
  test(
    'startup, refresh and permission retry never invoke destructive restore',
    () async {
      final exporter = _RecoveryExporter();
      final controller = await _open(exporter);
      expect(controller.originalRecoveryState!.status, 'conflict');
      expect(controller.recoveryNotice, _unknownCurrentWarning);
      expect(exporter.restores, 0);

      await controller.refreshLibrary();
      await controller.retryOriginalRecovery();

      expect(exporter.recoveryChecks, 3);
      expect(exporter.stateReads, 3);
      expect(exporter.permissionRechecks, 1);
      expect(exporter.restores, 0);
      expect(exporter.finishes, 0);
      expect(exporter.acknowledgements, 0);
      expect(exporter.exportedVersionIds, isEmpty);
      expect(exporter.regularExports, 0);
      expect(controller.originalRecoveryState!.targetUri, _targetUri);
      expect(
        controller.originalRecoveryState!.versions.map(
          (version) => version.sha256,
        ),
        [_original.sha256, _current.sha256],
      );
      expect(controller.recoveryNotice, _unknownCurrentWarning);
      expect(
        controller.tasks.every(
          (task) => task.status != TaskStatus.savedOriginal,
        ),
        isTrue,
      );
    },
  );

  test('missing recovery state blocks restore, export and finish', () async {
    final exporter = _RecoveryExporter()
      ..state = null
      ..warning = null;
    final controller = await _open(exporter);
    await controller.restoreOriginalBackup();
    await controller.exportOriginalRecoveryVersion('original');
    await controller.finishOriginalRecovery();
    expect(exporter.restores, 0);
    expect(exporter.finishes, 0);
    expect(exporter.exportedVersionIds, isEmpty);
    expect(controller.originalRecoveryState, isNull);
  });

  test(
    'backend flags block restore and finish regardless of notice wording',
    () async {
      final exporter = _RecoveryExporter()
        ..state = _recoveryState(canRestore: false, canFinish: false)
        ..warning =
            'Synthetic: 恢复原始备份 / 完成恢复 are descriptions, not authorization.';
      final controller = await _open(exporter);
      await controller.restoreOriginalBackup();
      await controller.finishOriginalRecovery();
      expect(exporter.restores, 0);
      expect(exporter.finishes, 0);
      expect(controller.originalRecoveryState!.versions, hasLength(2));
      expect(controller.recoveryNotice, exporter.warning);
    },
  );

  test('explicit restore refreshes state and revokes only target candidate approval', () async {
    final exporter = _RecoveryExporter()
      ..state = _recoveryState(versions: const [_original]);
    final controller = await _open(exporter);
    final targetApproval = controller.taskForTrack('target')!;
    expect(controller.approvedSuggestionsFor(targetApproval), hasLength(1));
    final readsBefore = exporter.stateReads;

    await controller.restoreOriginalBackup();

    expect(exporter.restores, 1);
    expect(exporter.stateReads, greaterThan(readsBefore));
    expect(controller.originalRecoveryState!.status, 'restored');
    expect(controller.originalRecoveryState!.canRestore, isFalse);
    expect(
      controller.originalRecoveryState!.versions.map((version) => version.id),
      ['original', 'retained-current'],
    );
    expect(controller.taskForTrack('target')!.status, TaskStatus.outdated);
    expect(controller.taskForTrack('target')!.approvedSuggestions, isEmpty);
    expect(controller.approvedSuggestionsFor(targetApproval), isEmpty);
    expect(
      controller.taskForTrack('unrelated')!.status,
      TaskStatus.readyToSave,
    );
    expect(
      controller.taskForTrack('unrelated')!.approvedSuggestions,
      hasLength(1),
    );
    expect(controller.recoveryNotice, exporter.warning);
    expect(exporter.finishes, 0);
    expect(exporter.acknowledgements, 0);
  });

  test(
    'failed restore retains recovery notice, versions and actionable state',
    () async {
      final exporter = _RecoveryExporter()..failRestore = true;
      final controller = await _open(exporter);
      await controller.restoreOriginalBackup();
      expect(exporter.restores, 1);
      expect(controller.originalRecoveryState!.status, 'conflict');
      expect(
        controller.originalRecoveryState!.versions.map((version) => version.id),
        ['original', 'retained-current'],
      );
      expect(controller.recoveryNotice, _unknownCurrentWarning);
      expect(controller.notice, contains('restore failed'));
      expect(controller.isBusy, isFalse);
      expect(exporter.finishes, 0);
      expect(exporter.acknowledgements, 0);
    },
  );

  test(
    'denied permission retry retains recovery evidence and never restores',
    () async {
      final exporter = _RecoveryExporter()..failRetry = true;
      final controller = await _open(exporter);
      await controller.retryOriginalRecovery();
      expect(exporter.permissionRechecks, 1);
      expect(exporter.restores, 0);
      expect(controller.recoveryNotice, _unknownCurrentWarning);
      expect(controller.originalRecoveryState!.versions, hasLength(2));
      expect(controller.notice, contains('permission denied'));
      expect(controller.isBusy, isFalse);
    },
  );

  test(
    'cancelled retained-version export preserves versions and does not finish',
    () async {
      final exporter = _RecoveryExporter();
      final controller = await _open(exporter);
      final before = controller.originalRecoveryState!.versions;
      final readsBefore = exporter.stateReads;
      await controller.exportOriginalRecoveryVersion('retained-current');
      expect(exporter.exportedVersionIds, ['retained-current']);
      expect(exporter.stateReads, greaterThan(readsBefore));
      expect(controller.originalRecoveryState!.versions, before);
      expect(
        controller.originalRecoveryState!.versions.every(
          (version) => version.exportedUri == null,
        ),
        isTrue,
      );
      expect(controller.recoveryNotice, _unknownCurrentWarning);
      expect(controller.notice, contains('已取消导出'));
      expect(exporter.finishes, 0);
      expect(exporter.restores, 0);
      expect(exporter.acknowledgements, 0);
    },
  );

  test(
    'successful version export refreshes receipt without silently finishing',
    () async {
      final exporter = _RecoveryExporter()
        ..state = _recoveryState(versions: const [_original])
        ..exportResult = 'content://fixture/recovery-export/original.mp3';
      final controller = await _open(exporter);
      await controller.exportOriginalRecoveryVersion('original');
      expect(
        controller.originalRecoveryState!.versions.single.exportedUri,
        exporter.exportResult,
      );
      expect(controller.originalRecoveryState!.canFinish, isTrue);
      expect(controller.recoveryNotice, _unknownCurrentWarning);
      expect(exporter.finishes, 0);
      expect(exporter.restores, 0);
    },
  );

  test(
    'failed retained-version export leaves recovery evidence intact',
    () async {
      final exporter = _RecoveryExporter()..failExport = true;
      final controller = await _open(exporter);
      await controller.exportOriginalRecoveryVersion('original');
      expect(exporter.exportedVersionIds, ['original']);
      expect(controller.originalRecoveryState!.versions, hasLength(2));
      expect(
        controller.originalRecoveryState!.versions.first.exportedUri,
        isNull,
      );
      expect(controller.recoveryNotice, _unknownCurrentWarning);
      expect(controller.notice, contains('version export failed'));
      expect(exporter.finishes, 0);
    },
  );

  test('finish trusts backend flag instead of inferring safety from export receipts', () async {
    final exporter = _RecoveryExporter()
      ..state = _recoveryState(
        canRestore: false,
        canFinish: false,
        versions: const [
          RecoveryAudioVersion(
            id: 'original',
            label: 'Synthetic exported original',
            sha256: 'synthetic-original-hash',
            sizeBytes: 1024,
            exportedUri: 'content://fixture/exported-original',
          ),
        ],
      );
    final controller = await _open(exporter);
    await controller.finishOriginalRecovery();
    expect(exporter.finishes, 0);
    expect(controller.originalRecoveryState, isNotNull);
    expect(controller.recoveryNotice, _unknownCurrentWarning);
  });

  test(
    'explicit permitted finish refreshes and clears completed recovery state',
    () async {
      final exporter = _RecoveryExporter()
        ..state = _recoveryState(canRestore: false, canFinish: true);
      final controller = await _open(exporter);
      final readsBefore = exporter.stateReads;
      await controller.finishOriginalRecovery();
      expect(exporter.finishes, 1);
      expect(exporter.stateReads, greaterThan(readsBefore));
      expect(controller.originalRecoveryState, isNull);
      expect(controller.exportRecoveryNotice, isNull);
      expect(controller.recoveryNotice, isNull);
      expect(exporter.restores, 0);
      expect(exporter.acknowledgements, 0);
      expect(controller.taskForTrack('target')!.status, TaskStatus.readyToSave);
    },
  );

  test(
    'backend finish refusal keeps recovery visible and does not restore',
    () async {
      final exporter = _RecoveryExporter()
        ..state = _recoveryState(canFinish: true)
        ..failFinish = true;
      final controller = await _open(exporter);
      await controller.finishOriginalRecovery();
      expect(exporter.finishes, 1);
      expect(controller.originalRecoveryState, isNotNull);
      expect(controller.recoveryNotice, _unknownCurrentWarning);
      expect(controller.notice, contains('still need export'));
      expect(exporter.restores, 0);
      expect(controller.isBusy, isFalse);
    },
  );

  test(
    'unreadable recovery state cannot enable destructive controller actions',
    () async {
      final exporter = _RecoveryExporter()..failStateRead = true;
      final controller = await _open(exporter);
      expect(controller.loadError, isNull);
      expect(controller.originalRecoveryState, isNull);
      expect(controller.recoveryNotice, contains('无法检查'));
      await controller.restoreOriginalBackup();
      await controller.finishOriginalRecovery();
      expect(exporter.restores, 0);
      expect(exporter.finishes, 0);
      expect(controller.recoveryNotice, isNotNull);
    },
  );
}
