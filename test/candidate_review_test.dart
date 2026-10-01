import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Exporter implements AudioCopyExporter {
  int calls = 0;
  String? result;
  List<FieldSuggestion> selected = [];
  @override
  bool supports(AudioTrack track) => true;
  @override
  Future<String?> export(AudioTrack track, List<FieldSuggestion> values) async {
    calls++;
    selected = values;
    return result;
  }
}

void main() {
  testWidgets(
    'review can deselect, cancel save, retry and reports separate copy',
    (tester) async {
      final task = CompletionTask(
        trackId: 'fixture',
        trackTitle: 'Synthetic song',
        createdAt: DateTime(2026),
        status: TaskStatus.needsReview,
        message: 'Offline fixture only',
        suggestions: const [
          FieldSuggestion(
            field: AudioField.album,
            value: 'Synthetic album',
            source: 'Test source',
          ),
          FieldSuggestion(
            field: AudioField.lyrics,
            value: 'Synthetic lyrics',
            source: 'Test source',
          ),
        ],
      );
      final exporter = _Exporter();
      final controller = LibraryController(
        store: MemoryStore(
          LibrarySnapshot(tracks: [fixtureTrack()], tasks: [task]),
        ),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(),
        exporter: exporter,
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补全任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认 2 项候选'));
      await tester.pumpAndSettle();
      expect(find.text('确认候选资料'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出副本（1 项）'));
      await tester.pumpAndSettle();
      expect(exporter.selected.single.field, AudioField.lyrics);
      expect(find.text('确认候选资料'), findsOneWidget);
      expect(controller.tasks.single.status, TaskStatus.needsReview);
      exporter.result = 'content://test/new-copy';
      await tester.tap(find.text('导出副本（1 项）'));
      await tester.pumpAndSettle();
      expect(exporter.calls, 2);
      expect(find.text('确认候选资料'), findsNothing);
      expect(controller.tasks.single.status, TaskStatus.exported);
      expect(controller.tracks.single.lyrics, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('batch confirmation cancellation starts no query', (
    tester,
  ) async {
    final controller = testController(
      store: MemoryStore(LibrarySnapshot(tracks: [fixtureTrack()])),
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('补全全部缺失信息'));
    await tester.pumpAndSettle();
    expect(find.text('查询 1 首歌曲？'), findsOneWidget);
    expect(controller.tasks, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.tasks, isEmpty);
    expect(find.text('查询 1 首歌曲？'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
