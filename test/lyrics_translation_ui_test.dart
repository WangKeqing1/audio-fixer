import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
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
  List<FieldSuggestion> selected = [];
  @override
  bool supports(AudioTrack track) => true;
  @override
  Future<String?> export(AudioTrack track, List<FieldSuggestion> values) async {
    selected = values;
    return 'content://test/new-copy';
  }
}

void main() {
  testWidgets(
    'translation can be disabled in preview and exported original-only',
    (tester) async {
      final candidate = const FieldSuggestion(
        field: AudioField.lyrics,
        value: '[00:01.000]Synthetic original',
        source: 'Fixture provider',
        originalLyrics: '[00:01.000]Synthetic original',
        chineseTranslation: '[00:01.000]合成测试译文',
      ).withChineseTranslation(true);
      final task = CompletionTask(
        trackId: 'fixture',
        trackTitle: 'Synthetic song',
        createdAt: DateTime(2026),
        status: TaskStatus.needsReview,
        message: 'Offline fixture',
        suggestions: [candidate],
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
      await tester.tap(find.text('确认 1 项候选'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('不加翻译，仅保存原歌词'), findsOneWidget);
      await tester.tap(find.text('导出副本（1 项）'));
      await tester.pumpAndSettle();
      expect(exporter.selected.single.value, '[00:01.000]Synthetic original');
      expect(exporter.selected.single.includeChineseTranslation, isFalse);
      expect(controller.tasks.single.status, TaskStatus.exported);
      expect(tester.takeException(), isNull);
    },
  );
  test('legacy settings default translation on and opt-out persists', () {
    final data = const AppSettings().toJson()
      ..remove('includeChineseTranslation');
    expect(AppSettings.fromJson(data).includeChineseTranslation, isTrue);
    expect(
      AppSettings.fromJson(
        const AppSettings().copyWith(includeChineseTranslation: false).toJson(),
      ).includeChineseTranslation,
      isFalse,
    );
  });
}
