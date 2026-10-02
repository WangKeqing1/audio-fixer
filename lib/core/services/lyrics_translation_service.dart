import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The caller must obtain the user's opt-in before invoking this service.
/// Inspecting and translating never download models or send lyrics to a server.
abstract class LyricsTranslator {
  Future<TranslationModelStatus> inspect(String original);
  Future<void> downloadModels(String sourceLanguage);
  Future<LyricTranslation> translateIfReady(String original);
}

class TranslationModelStatus {
  const TranslationModelStatus({
    required this.sourceLanguage,
    this.ready = false,
    this.missingModels = const [],
    this.message,
  });

  final String sourceLanguage;
  final bool ready;
  final List<String> missingModels;
  final String? message;

  bool get canTranslate =>
      sourceLanguage != 'zh' && _supportedLanguages.contains(sourceLanguage);
}

class LyricTranslation {
  const LyricTranslation({
    this.chineseLyrics,
    this.sourceLanguage,
    this.message,
  });

  final String? chineseLyrics;
  final String? sourceLanguage;
  final String? message;

  bool get available => chineseLyrics?.trim().isNotEmpty ?? false;
}

// ML Kit Translation's base-language codes. Language identification itself is
// delegated to ML Kit; unsupported and uncertain results are never guessed.
const _supportedLanguages = {
  'af',
  'ar',
  'be',
  'bg',
  'bn',
  'ca',
  'cs',
  'cy',
  'da',
  'de',
  'el',
  'en',
  'eo',
  'es',
  'et',
  'fa',
  'fi',
  'fr',
  'ga',
  'gl',
  'gu',
  'he',
  'hi',
  'hr',
  'ht',
  'hu',
  'id',
  'is',
  'it',
  'ja',
  'ka',
  'kn',
  'ko',
  'lt',
  'lv',
  'mk',
  'mr',
  'ms',
  'mt',
  'nl',
  'no',
  'pl',
  'pt',
  'ro',
  'ru',
  'sk',
  'sl',
  'sq',
  'sv',
  'sw',
  'ta',
  'te',
  'th',
  'tl',
  'tr',
  'uk',
  'ur',
  'vi',
  'zh',
};

class PlatformLyricsTranslator implements LyricsTranslator {
  PlatformLyricsTranslator({Directory? cacheDirectory, MethodChannel? channel})
    : _providedCacheDirectory = cacheDirectory,
      _channel =
          channel ?? const MethodChannel('audio_fixer/lyrics_translation');

  static const _engineVersion = 'mlkit-local-zh-v1';
  static const _maxEntries = 256;
  static const _maxCacheBytes = 4 * 1024 * 1024;
  static const _maxOriginalChars = 100000;
  static const _maxUniqueLines = 300;
  static const _maxTextChars = 20000;
  static const _maxLineChars = 2000;
  static const _maxOutputChars = 80000;
  static int _temporarySequence = 0;

  final MethodChannel _channel;
  final Directory? _providedCacheDirectory;
  final _cache = <String, _CachedTranslation>{};
  final _inFlight = <String, Future<LyricTranslation>>{};
  Future<void>? _cacheLoaded;
  Future<void> _cacheWrites = Future.value();
  Directory? _cacheDirectory;

  @override
  Future<TranslationModelStatus> inspect(String original) async {
    final lyrics = _parse(original);
    if (lyrics.error != null) {
      return TranslationModelStatus(
        sourceLanguage: 'und',
        message: lyrics.error,
      );
    }
    return _inspect(lyrics);
  }

  Future<TranslationModelStatus> _inspect(_ParsedLyrics lyrics) async {
    var source = 'und';
    try {
      final identified = await _channel
          .invokeMethod<Object?>('identifyLanguage', {
            'text': _identificationSample(lyrics.uniqueLines),
          })
          .timeout(const Duration(seconds: 20));
      if (identified is! String || identified.trim().isEmpty) {
        return const TranslationModelStatus(
          sourceLanguage: 'und',
          message: '无法可靠识别歌词语言，未进行本地翻译。',
        );
      }
      source = _languageCode(identified);
      if (source == 'zh') {
        return const TranslationModelStatus(
          sourceLanguage: 'zh',
          message: '原歌词已是中文，无需生成中文翻译。',
        );
      }
      if (!_supportedLanguages.contains(source)) {
        return TranslationModelStatus(
          sourceLanguage: source,
          message: source == 'und'
              ? '无法可靠识别歌词语言，混合语言或过短歌词可能无法翻译。'
              : '当前本地引擎不支持该歌词语言或混合语言。',
        );
      }
      final result = await _channel
          .invokeMethod<Object?>('modelStatus', {'sourceLanguage': source})
          .timeout(const Duration(seconds: 20));
      if (result is! Map ||
          result['ready'] is! bool ||
          result['sourceLanguage'] is! String ||
          _languageCode(result['sourceLanguage'] as String) != source ||
          result['missingModels'] is! List ||
          (result['missingModels'] as List).any((item) => item is! String)) {
        return TranslationModelStatus(
          sourceLanguage: source,
          message: '无法确认本地翻译模型状态，请稍后重试。',
        );
      }
      final missing = List<String>.unmodifiable(
        (result['missingModels'] as List).cast<String>(),
      );
      final ready = result['ready'] == true && missing.isEmpty;
      return TranslationModelStatus(
        sourceLanguage: source,
        ready: ready,
        missingModels: missing,
        message: ready
            ? '本地模型已就绪；将按识别的主要语言翻译，混合语言可能不准确。'
            : '本地翻译模型尚未下载，请在设置中确认后通过 Wi-Fi 下载。',
      );
    } catch (error) {
      return TranslationModelStatus(
        sourceLanguage: source,
        message: _errorMessage(error),
      );
    }
  }

  /// This is the only operation that can download models. The UI must call it
  /// solely in response to explicit download consent; native enforces Wi-Fi.
  @override
  Future<void> downloadModels(String sourceLanguage) async {
    final source = _languageCode(sourceLanguage);
    if (source == 'zh' || !_supportedLanguages.contains(source)) {
      throw const FormatException('当前本地引擎不支持该源语言。');
    }
    final result = await _channel
        .invokeMethod<Object?>('downloadModels', {'sourceLanguage': source})
        .timeout(const Duration(seconds: 315));
    if (result is! Map ||
        result['sourceLanguage'] is! String ||
        _languageCode(result['sourceLanguage'] as String) != source ||
        result['ready'] != true ||
        result['missingModels'] is! List ||
        (result['missingModels'] as List).isNotEmpty) {
      throw PlatformException(
        code: 'MODELS_MISSING',
        message: '翻译模型尚未准备好，请连接 Wi-Fi 后重试。',
      );
    }
  }

  @override
  Future<LyricTranslation> translateIfReady(String original) {
    // Reject oversized input before hashing, parsing, or any platform call.
    if (original.length > _maxOriginalChars) {
      return Future.value(const LyricTranslation(message: '歌词过长，未进行本地翻译。'));
    }
    final originalKey = _hash(original);
    return _inFlight.putIfAbsent(originalKey, () async {
      try {
        return await _translate(original);
      } finally {
        // Async work yields before this removal, so putIfAbsent has installed it.
        _inFlight.remove(originalKey);
      }
    });
  }

  Future<LyricTranslation> _translate(String original) async {
    final lyrics = _parse(original);
    if (lyrics.error != null) return LyricTranslation(message: lyrics.error);
    final status = await _inspect(lyrics);
    if (!status.canTranslate || !status.ready) {
      return LyricTranslation(
        sourceLanguage: status.sourceLanguage,
        message: status.message,
      );
    }
    final key = _hash(
      jsonEncode([original, status.sourceLanguage, 'zh', _engineVersion]),
    );
    await (_cacheLoaded ??= _loadCache());
    final cached = _cache.remove(key);
    if (cached != null &&
        cached.sourceLanguage == status.sourceLanguage &&
        _structuralTags(original) ==
            _structuralTags(cached.result.chineseLyrics!)) {
      _cache[key] = cached;
      return cached.result;
    }
    try {
      final result = await _channel
          .invokeMethod<Object?>('translateLines', {
            'sourceLanguage': status.sourceLanguage,
            'lines': lyrics.uniqueLines,
          })
          .timeout(const Duration(seconds: 130));
      if (result is! List || result.length != lyrics.uniqueLines.length) {
        return _invalidTranslation(status.sourceLanguage);
      }
      final translated = <String, String>{};
      var characters = 0;
      var hasContinuation = false;
      for (var index = 0; index < result.length; index++) {
        final value = result[index];
        final source = lyrics.uniqueLines[index];
        if (value is! String || !_validLine(value, source)) {
          return _invalidTranslation(status.sourceLanguage);
        }
        final text = value.trim();
        characters += text.length;
        if (characters > _maxOutputChars) {
          return _invalidTranslation(status.sourceLanguage);
        }
        hasContinuation |= text.contains('\n') || text.contains('\r');
        translated[source] = text;
      }
      final output = lyrics.rows.map((row) {
        if (row.text == null) return '${row.original}${row.ending}';
        return '${row.prefix}${translated[row.text]}${row.suffix}${row.ending}';
      }).join();
      if (output.length > _maxOriginalChars + _maxOutputChars) {
        return _invalidTranslation(status.sourceLanguage);
      }
      final translation = LyricTranslation(
        chineseLyrics: output,
        sourceLanguage: status.sourceLanguage,
        message: hasContinuation && lyrics.hasTimestamps
            ? '本地机器翻译；已保留原时间戳，译文新增换行没有独立时间轴。'
            : '本地机器翻译，仅供参考；混合语言可能不准确。',
      );
      _cache[key] = _CachedTranslation(translation);
      _trimCache();
      // Persist before returning so an immediately restarted service can reuse it.
      _cacheWrites = _cacheWrites.then((_) => _saveCache());
      await _cacheWrites;
      return translation;
    } catch (error) {
      return LyricTranslation(
        sourceLanguage: status.sourceLanguage,
        message: _errorMessage(error),
      );
    }
  }

  Future<void> _loadCache() async {
    try {
      _cacheDirectory =
          _providedCacheDirectory ??
          Directory(
            p.join(
              (await getApplicationSupportDirectory()).path,
              'lyrics_translations',
            ),
          );
      final file = File(p.join(_cacheDirectory!.path, 'translations-v1.json'));
      if (!await file.exists()) return;
      if (await file.length() > _maxCacheBytes) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map ||
          raw['engine'] != _engineVersion ||
          raw['entries'] is! List) {
        return;
      }
      for (final entry in (raw['entries'] as List).take(_maxEntries)) {
        if (entry is! Map ||
            entry['key'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry['key'] as String) ||
            entry['source'] is! String ||
            !_supportedLanguages.contains(entry['source']) ||
            entry['source'] == 'zh' ||
            entry['lyrics'] is! String ||
            (entry['lyrics'] as String).length >
                _maxOriginalChars + _maxOutputChars ||
            !_han.hasMatch(entry['lyrics'] as String) ||
            entry['contentHash'] != _hash(entry['lyrics'] as String) ||
            (entry['message'] != null && entry['message'] is! String)) {
          continue;
        }
        _cache[entry['key'] as String] = _CachedTranslation(
          LyricTranslation(
            sourceLanguage: entry['source'] as String,
            chineseLyrics: entry['lyrics'] as String,
            message: entry['message'] as String?,
          ),
        );
      }
      _trimCache();
    } catch (_) {
      // Cache access must never block local translation, including when the
      // platform has no path-provider implementation (desktop/tests).
    }
  }

  Map<String, Object> _cacheJson() => {
    'engine': _engineVersion,
    'entries': [
      for (final entry in _cache.entries)
        {
          'key': entry.key,
          'source': entry.value.sourceLanguage,
          'lyrics': entry.value.result.chineseLyrics,
          'contentHash': _hash(entry.value.result.chineseLyrics!),
          'message': entry.value.result.message,
        },
    ],
  };

  void _trimCache() {
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    while (_cache.isNotEmpty &&
        utf8.encode(jsonEncode(_cacheJson())).length > _maxCacheBytes) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<void> _saveCache() async {
    final directory = _cacheDirectory;
    if (directory == null) return;
    File? temporary;
    try {
      await directory.create(recursive: true);
      final contents = jsonEncode(_cacheJson());
      temporary = File(
        p.join(
          directory.path,
          '.translations-${DateTime.now().microsecondsSinceEpoch}-${_temporarySequence++}.tmp',
        ),
      );
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(p.join(directory.path, 'translations-v1.json'));
    } catch (_) {
      // The bounded in-memory cache remains available after storage failures.
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {
        // Do not leak storage paths or lyric text into error reports.
      }
    }
  }

  static String _structuralTags(String text) => RegExp(
    r'\[(?:\d{1,3}:\d{2}(?:[.:]\d{1,3})?|[a-zA-Z][a-zA-Z0-9_-]*:[^\]\r\n]*)\]',
  ).allMatches(text).map((match) => match.group(0)).join('\u0000');

  static String _identificationSample(List<String> lines) {
    final sample = StringBuffer();
    for (final line in lines) {
      final separator = sample.isEmpty ? '' : '\n';
      if (sample.length + separator.length + line.length > _maxTextChars) break;
      sample.write(separator);
      sample.write(line);
    }
    return sample.toString();
  }

  static String _languageCode(String tag) =>
      tag.trim().toLowerCase().split(RegExp('[-_]')).first;
  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static final _han = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');
  static final _timestamp = RegExp(r'\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]');
  static final _enhancedTimestamp = RegExp(r'<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>');
  static final _tag = RegExp(
    r'^\[(?:\d{1,3}:\d{2}(?:[.:]\d{1,3})?|[a-zA-Z][a-zA-Z0-9_-]*:[^\]\r\n]*)\]',
  );
  static final _metadata = RegExp(r'\[[a-zA-Z][a-zA-Z0-9_-]*:[^\]\r\n]*\]');
  static final _credit = RegExp(
    r'^(?:(?:lyrics?|words?|music|compos(?:er|ed)|arrang(?:er|ed)|written|produced|sung|vocals?|artist|album|title|translation)(?:\s+by)?\s*[:：]|(?:作词|作曲|编曲|作詞|編曲|词|曲|詞|演唱|歌手|专辑|專輯|制作人|製作人|监制|監製|录音|錄音|混音|母带|母帶|翻译|翻譯|译者|譯者|歌词|歌詞)\s*[:：])',
    caseSensitive: false,
  );
  static final _creditBy = RegExp(
    r'^(?:lyrics?|words?|music|composed|arranged|written|produced|sung)\s+by\b',
    caseSensitive: false,
  );
  static final _section = RegExp(
    r'^\[(?:intro|verse|chorus|bridge|outro|instrumental|pre-chorus|post-chorus)(?:\s+\d+)?\]$',
    caseSensitive: false,
  );
  static final _letters = RegExp(
    r'[A-Za-z\u00C0-\u02FF\u0370-\u052F\u0590-\u06FF\u0900-\u0DFF\u0E00-\u0FFF\u10A0-\u10FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
  );

  static bool _validLine(String translated, String original) =>
      translated.length <= 8000 &&
      translated.trim().isNotEmpty &&
      translated.trim() != original.trim() &&
      _han.hasMatch(translated) &&
      !_timestamp.hasMatch(translated) &&
      !_enhancedTimestamp.hasMatch(translated) &&
      !_metadata.hasMatch(translated) &&
      !translated.contains('\u0000');

  static _ParsedLyrics _parse(String original) {
    if (original.length > _maxOriginalChars) {
      return _ParsedLyrics.invalid('歌词过长，未进行本地翻译。');
    }
    final rows = <_LyricRow>[];
    final unique = <String>{};
    var total = 0;
    var start = 0;
    var hasTimestamps = false;
    var rowCount = 0;
    for (final ending in [
      ...RegExp(r'\r\n|\r|\n').allMatches(original),
      null,
    ]) {
      final end = ending?.start ?? original.length;
      final raw = original.substring(start, end);
      start = ending?.end ?? original.length;
      rowCount++;
      if (rowCount > 2000) return _ParsedLyrics.invalid('歌词行数过多，未进行本地翻译。');
      if (raw.trim().isEmpty) continue;
      final lineEnding = ending?.group(0) ?? '';
      var contentStart = raw.length - raw.trimLeft().length;
      while (contentStart < raw.length) {
        final match = _tag.firstMatch(raw.substring(contentStart));
        if (match == null) break;
        hasTimestamps |= _timestamp.hasMatch(match.group(0)!);
        contentStart += match.end;
        contentStart +=
            raw.substring(contentStart).length -
            raw.substring(contentStart).trimLeft().length;
      }
      final text = raw.substring(contentStart).trimRight();
      if (text.isEmpty ||
          _credit.hasMatch(text) ||
          _creditBy.hasMatch(text) ||
          _section.hasMatch(text) ||
          !_letters.hasMatch(text)) {
        rows.add(_LyricRow(original: raw, ending: lineEnding));
        continue;
      }
      if (_timestamp.hasMatch(text) || _enhancedTimestamp.hasMatch(text)) {
        return _ParsedLyrics.invalid('歌词包含逐字或行内时间戳，无法可靠保留其时间对应关系。');
      }
      if (text.length > _maxLineChars) {
        return _ParsedLyrics.invalid('单行歌词过长，未进行本地翻译。');
      }
      if (unique.add(text)) total += text.length;
      // Translation input is never truncated; the language sample is bounded separately.
      if (unique.length > _maxUniqueLines || total > _maxTextChars) {
        return _ParsedLyrics.invalid('歌词超出本地翻译长度限制，未截断或部分翻译。');
      }
      rows.add(
        _LyricRow(
          original: raw,
          ending: lineEnding,
          prefix: raw.substring(0, contentStart),
          text: text,
          suffix: raw.substring(contentStart + text.length),
        ),
      );
    }
    if (unique.isEmpty) {
      return _ParsedLyrics.invalid('没有可翻译的歌词正文，标题、署名和时间戳不会用于语言识别。');
    }
    return _ParsedLyrics(rows, unique.toList(growable: false), hasTimestamps);
  }

  static LyricTranslation _invalidTranslation(String source) =>
      LyricTranslation(
        sourceLanguage: source,
        message: '本地翻译结果不完整、不是中文或未保留正文，已忽略该结果。',
      );

  static String _errorMessage(Object error) {
    if (error is MissingPluginException) return '此设备暂不支持本地歌词翻译。';
    if (error is TimeoutException) return '本地翻译处理超时，请稍后重试。';
    if (error is PlatformException) {
      return switch (error.code) {
        'UNSUPPORTED_LANGUAGE' => '当前本地引擎不支持该歌词语言或混合语言。',
        'MODELS_MISSING' => '本地翻译模型尚未下载，请在设置中确认后通过 Wi-Fi 下载。',
        'BUSY' => '本地翻译正在处理其他歌词，请稍后重试。',
        'TIMEOUT' => '本地翻译处理超时，请稍后重试。',
        'IDENTIFICATION_FAILED' => '无法可靠识别歌词语言，未进行本地翻译。',
        _ => '本地歌词翻译暂时失败，请稍后重试。',
      };
    }
    return '本地歌词翻译暂时失败，请稍后重试。';
  }
}

class _CachedTranslation {
  const _CachedTranslation(this.result);
  final LyricTranslation result;
  String get sourceLanguage => result.sourceLanguage!;
}

class _ParsedLyrics {
  const _ParsedLyrics(this.rows, this.uniqueLines, this.hasTimestamps)
    : error = null;
  const _ParsedLyrics.invalid(this.error)
    : rows = const [],
      uniqueLines = const [],
      hasTimestamps = false;
  final List<_LyricRow> rows;
  final List<String> uniqueLines;
  final bool hasTimestamps;
  final String? error;
}

class _LyricRow {
  const _LyricRow({
    required this.original,
    required this.ending,
    this.prefix = '',
    this.text,
    this.suffix = '',
  });
  final String original;
  final String ending;
  final String prefix;
  final String? text;
  final String suffix;
}
