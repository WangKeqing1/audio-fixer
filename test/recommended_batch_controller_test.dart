import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/recommended_changes.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _album = FieldSuggestion(
  field: AudioField.album,
  value: 'Verified album',
  source: 'Fixture',
  provenance: SuggestionProvenance.verifiedRecording,
);
const _lyrics = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'Verified lyrics',
  source: 'Fixture',
  provenance: SuggestionProvenance.verifiedRecording,
);

CompletionTask _task(String id, {int revision = 0}) => CompletionTask(
  trackId: id,
  trackTitle: id,
  createdAt: DateTime(2026, 1, 1, 0, 0, revision),
  status: TaskStatus.needsReview,
  message: '',
  suggestions: const [_album, _lyrics],
);

class _Writer
    implements AudioCopyExporter, AudioOriginalSaver, AudioBatchOriginalSaver {
  final writes = <String, List<FieldSuggestion>>{};
  final permissions = <List<String>>[];
  bool granted = true;
  final failIds = <String>{};
  final attempts = <String>[];
  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<bool> authorizeOriginalWrites(List<AudioTrack> tracks) async {
    permissions.add(tracks.map((track) => track.id).toList());
    return granted;
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    attempts.add(track.id);
    if (failIds.contains(track.id)) throw const ExportException('Test failure');
    writes[track.id] = List.of(selected);
    return 'content://fixture/${track.id}';
  }

  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => null;
}

Future<LibraryController> _controller(_Writer writer) async {
  final controller = LibraryController(
    store: MemoryStore(
      LibrarySnapshot(
        tracks: [
          fixtureTrack(id: 'a'),
          fixtureTrack(id: 'b'),
        ],
        tasks: [_task('a'), _task('b')],
      ),
    ),
    picker: FakePicker(),
    importer: FakeImporter(),
    completion: CompletionService(),
    exporter: writer,
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

void main() {
  test('reading defaults does not approve or write, final batch writes only snapshot', () async {
    final writer = _Writer();
    final controller = await _controller(writer);
    final task = controller.taskForTrack('a')!;
    expect(controller.reviewSuggestionsFor(task), [_album, _lyrics]);
    expect(controller.approvedSuggestionsFor(task), isEmpty);
    expect(writer.writes, isEmpty);
    await controller.saveReviewedBatch([
      ReviewedTaskSelection(task: task, suggestions: const [_album]),
    ]);
    expect(writer.permissions, [
      ['a'],
    ]);
    expect(writer.writes, {
      'a': [_album],
    });
    expect(controller.taskForTrack('b')!.approvedSuggestions, isEmpty);
    expect(controller.trackById('a')!.lyrics, isNull);
  });

  test(
    'explicit prior approval preserves omissions rather than merging defaults',
    () async {
      final controller = await _controller(_Writer());
      final task = controller.taskForTrack('a')!;
      await controller.approveCandidates(task, const [_album]);
      expect(controller.recommendedSuggestionsFor(task), [_album, _lyrics]);
      expect(controller.reviewSuggestionsFor(task), [_album]);
    },
  );

  test(
    'revocation remains an explicit empty choice after persistence',
    () async {
      final controller = await _controller(_Writer());
      final task = controller.taskForTrack('a')!;
      await controller.approveCandidates(task, const [_album]);
      await controller.revokeCandidateApproval(task);
      expect(controller.reviewSuggestionsFor(task), isEmpty);
      expect(controller.recommendedSuggestionsFor(task), [_album, _lyrics]);
      final store = controller.store as MemoryStore;
      store.snapshot = LibrarySnapshot(
        tracks: store.snapshot.tracks,
        tasks: store.snapshot.tasks
            .map((task) => CompletionTask.fromJson(task.toJson()))
            .toList(),
      );
      await controller.initialize();
      expect(
        controller.reviewSuggestionsFor(controller.taskForTrack('a')!),
        isEmpty,
      );
    },
  );

  test(
    'a stale reviewed generation never writes a newer set of candidates',
    () async {
      final writer = _Writer();
      final controller = await _controller(writer);
      final snapshot = ReviewedTaskSelection(
        task: controller.taskForTrack('a')!,
        suggestions: const [_album],
      );
      final store = controller.store as MemoryStore;
      store.snapshot = LibrarySnapshot(
        tracks: store.snapshot.tracks,
        tasks: [_task('a', revision: 1), _task('b')],
      );
      await controller.initialize();
      expect(controller.isReviewedSelectionCurrent(snapshot), isFalse);
      await controller.saveReviewedBatch([snapshot]);
      expect(writer.permissions, isEmpty);
      expect(writer.writes, isEmpty);
      expect(controller.batchOperation!.items.single.status.name, 'skipped');
    },
  );

  test(
    'system authorization rejection preserves task and makes no write',
    () async {
      final writer = _Writer()..granted = false;
      final controller = await _controller(writer);
      final task = controller.taskForTrack('a')!;
      await controller.saveReviewedBatch([
        ReviewedTaskSelection(
          task: task,
          suggestions: controller.reviewSuggestionsFor(task),
        ),
      ]);
      expect(writer.permissions, [
        ['a'],
      ]);
      expect(writer.writes, isEmpty);
      expect(controller.approvedSuggestionsFor(task), [_album, _lyrics]);
      expect(controller.isTaskCurrent(task), isTrue);
    },
  );

  test(
    'failed-item retry reuses exact applied subset and never repeats success',
    () async {
      final writer = _Writer()..failIds.add('a');
      final controller = await _controller(writer);
      await controller.saveReviewedBatch([
        for (final id in ['a', 'b'])
          ReviewedTaskSelection(
            task: controller.taskForTrack(id)!,
            suggestions: const [_album],
          ),
      ]);
      expect(writer.writes.keys, ['b']);
      expect(controller.approvedSuggestionsFor(controller.taskForTrack('a')!), [
        _album,
      ]);
      writer.failIds.clear();
      await controller.retryFailedBatch();
      expect(writer.attempts, ['a', 'b', 'a']);
      expect(writer.writes['a'], [_album]);
      expect(controller.trackById('a')!.lyrics, isNull);
    },
  );

  test(
    'forged or duplicate field snapshots do not enter authorization',
    () async {
      final writer = _Writer();
      final controller = await _controller(writer);
      final task = controller.taskForTrack('a')!;
      await controller.saveReviewedBatch([
        ReviewedTaskSelection(task: task, suggestions: const [_album, _album]),
      ]);
      expect(writer.permissions, isEmpty);
      expect(writer.writes, isEmpty);
      await controller.saveReviewedBatch([
        ReviewedTaskSelection(
          task: task,
          suggestions: const [
            FieldSuggestion(
              field: AudioField.album,
              value: 'Forged',
              source: 'Fixture',
            ),
          ],
        ),
      ]);
      expect(writer.permissions, isEmpty);
      expect(writer.writes, isEmpty);
    },
  );
}
