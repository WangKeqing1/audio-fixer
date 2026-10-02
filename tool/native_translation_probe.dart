// Standalone, test-only AOT entrypoint. This is never lib/main.dart.
// The host installs a second APK with no INTERNET permission, preserving data,
// and reads only this probe's bounded, synthetic JSON result from logcat.
import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/core/models/lyrics_content.dart';
import 'package:audio_fixer/core/services/lyrics_translation_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _phase = String.fromEnvironment('AUDIO_FIXER_TRANSLATION_PROBE_PHASE');
const _channel = MethodChannel('audio_fixer/lyrics_translation');
const _resultMarker = 'AUDIO_FIXER_TRANSLATION_RESULT:';
const _english = [
  'The bright sun rises above the quiet blue river.',
  'The silver moon shines over the sleeping green garden.',
];
const _french = [
  'Le soleil brille au-dessus de la rivière tranquille.',
  'La lune éclaire le jardin pendant la nuit.',
];
const _offlineEnglish = [
  'The small yellow bird is flying above the peaceful forest.',
  'The white boat is floating slowly toward the distant mountain.',
];
const _offlineFrench = [
  'Le petit oiseau jaune vole au-dessus de la forêt paisible.',
  'Le bateau blanc avance lentement vers la montagne lointaine.',
];
final _progress = ValueNotifier<String>('Starting synthetic translation probe');

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<Map<String, dynamic>> _status(String language) async =>
    Map<String, dynamic>.from(
      (await _channel.invokeMapMethod<String, dynamic>('modelStatus', {
        'sourceLanguage': language,
      }))!,
    );

Future<List<String>> _translate(String language, List<String> lines) async =>
    (await _channel.invokeListMethod<String>('translateLines', {
      'sourceLanguage': language,
      'lines': lines,
    }))!;

Future<String> _expectNativeError(
  Future<Object?> Function() call,
  String expectedCode,
) async {
  try {
    await call();
  } on PlatformException catch (error) {
    _require(
      error.code == expectedCode,
      'Expected $expectedCode, got ${error.code}',
    );
    return error.code;
  }
  throw StateError('Expected explicit native failure without a translation');
}

Future<Map<String, Object?>> _probe() async {
  _require(Platform.isAndroid, 'Disposable Android emulator required');
  _require(
    _phase == 'download' || _phase == 'offline',
    'Explicit download or offline probe phase required',
  );
  final support = await getApplicationSupportDirectory();
  final sentinel = File('${support.path}/native_translation_sentinel.json');
  final checks = <String>[];
  final results = <String, List<String>>{};
  final errors = <String, String>{};
  final translator = PlatformLyricsTranslator(
    cacheDirectory: Directory('${support.path}/translation-probe-cache'),
  );
  if (_phase == 'download') {
    _require(
      !await sentinel.exists(),
      'Only a fresh disposable probe install is supported',
    );
    await sentinel.writeAsString(
      jsonEncode({
        'synthetic_only': true,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'original_lines': _english,
      }),
      flush: true,
    );
  } else {
    _require(
      await sentinel.exists(),
      'Upgrade lost app-private probe/model data',
    );
  }
  final sentinelBytes = await sentinel.readAsBytes();
  final persisted = jsonDecode(utf8.decode(sentinelBytes)) as Map;
  _require(
    persisted['synthetic_only'] == true,
    'Synthetic provenance is missing',
  );
  _require(
    jsonEncode(persisted['original_lines']) == jsonEncode(_english),
    'Original synthetic text was changed',
  );
  checks.add('original_synthetic_text_preserved');
  final sentinelHash = sha256.convert(sentinelBytes).toString();

  errors['unsupported_language'] = await _expectNativeError(
    () => _channel.invokeMethod<Object>('modelStatus', {
      'sourceLanguage': 'xx-invalid',
    }),
    'UNSUPPORTED_LANGUAGE',
  );
  errors['invalid_lines'] = await _expectNativeError(
    () => _channel.invokeMethod<Object>('translateLines', {
      'sourceLanguage': 'en',
      'lines': 'This is not an array',
    }),
    'INVALID_ARGUMENT',
  );
  checks.add('native_invalid_input_fails_explicitly');

  final fixtures = _phase == 'download'
      ? {'en': _english, 'fr': _french}
      : {'en': _offlineEnglish, 'fr': _offlineFrench};
  for (final fixture in fixtures.entries) {
    final language = fixture.key;
    final source = fixture.value;
    final originalLyrics =
        '[offset:+120]\n[00:01.00][00:04.00]${source[0]}\n[00:02.50]${source[1]}';
    _progress.value = '$_phase: checking synthetic $language text';
    final detected = await _channel.invokeMethod<String>('identifyLanguage', {
      'text': source.join(' '),
    });
    _require(
      detected == language,
      'Bundled language identification failed for $language',
    );
    checks.add('${language}_language_identified_locally');
    final before = await _status(language);
    if (_phase == 'download') {
      _require(
        before['ready'] == false,
        'Fresh emulator unexpectedly already has $language models',
      );
      final priorModels = jsonEncode(before['downloadedModels']);
      errors['${language}_missing_models'] = await _expectNativeError(
        () => _translate(language, source),
        'MODELS_MISSING',
      );
      final unavailable = await translator.translateIfReady(originalLyrics);
      _require(
        !unavailable.available && unavailable.chineseLyrics == null,
        'Missing-model service result fabricated translated lyrics',
      );
      _require(
        LyricsContent(
              originalLyrics,
              chineseTranslation: unavailable.chineseLyrics,
            ).render(includeTranslation: true) ==
            originalLyrics,
        'Missing-model failure did not preserve original lyrics exactly',
      );
      checks.add('${language}_missing_model_preserves_original_lyrics');
      final afterFailure = await _status(language);
      _require(
        afterFailure['ready'] == false,
        'Translate implicitly downloaded missing models',
      );
      _require(
        jsonEncode(afterFailure['downloadedModels']) == priorModels,
        'Missing-model failure changed downloaded models',
      );
      checks.add('${language}_missing_models_do_not_auto_download');
      _progress.value = 'Downloading official $language → Chinese models';
      final downloaded = await _channel
          .invokeMapMethod<String, dynamic>('downloadModels', {
            'sourceLanguage': language,
            'requireWifi': true,
          })
          .timeout(const Duration(minutes: 8));
      _require(
        downloaded?['ready'] == true,
        '$language model download did not complete',
      );
    }
    final ready = await _status(language);
    _require(
      ready['ready'] == true,
      '$language models unavailable after $_phase setup',
    );
    _require(
      (ready['missingModels'] as List).isEmpty,
      '$language still has missing models',
    );
    checks.add('${language}_models_ready');
    _progress.value = '$_phase: translating synthetic $language text locally';
    final translated = await _translate(
      language,
      source,
    ).timeout(const Duration(minutes: 2));
    _require(
      translated.length == source.length,
      'Translation lost line count/order contract',
    );
    for (var index = 0; index < source.length; index++) {
      _require(
        translated[index].trim().isNotEmpty,
        'Translation returned an empty line',
      );
      _require(
        translated[index] != source[index],
        'Translation returned the source unchanged',
      );
      _require(
        RegExp(r'[\u3400-\u9fff]').hasMatch(translated[index]),
        'Translation has no Chinese characters',
      );
    }
    final ordered = await _translate(language, [
      source[0],
      '',
      source[1],
      source[0],
    ]);
    _require(
      ordered.length == 4 && ordered[1].isEmpty,
      'Native translation lost blank-line position',
    );
    _require(
      ordered[0] == translated[0] &&
          ordered[2] == translated[1] &&
          ordered[3] == ordered[0],
      'Native translation changed duplicate-line determinism or order',
    );
    checks.add('${language}_blank_and_duplicate_line_order_preserved');
    final translatedLyrics = await translator.translateIfReady(originalLyrics);
    _require(
      translatedLyrics.available && translatedLyrics.chineseLyrics != null,
      'Real platform translation service did not return Chinese lyrics',
    );
    final chineseLyrics = translatedLyrics.chineseLyrics!;
    _require(
      chineseLyrics != originalLyrics &&
          RegExp(r'[\u3400-\u9fff]').hasMatch(chineseLyrics),
      'Real service translation returned no Chinese change',
    );
    final timestamp = RegExp(r'\[\d{1,3}:[0-5]\d(?:[.:]\d{1,3})?\]');
    _require(
      jsonEncode(
            timestamp
                .allMatches(chineseLyrics)
                .map((match) => match.group(0))
                .toList(),
          ) ==
          jsonEncode(
            timestamp
                .allMatches(originalLyrics)
                .map((match) => match.group(0))
                .toList(),
          ),
      'Translation changed LRC timestamps, multi-stamps, or line order',
    );
    _require(
      chineseLyrics.contains('[offset:+120]'),
      'Translation changed LRC offset',
    );
    checks.add('${language}_real_service_preserves_lrc_timestamps_and_offset');
    results[language] = translated;
    checks.add('${language}_real_native_chinese_translation');
  }
  _require(
    sha256.convert(await sentinel.readAsBytes()).toString() == sentinelHash,
    'Translation mutated original persisted text',
  );
  return {
    'passed': true,
    'phase': _phase,
    'synthetic_only': true,
    'mocked_native_channels': false,
    'model_download_requested': _phase == 'download',
    'phase_specific_fresh_synthetic_inputs': true,
    'sentinel_sha256': sentinelHash,
    'checks': checks,
    'native_errors': errors,
    'translations': results,
  };
}

Map<String, Object> _nativeFailureDetails(Object? details) {
  if (details is! Map) return const {};
  const stages = {
    'validate_arguments',
    'initialize_sdk',
    'create_language_identifier',
    'identify_language',
    'read_model_status',
    'download_models',
    'create_translator',
    'translate_line',
  };
  final value = <String, Object>{};
  final stage = details['stage'];
  if (stage is String && stages.contains(stage)) value['stage'] = stage;
  final types = details['exceptionTypes'];
  if (types is List) {
    value['exceptionTypes'] = types
        .take(3)
        .whereType<String>()
        .where((type) => RegExp(r'^[A-Za-z0-9_.$]{1,160}$').hasMatch(type))
        .toList();
  }
  final code = details['mlKitErrorCode'];
  if (code is int) value['mlKitErrorCode'] = code;
  return value;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Synthetic translation acceptance')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<String>(
            valueListenable: _progress,
            builder: (_, value, _) => Text(value),
          ),
        ),
      ),
    ),
  );
  Map<String, Object?> result;
  try {
    result = await _probe();
    _progress.value = '$_phase passed: synthetic English and French → Chinese';
  } catch (error) {
    result = {
      'passed': false,
      'phase': _phase,
      'synthetic_only': true,
      'error': error is PlatformException
          ? 'Native operation failed; see bounded code/type diagnostics'
          : error.toString().substring(
              0,
              error.toString().length.clamp(0, 400),
            ),
      if (error is PlatformException) ...{
        'error_code': RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(error.code)
            ? error.code
            : 'PLATFORM_ERROR',
        'native_details': _nativeFailureDetails(error.details),
      },
    };
    _progress.value = '$_phase failed; see bounded synthetic check result';
  }
  // AOT probe needs no VM-service socket, debug flag, storage permission, or
  // online result endpoint. Host only captures this exact synthetic JSON marker.
  // ignore: avoid_print
  print('$_resultMarker${jsonEncode(result)}');
}
