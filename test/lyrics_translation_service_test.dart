import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/core/services/lyrics_translation_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('audio_fixer/lyrics_translation');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late List<MethodCall> calls;
  late String identified;
  late bool ready;
  late List<String> missing;
  late Object? translation;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'identifyLanguage':
        return identified;
      case 'modelStatus':
        return {
          'sourceLanguage': identified.split('-').first,
          'ready': ready,
          'missingModels': missing,
          'downloadedModels': ready ? ['zh'] : <String>[],
        };
      case 'downloadModels':
        return {
          'sourceLanguage': identified.split('-').first,
          'ready': true,
          'missingModels': <String>[],
          'downloadedModels': ['zh'],
        };
      case 'translateLines':
        return translation ??
            (call.arguments as Map)['lines']
                .map((line) => '中文译文：$line')
                .toList();
      default:
        throw MissingPluginException();
    }
  }

  PlatformLyricsTranslator translator([Directory? directory]) =>
      PlatformLyricsTranslator(
        channel: channel,
        cacheDirectory: directory ?? temporary,
      );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'lyrics-translation-test-',
    );
    calls = [];
    identified = 'en';
    ready = true;
    missing = [];
    translation = null;
    messenger.setMockMethodCallHandler(channel, handle);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  test(
    'inspect only identifies and checks models; never downloads or translates',
    () async {
      final status = await translator().inspect(
        '[ar:English credits]\n[00:01.20]Hello there',
      );
      expect(status.sourceLanguage, 'en');
      expect(status.ready, isTrue);
      expect(status.canTranslate, isTrue);
      expect(calls.map((call) => call.method), [
        'identifyLanguage',
        'modelStatus',
      ]);
      expect((calls.first.arguments as Map)['text'], 'Hello there');
    },
  );

  test(
    'translation never downloads and exposes missing models honestly',
    () async {
      ready = false;
      missing = ['zh'];
      final service = translator();
      final status = await service.inspect('Hello there');
      expect(status.ready, isFalse);
      expect(status.canTranslate, isTrue);
      expect(status.missingModels, ['zh']);
      final result = await service.translateIfReady('Hello there');
      expect(result.available, isFalse);
      expect(result.message, contains('设置'));
      expect(
        calls.any(
          (call) =>
              call.method == 'downloadModels' ||
              call.method == 'translateLines',
        ),
        isFalse,
      );
    },
  );

  test('only explicit download uses the native download method', () async {
    final service = translator();
    await service.downloadModels('en-US');
    expect(calls.single.method, 'downloadModels');
    expect(calls.single.arguments, {'sourceLanguage': 'en'});
    await expectLater(service.downloadModels('und'), throwsFormatException);
    await expectLater(service.downloadModels('zh'), throwsFormatException);
    expect(calls, hasLength(1));
  });

  test('incomplete download is not reported as success', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => {
        'sourceLanguage': 'en',
        'ready': false,
        'missingModels': ['zh'],
      },
    );
    await expectLater(
      translator().downloadModels('en'),
      throwsA(isA<PlatformException>()),
    );
  });

  for (final language in ['und', 'zh', 'mul', 'xyz']) {
    test('$language never translates or assumes English', () async {
      identified = language;
      final service = translator();
      final status = await service.inspect('Hello there');
      expect(status.canTranslate, isFalse);
      final result = await service.translateIfReady('Hello there');
      expect(result.available, isFalse);
      expect(result.sourceLanguage, language);
      expect(result.message, isNotEmpty);
      expect(calls.every((call) => call.method == 'identifyLanguage'), isTrue);
    });
  }

  test(
    'uses actual identified non-English language and normalizes its region',
    () async {
      identified = 'ja-JP';
      translation = ['我想见你'];
      final result = await translator().translateIfReady('あなたに会いたい');
      expect(result.sourceLanguage, 'ja');
      expect(result.chineseLyrics, '我想见你');
      expect((calls.last.arguments as Map)['sourceLanguage'], 'ja');
    },
  );

  test('preserves exact timestamps, multi-stamps, metadata, offsets and CRLF', () async {
    const original =
        '[ar:Artist]\r\n[ti:Title]\r\n[offset:-250]\r\n\r\n'
        '[00:01.200][01:02.3]  Hello world  \r\n[00:03.00]Good night\r\n[00:09.00]\r\n';
    translation = ['你好世界', '晚安'];
    final result = await translator().translateIfReady(original);
    expect(
      result.chineseLyrics,
      '[ar:Artist]\r\n[ti:Title]\r\n[offset:-250]\r\n'
      '[00:01.200][01:02.3]  你好世界  \r\n[00:03.00]晚安\r\n[00:09.00]\r\n',
    );
    expect((calls.first.arguments as Map)['text'], 'Hello world\nGood night');
    expect((calls.last.arguments as Map)['lines'], [
      'Hello world',
      'Good night',
    ]);
    expect(original, contains('Hello world'));
  });

  test(
    'credits and section headers never enter the language sample or translator',
    () async {
      const original =
          '[00:00.00]作词：某某\nLyrics: Someone\n[Chorus]\nHello there';
      final result = await translator().translateIfReady(original);
      expect(result.available, isTrue);
      expect((calls.first.arguments as Map)['text'], 'Hello there');
      expect((calls.last.arguments as Map)['lines'], ['Hello there']);
      expect(
        result.chineseLyrics,
        startsWith('[00:00.00]作词：某某\nLyrics: Someone\n[Chorus]\n'),
      );
    },
  );

  test(
    'metadata-only and punctuation-only text are not language samples',
    () async {
      for (final original in [
        '',
        ' \n\n',
        '[ar:Someone]\n[ti:English title]',
        '[00:00.00]作词：某某\n[offset:20]',
        '...\n123\n♪',
      ]) {
        expect(
          (await translator().translateIfReady(original)).available,
          isFalse,
        );
      }
      expect(calls, isEmpty);
    },
  );

  test(
    'repeated lyrics translate exactly once and retain each timestamp',
    () async {
      translation = ['你好'];
      final result = await translator().translateIfReady(
        '[00:01.00]Hello\n[00:02.00]Hello\nHello',
      );
      expect((calls.last.arguments as Map)['lines'], ['Hello']);
      expect(result.chineseLyrics, '[00:01.00]你好\n[00:02.00]你好\n你好');
    },
  );

  test(
    'engine line breaks stay intact without inventing time alignment',
    () async {
      translation = ['你好\n世界', '晚安'];
      final result = await translator().translateIfReady(
        '[00:01.00]Hello\n[00:02.00]Good night',
      );
      expect(result.chineseLyrics, '[00:01.00]你好\n世界\n[00:02.00]晚安');
      expect(result.message, contains('没有独立时间轴'));
    },
  );

  test(
    'plain multiline translation preserves input and engine line breaks',
    () async {
      translation = ['你好\n朋友', '晚安'];
      final result = await translator().translateIfReady('Hello\n\nGood night');
      expect(result.chineseLyrics, '你好\n朋友\n晚安');
    },
  );

  test(
    'enhanced and inline LRC is rejected instead of destroying word timing',
    () async {
      for (final original in [
        '[00:01.00]<00:01.00>Hello <00:01.20>world',
        'Hello [00:02.00]world',
      ]) {
        final result = await translator().translateIfReady(original);
        expect(result.available, isFalse);
        expect(result.message, contains('时间'));
      }
      expect(calls, isEmpty);
    },
  );

  test(
    'in-flight duplicate calls share identification and local translation',
    () async {
      final gate = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'translateLines') await gate.future;
        return handle(call);
      });
      final service = translator();
      final first = service.translateIfReady('Hello there');
      final second = service.translateIfReady('Hello there');
      gate.complete();
      final results = await Future.wait([first, second]);
      expect(results.every((result) => result.available), isTrue);
      expect(calls.map((call) => call.method), [
        'identifyLanguage',
        'modelStatus',
        'translateLines',
      ]);
    },
  );

  test(
    'memory and persistent cache reuse translated text across instances',
    () async {
      final service = translator();
      final first = await service.translateIfReady('[00:01.00]Hello there');
      expect(
        (await service.translateIfReady('[00:01.00]Hello there')).chineseLyrics,
        first.chineseLyrics,
      );
      expect(
        (await translator().translateIfReady('[00:01.00]Hello there'))
            .chineseLyrics,
        first.chineseLyrics,
      );
      expect(
        calls.where((call) => call.method == 'translateLines'),
        hasLength(1),
      );
      final files = await temporary.list().toList();
      expect(files, hasLength(1));
      final raw = await (files.single as File).readAsString();
      expect(raw, contains('mlkit-local-zh-v1'));
      expect(raw, isNot(contains('"original"')));
    },
  );

  test(
    'exact original timestamps and identified language belong to cache key',
    () async {
      final service = translator();
      await service.translateIfReady('[00:01.00]Hello there');
      await service.translateIfReady('[00:02.00]Hello there');
      identified = 'fr';
      await service.translateIfReady('[00:02.00]Hello there');
      expect(
        calls.where((call) => call.method == 'translateLines'),
        hasLength(3),
      );
    },
  );

  test(
    'storage failure falls back to bounded memory without losing translation',
    () async {
      final file = File(p.join(temporary.path, 'not-a-directory'));
      await file.writeAsString('block directory creation');
      final service = translator(Directory(file.path));
      expect((await service.translateIfReady('Hello')).available, isTrue);
      expect((await service.translateIfReady('Hello')).available, isTrue);
      expect(
        calls.where((call) => call.method == 'translateLines'),
        hasLength(1),
      );
    },
  );

  test(
    'corrupt and obsolete caches are ignored and replaced atomically',
    () async {
      final file = File(p.join(temporary.path, 'translations-v1.json'));
      for (final value in [
        '{broken',
        jsonEncode({'engine': 'old', 'entries': []}),
      ]) {
        await file.writeAsString(value);
        expect(
          (await translator().translateIfReady('Hello')).available,
          isTrue,
        );
        expect(
          (jsonDecode(await file.readAsString()) as Map)['engine'],
          'mlkit-local-zh-v1',
        );
        expect(
          (await temporary.list().toList()).where(
            (file) => file.path.endsWith('.tmp'),
          ),
          isEmpty,
        );
      }
      expect(
        calls.where((call) => call.method == 'translateLines'),
        hasLength(2),
      );
    },
  );

  test(
    'missing plugin and native errors are safe user-readable failures',
    () async {
      for (final error in [
        MissingPluginException(),
        PlatformException(code: 'MODELS_MISSING'),
        PlatformException(code: 'IDENTIFICATION_FAILED'),
        PlatformException(code: 'UNSUPPORTED_LANGUAGE'),
        PlatformException(code: 'BUSY'),
        PlatformException(code: 'TIMEOUT'),
        PlatformException(
          code: 'TRANSLATION_FAILED',
          message: 'sensitive lyric payload',
        ),
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => throw error);
        final result = await translator().translateIfReady('Hello');
        expect(result.available, isFalse);
        expect(result.message, isNotEmpty);
        expect(result.message, isNot(contains('sensitive lyric payload')));
      }
    },
  );

  test('malformed model status cannot start translation', () async {
    for (final status in [
      null,
      'ready',
      {'ready': true},
      {'ready': true, 'sourceLanguage': 'fr', 'missingModels': []},
      {
        'ready': true,
        'sourceLanguage': 'en',
        'missingModels': [3],
      },
      {
        'ready': true,
        'sourceLanguage': 'en',
        'missingModels': ['zh'],
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'identifyLanguage' ? 'en' : status;
      });
      expect((await translator().translateIfReady('Hello')).available, isFalse);
    }
    expect(calls.any((call) => call.method == 'translateLines'), isFalse);
  });

  test(
    'malformed, empty, non-Chinese, echoed or retimed output is not cached',
    () async {
      final service = translator();
      for (final value in [
        <String>[],
        ['你好', '额外一行'],
        [null],
        [''],
        ['Hello'],
        ['Bonjour'],
        ['[00:04.00]你好'],
        ['[offset:10]你好'],
        ['<00:04.00>你好'],
        ['你\u0000好'],
        ['中' * 8001],
      ]) {
        translation = value;
        expect(
          (await service.translateIfReady('[00:01.00]Hello')).available,
          isFalse,
        );
      }
      translation = ['你好'];
      expect(
        (await service.translateIfReady('[00:01.00]Hello')).available,
        isTrue,
      );
      expect(
        calls.where((call) => call.method == 'translateLines'),
        hasLength(12),
      );
    },
  );

  test(
    'mixed-language identical Chinese echo is not accepted as translation',
    () async {
      translation = ['你好', '我爱你'];
      final result = await translator().translateIfReady('Hello\n我爱你');
      expect(result.available, isFalse);
    },
  );

  test(
    'input bounds are enforced before any channel calls without truncation',
    () async {
      final oversized = [
        'a' * 100001,
        'a' * 2001,
        List.generate(301, (i) => 'line $i').join('\n'),
        List.generate(20, (i) => 'line $i ${'a' * 1000}').join('\n'),
        List.filled(2001, 'Hi').join('\n'),
      ];
      for (final original in oversized) {
        expect((await translator().inspect(original)).ready, isFalse);
        expect(
          (await translator().translateIfReady(original)).available,
          isFalse,
        );
      }
      expect(calls, isEmpty);
    },
  );

  test(
    'full 20k translation input is preserved while language sample is bounded',
    () async {
      final lines = List.generate(10, (index) => '$index${'a' * 1999}');
      final result = await translator().translateIfReady(lines.join('\n'));
      expect(result.available, isTrue);
      expect(
        ((calls.first.arguments as Map)['text'] as String).length,
        lessThanOrEqualTo(20000),
      );
      expect((calls.last.arguments as Map)['lines'], lines);
    },
  );

  test('300 short unique lines and 2000-character line are accepted', () async {
    final service = translator();
    expect(
      (await service.translateIfReady(
        List.generate(300, (i) => 'Hello $i').join('\n'),
      )).available,
      isTrue,
    );
    expect((await service.translateIfReady('a' * 2000)).available, isTrue);
  });

  test(
    'cache retains at most 256 entries and evicts oldest translation',
    () async {
      final service = translator();
      for (var index = 0; index < 257; index++) {
        expect(
          (await service.translateIfReady('Hello $index')).available,
          isTrue,
        );
      }
      final file = File(p.join(temporary.path, 'translations-v1.json'));
      final raw = jsonDecode(await file.readAsString()) as Map;
      expect(raw['entries'], hasLength(256));
      expect(await file.length(), lessThanOrEqualTo(4 * 1024 * 1024));
      await service.translateIfReady('Hello 0');
      expect(
        calls.where((call) => call.method == 'translateLines'),
        hasLength(258),
      );
    },
  );

  test('cache prunes by UTF-8 bytes even before entry limit', () async {
    final service = translator();
    translation = [for (var i = 0; i < 10; i++) '中' * 7000];
    for (var index = 0; index < 24; index++) {
      final original = List.generate(10, (i) => 'Hello $index $i').join('\n');
      expect((await service.translateIfReady(original)).available, isTrue);
    }
    final file = File(p.join(temporary.path, 'translations-v1.json'));
    final raw = jsonDecode(await file.readAsString()) as Map;
    expect((raw['entries'] as List).length, lessThan(24));
    expect(await file.length(), lessThanOrEqualTo(4 * 1024 * 1024));
  });
  test(
    'damaged persistent translation cannot change the original timestamps',
    () async {
      const original = '[offset:50]\n[00:01.00]Hello';
      await translator().translateIfReady(original);
      final file = File(p.join(temporary.path, 'translations-v1.json'));
      final raw = jsonDecode(await file.readAsString()) as Map;
      final entry = (raw['entries'] as List).single as Map;
      entry['lyrics'] = '[offset:500]\n[00:20.00]错误';
      await file.writeAsString(jsonEncode(raw));
      final result = await translator().translateIfReady(original);
      expect(result.chineseLyrics, '[offset:50]\n[00:01.00]中文译文：Hello');
      expect(
        calls.where((call) => call.method == 'translateLines'),
        hasLength(2),
      );
    },
  );
}
