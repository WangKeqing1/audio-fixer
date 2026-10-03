import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/batch_operation.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _candidate = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'Synthetic approval persistence fixture',
  source: 'Offline fixture',
  sourceUrl: 'https://example.com/synthetic-candidate',
  matchDescription: 'Synthetic match evidence',
);

CompletionTask _task(
  String id, {
  TaskStatus status = TaskStatus.needsReview,
  bool approved = false,
  String? writeError,
}) => CompletionTask(
  trackId: id,
  trackTitle: 'Synthetic $id',
  createdAt: DateTime.utc(2026, 1, 1),
  status: status,
  message: 'Synthetic persistence fixture',
  suggestions: const [_candidate],
  approvedSuggestions: approved ? const [_candidate] : const [],
  queriedFields: const {AudioField.lyrics},
  writeError: writeError,
);

class _Writer implements AudioCopyExporter, AudioOriginalSaver {
  final originalCalls = <String>[];
  int copyCalls = 0;
  String? pauseId;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  bool supports(AudioTrack track) => true;

  @override
  bool supportsOriginal(AudioTrack track) => true;

  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    copyCalls++;
    return 'content://fixture/copy/${track.id}';
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    originalCalls.add(track.id);
    if (track.id == pauseId) {
      entered.complete();
      await release.future;
    }
    return 'content://fixture/original/${track.id}';
  }
}

Future<LibraryController> _open(MemoryStore store, _Writer writer) async {
  final controller = LibraryController(
    store: store,
    picker: FakePicker(),
    importer: FakeImporter(),
    completion: CompletionService(),
    exporter: writer,
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

LibrarySnapshot _roundTrip(LibrarySnapshot snapshot) =>
    LibrarySnapshot.fromJson(
      jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>,
    );

void main() {
  test('old catalog candidates never gain implicit approval after upgrade', () {
    final document = LibrarySnapshot(
      tracks: [fixtureTrack(id: 'a')],
      tasks: [_task('a')],
    ).toJson();
    document.remove('batchOperation');
    final taskDocument =
        (document['tasks'] as List).single as Map<String, Object?>;
    taskDocument.remove('approvedSuggestions');
    taskDocument.remove('writeError');
    final restored = LibrarySnapshot.fromJson(
      jsonDecode(jsonEncode(document)) as Map<String, dynamic>,
    );
    expect(restored.batchOperation, isNull);
    expect(restored.tasks.single.status, TaskStatus.needsReview);
    expect(restored.tasks.single.suggestions, hasLength(1));
    expect(restored.tasks.single.approvedSuggestions, isEmpty);
    expect(restored.tasks.single.writeError, isNull);
  });

  test('explicit approval, source attribution and write errors round trip', () {
    final restored = _roundTrip(
      LibrarySnapshot(
        tracks: [fixtureTrack(id: 'a')],
        tasks: [
          _task(
            'a',
            status: TaskStatus.readyToSave,
            approved: true,
            writeError: 'Synthetic writer failed',
          ),
        ],
      ),
    );
    final task = restored.tasks.single;
    expect(task.status, TaskStatus.readyToSave);
    expect(task.approvedSuggestions.single.toJson(), _candidate.toJson());
    expect(task.queriedFields, {AudioField.lyrics});
    expect(task.writeError, 'Synthetic writer failed');
  });

  test('batch counts describe every terminal outcome and round trip', () {
    const statuses = BatchItemStatus.values;
    final batch = BatchOperation(
      kind: BatchOperationKind.saveOriginal,
      isRunning: true,
      stopRequested: true,
      items: [
        for (var index = 0; index < statuses.length; index++)
          BatchItemResult(
            trackId: 'synthetic-$index',
            trackTitle: 'Synthetic $index',
            status: statuses[index],
            message: 'Fixture ${statuses[index].name}',
          ),
      ],
    );
    final restored = _roundTrip(LibrarySnapshot(batchOperation: batch))
        .batchOperation!;
    expect(restored.kind, BatchOperationKind.saveOriginal);
    expect(restored.totalCount, 8);
    expect(restored.completedCount, 6);
    expect(restored.progress, 0.75);
    expect(restored.failedCount, 1);
    expect(restored.reviewCount, 1);
    expect(restored.savedOriginalCount, 1);
    expect(restored.exportedCount, 1);
    expect(restored.skippedCount, 1);
    expect(restored.cancelledCount, 1);
    expect(restored.isRunning, isTrue);
    expect(restored.stopRequested, isTrue);
    expect(restored.summary, contains('共 8 首'));
    expect(restored.summary, contains('失败 1'));
    expect(
      restored.items.map((item) => item.message),
      batch.items.map((item) => item.message),
    );
  });

  test(
    'interrupted recovery leaves successful and failed results unchanged',
    () {
      final batch = BatchOperation(
        kind: BatchOperationKind.exportCopies,
        stopRequested: true,
        items: [
          for (final status in BatchItemStatus.values)
            BatchItemResult(
              trackId: status.name,
              trackTitle: status.name,
              status: status,
              message: 'Before ${status.name}',
            ),
        ],
      );
      final restored = batch.recoverInterrupted();
      expect(restored.isRunning, isFalse);
      expect(restored.stopRequested, isFalse);
      expect(restored.completedCount, restored.totalCount);
      expect(restored.progress, 1);
      expect(restored.cancelledCount, 3);
      for (final old in batch.items) {
        final current = restored.items.singleWhere(
          (item) => item.trackId == old.trackId,
        );
        if (old.isFinished) {
          expect(current.status, old.status);
          expect(current.message, old.message);
        } else {
          expect(current.status, BatchItemStatus.cancelled);
          expect(current.message, contains('中断'));
        }
      }
      expect(
        batch.isRunning,
        isTrue,
        reason: 'Recovery returns a new immutable record.',
      );
    },
  );

  test('restart cancels persisted pending writes and revokes uncertain approval', () async {
    final store = MemoryStore(
      LibrarySnapshot(
        tracks: ['a', 'b', 'c'].map((id) => fixtureTrack(id: id)).toList(),
        tasks: ['a', 'b', 'c'].map((id) => _task(id)).toList(),
      ),
    );
    final writer = _Writer()..pauseId = 'b';
    final controller = await _open(store, writer);
    for (final task in controller.tasks.toList()) {
      expect(
        await controller.approveCandidates(task, const [_candidate]),
        isTrue,
      );
    }
    controller.selectTracks(['a', 'b', 'c']);
    final work = controller.saveSelectedCandidates();
    await writer.entered.future.timeout(const Duration(seconds: 5));
    final interrupted = _roundTrip(store.snapshot);
    expect(interrupted.batchOperation!.isRunning, isTrue);
    expect(interrupted.batchOperation!.items.map((item) => item.status), [
      BatchItemStatus.savedOriginal,
      BatchItemStatus.running,
      BatchItemStatus.queued,
    ]);
    // Finish the first controller cleanly; the captured durable snapshot models
    // exactly what another process would see after the write had been killed.
    controller.stopBatch();
    writer.release.complete();
    await work;

    final restartStore = MemoryStore(interrupted);
    final restartWriter = _Writer();
    final restarted = await _open(restartStore, restartWriter);
    final recovered = restarted.batchOperation!;
    expect(recovered.isRunning, isFalse);
    expect(recovered.items.map((item) => item.status), [
      BatchItemStatus.savedOriginal,
      BatchItemStatus.cancelled,
      BatchItemStatus.cancelled,
    ]);
    expect(recovered.savedOriginalCount, 1);
    expect(recovered.cancelledCount, 2);
    expect(restarted.taskForTrack('a')!.status, TaskStatus.savedOriginal);
    expect(restarted.taskForTrack('b')!.approvedSuggestions, isEmpty);
    expect(restarted.taskForTrack('b')!.status, isNot(TaskStatus.readyToSave));
    expect(restarted.selectedTrackIds, isEmpty);
    expect(restartWriter.originalCalls, isEmpty);
    expect(restartWriter.copyCalls, 0);
    expect(restarted.hasRetryableBatchFailures, isFalse);
    await restarted.retryFailedBatch();
    expect(restartWriter.originalCalls, isEmpty);
    restarted.selectTracks(['b']);
    await restarted.saveSelectedCandidates();
    expect(
      restartWriter.originalCalls,
      isEmpty,
      reason: 'An uncertain source write requires fresh review.',
    );
  });

  test(
    'approved idle tasks survive restart but never save automatically',
    () async {
      final store = MemoryStore(
        _roundTrip(
          LibrarySnapshot(
            tracks: [fixtureTrack(id: 'a')],
            tasks: [_task('a', status: TaskStatus.readyToSave, approved: true)],
          ),
        ),
      );
      final writer = _Writer();
      final controller = await _open(store, writer);
      expect(controller.tasks.single.status, TaskStatus.readyToSave);
      expect(
        controller.approvedSuggestionsFor(controller.tasks.single),
        hasLength(1),
      );
      expect(writer.originalCalls, isEmpty);
      controller.selectTracks(['a']);
      await controller.saveSelectedCandidates();
      expect(writer.originalCalls, ['a']);
    },
  );

  test(
    'disk updates cannot resurrect removed approvals or obsolete batches',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'audio-fixer-batch-catalog-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = JsonLibraryStore(() async => directory);
      await store.save(
        LibrarySnapshot(
          tracks: [fixtureTrack(id: 'a')],
          tasks: [
            _task(
              'a',
              status: TaskStatus.readyToSave,
              approved: true,
              writeError: 'Previous failure',
            ),
          ],
          batchOperation: const BatchOperation(
            kind: BatchOperationKind.saveOriginal,
            isRunning: false,
            items: [
              BatchItemResult(
                trackId: 'a',
                trackTitle: 'Synthetic a',
                status: BatchItemStatus.failed,
              ),
            ],
          ),
        ),
      );
      await store.save(
        LibrarySnapshot(
          tracks: [fixtureTrack(id: 'a')],
          tasks: [_task('a')],
        ),
      );
      final restored = await store.load();
      expect(restored.batchOperation, isNull);
      expect(restored.tasks.single.approvedSuggestions, isEmpty);
      expect(restored.tasks.single.writeError, isNull);
      expect(restored.tasks.single.status, TaskStatus.needsReview);
    },
  );

  for (final changedField in ['kind', 'status']) {
    test(
      'unknown batch $changedField preserves primary instead of restoring old backup',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'audio-fixer-future-batch-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = JsonLibraryStore(() async => directory);
        final supported = LibrarySnapshot(
          tracks: [fixtureTrack(id: 'a')],
          tasks: [_task('a', status: TaskStatus.readyToSave, approved: true)],
          batchOperation: const BatchOperation(
            kind: BatchOperationKind.saveOriginal,
            isRunning: false,
            items: [
              BatchItemResult(
                trackId: 'a',
                trackTitle: 'Synthetic a',
                status: BatchItemStatus.failed,
              ),
            ],
          ),
        );
        await store.save(supported);
        final primary = File('${directory.path}/library.json');
        final backup = File('${directory.path}/library.json.bak');
        final backupBytes = await backup.readAsBytes();
        final futureDocument =
            jsonDecode(jsonEncode(supported.toJson())) as Map<String, dynamic>;
        final batch = futureDocument['batchOperation'] as Map<String, dynamic>;
        if (changedField == 'kind') {
          batch['kind'] = 'futureWriteOperation';
        } else {
          ((batch['items'] as List).single as Map<String, dynamic>)['status'] =
              'futureWriteResult';
        }
        final futureBytes = utf8.encode(jsonEncode(futureDocument));
        await primary.writeAsBytes(futureBytes);
        await expectLater(
          store.load(),
          throwsA(isA<UnsupportedLibraryFormatException>()),
        );
        expect(await primary.readAsBytes(), futureBytes);
        expect(await backup.readAsBytes(), backupBytes);
        expect(await directory.list().length, 2);
      },
    );
  }
}
