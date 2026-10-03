import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/lyrics_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bilingual rendering retains each timestamp and original text', () {
    const content = LyricsContent(
      '[00:01.20]Original one\n[00:03.00]Original two',
      chineseTranslation: '[00:01.200]译文一\n[00:04.000]译文二',
    );
    expect(
      content.render(includeTranslation: true),
      '[00:01.20]Original one\n[00:01.200]【中文】译文一\n[00:03.00]Original two\n[00:04.000]【中文】译文二',
    );
    expect(content.render(includeTranslation: false), content.original);
  });
  test('plain lyrics stay in separately labelled language sections', () {
    const content = LyricsContent('Original verse', chineseTranslation: '中文译文');
    expect(
      content.render(includeTranslation: true),
      '【原歌词】\nOriginal verse\n\n【中文译文】\n中文译文',
    );
  });
  test('empty and timestamp-only translations are unavailable', () {
    for (final translation in [
      '',
      '[00:00.00]\n[00:01.00]',
      '暂无翻译',
      'romaji',
    ]) {
      final content = LyricsContent(
        'An original verse',
        chineseTranslation: translation,
      );
      expect(content.hasChineseTranslation, isFalse);
      expect(content.render(includeTranslation: true), content.original);
      expect(content.status, contains('未提供'));
    }
  });
  test(
    'Japanese with kana is not mislabelled Chinese; Chinese has no warning',
    () {
      expect(const LyricsContent('日本の歌').mostlyChinese, isFalse);
      expect(const LyricsContent('这是原歌词').status, '原歌词以中文为主');
    },
  );
  test('different LRC offsets are not falsely interleaved', () {
    const content = LyricsContent(
      '[offset:100]\n[00:01.00]Line',
      chineseTranslation: '[offset:200]\n[00:01.00]歌词',
    );
    expect(content.render(includeTranslation: true), content.original);
    expect(content.status, contains('仅供预览'));
    expect(content.canIncludeTranslation, isFalse);
  });
  test(
    'approved variants allow opt-out but reject edited text and fake source',
    () {
      const candidate = FieldSuggestion(
        field: AudioField.lyrics,
        value: 'Original',
        source: 'Provider',
        originalLyrics: 'Original',
        chineseTranslation: '译文',
      );
      final bilingual = candidate.withChineseTranslation(true);
      final originalOnly = bilingual.withChineseTranslation(false);
      expect(bilingual.permits(originalOnly), isTrue);
      expect(
        bilingual.permits(
          const FieldSuggestion(
            field: AudioField.lyrics,
            value: 'Made up',
            source: 'Provider',
            originalLyrics: 'Original',
            chineseTranslation: '改写译文',
          ),
        ),
        isFalse,
      );
      expect(
        bilingual.permits(
          const FieldSuggestion(
            field: AudioField.lyrics,
            value: 'Original',
            source: 'Fake',
          ),
        ),
        isFalse,
      );
      final restored = FieldSuggestion.fromJson(bilingual.toJson());
      expect(restored.value, bilingual.value);
      expect(restored.chineseTranslation, '译文');
      expect(restored.withChineseTranslation(false).value, 'Original');
    },
  );
}
