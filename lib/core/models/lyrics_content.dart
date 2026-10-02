/// Original/provider-supplied translated lyrics remain separate until saving.
/// No machine translation or upload of lyrics is performed here.
class LyricsContent {
  const LyricsContent(
    this.original, {
    this.chineseTranslation,
    this.machineTranslated = false,
  });

  final String original;
  final String? chineseTranslation;
  final bool machineTranslated;

  String get translationLabel =>
      machineTranslated ? '中文机器翻译 · Google Translate' : '中文';

  static final _timestamp = RegExp(
    r'\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]',
  );
  static final _tags = RegExp(r'\[[^\]\n]*\]');
  static final _han = RegExp(r'[\u3400-\u9fff]');
  static final _kanaHangul = RegExp(r'[\u3040-\u30ff\uac00-\ud7af]');
  static final _letters = RegExp(r'\p{L}', unicode: true);

  static String textOnly(String value) => value.replaceAll(_tags, '').trim();

  static bool usable(String? value) {
    if (value == null) return false;
    final text = textOnly(value).trim();
    if (!_letters.hasMatch(text)) return false;
    return !const {
      '暂无歌词',
      '暂无翻译',
      '纯音乐',
      '纯音乐，请欣赏',
      'no lyrics',
      'instrumental',
      'lyrics unavailable',
      'lyrics not available',
    }.contains(text.toLowerCase());
  }

  bool get mostlyChinese {
    final text = textOnly(original);
    final letters = _letters.allMatches(text).length;
    return letters > 0 &&
        !_kanaHangul.hasMatch(text) &&
        _han.allMatches(text).length / letters > 0.65;
  }

  bool get hasChineseTranslation =>
      usable(chineseTranslation) &&
      _han.hasMatch(textOnly(chineseTranslation!)) &&
      !_kanaHangul.hasMatch(textOnly(chineseTranslation!)) &&
      textOnly(chineseTranslation!) != textOnly(original);

  bool get hasIncompatibleOffsets =>
      hasChineseTranslation &&
      _timestamp.hasMatch(original) &&
      _timestamp.hasMatch(chineseTranslation!) &&
      _offset(original) != _offset(chineseTranslation!);

  bool get canIncludeTranslation =>
      hasChineseTranslation && !hasIncompatibleOffsets;

  String get status => hasIncompatibleOffsets
      ? '译文时间偏移不同，仅供预览；保存时保留原歌词'
      : hasChineseTranslation
      ? machineTranslated
            ? 'Google Translate 本机机器翻译，需人工核对'
            : '来源提供中文译文'
      : mostlyChinese
      ? '原歌词以中文为主'
      : '来源未提供可用中文译文，保留原歌词';

  String render({required bool includeTranslation}) {
    if (!includeTranslation || !canIncludeTranslation) return original;
    final originalLines = _timedLines(original, translated: false);
    final translatedLines = _timedLines(chineseTranslation!, translated: true);
    // Keep each provider timestamp. Do not align by index or invent timings.
    // An offset tag changes the entire LRC; combining different offsets would
    // silently desynchronize one language; the guard above saves original only.
    if (originalLines != null &&
        translatedLines != null &&
        _offset(original) == _offset(chineseTranslation!)) {
      final lines = [...originalLines, ...translatedLines]
        ..sort((a, b) {
          final order = a.time.compareTo(b.time);
          return order == 0 ? a.order.compareTo(b.order) : order;
        });
      final metadata = original
          .split('\n')
          .where(
            (line) => !_timestamp.hasMatch(line) && line.trim().startsWith('['),
          );
      return [
        ...metadata,
        ...lines.map(
          (line) => line.order >= 100000
              ? line.value.replaceFirst('【中文】', '【$translationLabel】')
              : line.value,
        ),
      ].join('\n');
    }
    return '【原歌词】\n$original\n\n【${machineTranslated ? translationLabel : '中文译文'}】\n$chineseTranslation';
  }

  static int _offset(String value) =>
      int.tryParse(
        RegExp(
              r'\[offset:([+-]?\d+)\]',
              caseSensitive: false,
            ).firstMatch(value)?.group(1) ??
            '0',
      ) ??
      0;

  static List<_TimedLine>? _timedLines(
    String value, {
    required bool translated,
  }) {
    final result = <_TimedLine>[];
    var sequence = 0;
    for (final line in value.split('\n')) {
      final stamps = _timestamp.allMatches(line).toList();
      if (stamps.isEmpty) {
        if (textOnly(line).isNotEmpty) return null;
        continue;
      }
      final text = line.replaceAll(_timestamp, '').trim();
      // Timestamp-only translation records are not translated content.
      if (translated && text.isEmpty) continue;
      for (final stamp in stamps) {
        final millis = (stamp.group(3) ?? '').padRight(3, '0');
        result.add(
          _TimedLine(
            (int.parse(stamp.group(1)!) * 60 + int.parse(stamp.group(2)!)) *
                    1000 +
                int.parse(millis),
            '${stamp.group(0)}${translated ? '【中文】' : ''}$text',
            (translated ? 100000 : 0) + sequence++,
          ),
        );
      }
    }
    return result.isEmpty ? null : result;
  }
}

class _TimedLine {
  const _TimedLine(this.time, this.value, this.order);
  final int time;
  final String value;
  final int order;
}
