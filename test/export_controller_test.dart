import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const candidate = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'offline test lyrics',
  source: 'Fixture',
);

class FakeExporter implements AudioCopyExporter {
  String? result = 'content://documents/new-copy';
  int calls = 0;
  bool fail = false;
  @override
  bool supports(AudioTrack track) => track.extension == 'MP3';
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    calls++;
    if (fail) throw const ExportException('Verification failed');
    return result;
  }
}

void main() {
  late FakeExporter exporter;
  late MemoryStore store;
  late LibraryController controller;
  late CompletionTask task;
  setUp(() async {
    task = CompletionTask(
      trackId: 'fixture',
      trackTitle: 'Fixture',
      createdAt: DateTime(2026),
      status: TaskStatus.needsReview,
      message: 'Review fixture',
      suggestions: const [candidate],
    );
    exporter = FakeExporter();
    store = MemoryStore(
      LibrarySnapshot(tracks: [fixtureTrack()], tasks: [task]),
    );
    controller = LibraryController(
      store: store,
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
      exporter: exporter,
    );
    await controller.initialize();
  });
  tearDown(() => controller.dispose());

  test(
    'export persists separate result without claiming source tags changed',
    () async {
      expect(await controller.exportCandidates(task, [candidate]), isTrue);
      expect(controller.tasks.single.status, TaskStatus.exported);
      expect(controller.tasks.single.exportedCopyUri, exporter.result);
      expect(controller.tracks.single.lyrics, isNull);
      final restored = LibrarySnapshot.fromJson(store.snapshot.toJson());
      expect(restored.tasks.single.status, TaskStatus.exported);
      expect(restored.tracks.single.lyrics, isNull);
    },
  );
  test('cancel leaves review and source untouched and can retry', () async {
    exporter.result = null;
    expect(await controller.exportCandidates(task, [candidate]), isFalse);
    expect(controller.tasks.single.status, TaskStatus.needsReview);
    expect(controller.notice, contains('已取消'));
    expect(controller.isBusy, isFalse);
    exporter.result = 'content://documents/new-copy';
    expect(await controller.exportCandidates(task, [candidate]), isTrue);
    expect(exporter.calls, 2);
  });
  test(
    'failed integrity verification is visible and does not mark exported',
    () async {
      exporter.fail = true;
      expect(await controller.exportCandidates(task, [candidate]), isFalse);
      expect(controller.notice, 'Verification failed');
      expect(controller.tasks.single.status, TaskStatus.needsReview);
    },
  );
  test('empty or altered candidates never invoke writer', () async {
    expect(await controller.exportCandidates(task, []), isFalse);
    expect(
      await controller.exportCandidates(task, const [
        FieldSuggestion(
          field: AudioField.lyrics,
          value: 'not the reviewed candidate',
          source: 'Fixture',
        ),
      ]),
      isFalse,
    );
    expect(exporter.calls, 0);
  });
  test('stale review cannot export newer query', () async {
    final stale = CompletionTask(
      trackId: 'fixture',
      trackTitle: 'Fixture',
      createdAt: DateTime(2025),
      status: TaskStatus.needsReview,
      message: '',
      suggestions: const [candidate],
    );
    expect(await controller.exportCandidates(stale, [candidate]), isFalse);
    expect(exporter.calls, 0);
  });
  test(
    'failed catalog persistence still accurately reports saved copy',
    () async {
      store.failSave = true;
      expect(await controller.exportCandidates(task, [candidate]), isTrue);
      expect(controller.notice, contains('音频副本已保存'));
      expect(controller.tracks.single.lyrics, isNull);
    },
  );
}
