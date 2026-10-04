import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/lyrics_translation_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _original = '[00:01.000]This is a synthetic test line.';
const _translated = '[00:01.000]这是一句合成测试文本。';
const _candidate = FieldSuggestion(
  field: AudioField.lyrics,
  value: _original,
  originalLyrics: _original,
  source: 'Synthetic source',
);

class _Source implements MetadataSource {
  _Source({this.providerTranslation = false});
  final bool providerTranslation;
  @override
  String get name => 'Synthetic source';
  @override
  Set<AudioField> get supportedFields => {AudioField.lyrics};
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async => [
    providerTranslation
        ? _candidate.withTranslation(chineseLyrics: _translated)
        : _candidate,
  ];
}

class _Translator implements LyricsTranslator {
  int inspections = 0;
  int downloads = 0;
  int translations = 0;
  bool ready = false;
  @override
  Future<TranslationModelStatus> inspect(String original) async {
    inspections++;
    return TranslationModelStatus(
      sourceLanguage: 'en',
      ready: ready,
      missingModels: ready ? const [] : const ['zh'],
    );
  }

  @override
  Future<void> downloadModels(String sourceLanguage) async {
    downloads++;
    ready = true;
  }

  @override
  Future<LyricTranslation> translateIfReady(String original) async {
    translations++;
    return ready
        ? const LyricTranslation(
            chineseLyrics: _translated,
            sourceLanguage: 'en',
          )
        : const LyricTranslation(message: '请先下载模型', sourceLanguage: 'en');
  }
}

void main() {
  test(
    'machine fallback is opt-in, does not run when translations are off',
    () async {
      for (final settings in [
        const AppSettings(),
        const AppSettings(
          onDeviceTranslationEnabled: true,
          includeChineseTranslation: false,
        ),
      ]) {
        final translator = _Translator()..ready = true;
        final service = CompletionService(
          sources: [_Source()],
          translator: translator,
        );
        final result = await service.preview(fixtureTrack(), settings);
        expect(result.suggestions.single.value, _original);
        expect(translator.translations, 0);
      }
    },
  );
  test('provider translation wins over local machine translation', () async {
    final translator = _Translator()..ready = true;
    final service = CompletionService(
      sources: [_Source(providerTranslation: true)],
      translator: translator,
    );
    final result = await service.preview(
      fixtureTrack(),
      const AppSettings(onDeviceTranslationEnabled: true),
    );
    expect(result.suggestions.single.machineTranslated, isFalse);
    expect(result.suggestions.single.chineseTranslation, _translated);
    expect(translator.translations, 0);
  });
  test(
    'ready machine fallback is clearly attributed with original retained',
    () async {
      final translator = _Translator()..ready = true;
      final service = CompletionService(
        sources: [_Source()],
        translator: translator,
      );
      final result = await service.preview(
        fixtureTrack(),
        const AppSettings(onDeviceTranslationEnabled: true),
      );
      final candidate = result.suggestions.single;
      expect(candidate.machineTranslated, isTrue);
      expect(candidate.value, contains('【中文机器翻译 · Google Translate】'));
      expect(candidate.originalLyrics, _original);
      expect(candidate.withChineseTranslation(false).value, _original);
      expect(
        FieldSuggestion.fromJson(candidate.toJson()).machineTranslated,
        isTrue,
      );
      expect(translator.downloads, 0);
    },
  );
  test('missing models remain original-only and never auto-download', () async {
    final translator = _Translator();
    final result =
        await CompletionService(
          sources: [_Source()],
          translator: translator,
        ).preview(
          fixtureTrack(),
          const AppSettings(onDeviceTranslationEnabled: true),
        );
    expect(result.suggestions.single.value, _original);
    expect(result.suggestions.single.translationNotice, '请先下载模型');
    expect(result.suggestions.single.machineTranslated, isFalse);
    expect(translator.downloads, 0);
  });
  testWidgets(
    'first-use decline does nothing; confirmed download creates reviewable machine candidate',
    (tester) async {
      final translator = _Translator();
      final task = CompletionTask(
        trackId: 'fixture',
        trackTitle: 'Synthetic song',
        createdAt: DateTime(2026),
        status: TaskStatus.needsReview,
        message: 'Offline fixture',
        suggestions: const [_candidate],
      );
      final controller = LibraryController(
        store: MemoryStore(
          LibrarySnapshot(
            tracks: [fixtureTrack()],
            tasks: [task],
            settings: const AppSettings(metadata: false, artwork: false),
          ),
        ),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(
          sources: [_Source()],
          translator: translator,
        ),
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      expect(translator.inspections, 0);
      await tester.tap(find.text('补全任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认 1 项候选'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('预览与来源').first,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('预览与来源').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览与来源').first);
      await tester.pumpAndSettle();
      final action = find.text('使用 Google Translate 本机翻译');
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('启用本机机器翻译？'), findsOneWidget);
      await tester.tap(find.text('暂不启用'));
      await tester.pumpAndSettle();
      expect(translator.inspections, 0);
      expect(translator.downloads, 0);
      expect(controller.settings.onDeviceTranslationEnabled, isFalse);
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('启用 Google Translate'));
      await tester.pumpAndSettle();
      expect(find.text('下载本机翻译模型？'), findsOneWidget);
      expect(translator.downloads, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(translator.downloads, 0);
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载并使用 Google Translate'));
      await tester.pumpAndSettle();
      expect(translator.downloads, 1);
      expect(translator.translations, 1);
      expect(
        controller.tasks.single.suggestions.single.machineTranslated,
        isTrue,
      );
      expect(
        controller.approvedSuggestionsFor(controller.tasks.single),
        isEmpty,
      );
      expect(controller.tracks.single.lyrics, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
