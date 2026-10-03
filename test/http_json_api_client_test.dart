import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/core/services/sources/http_json_api_client.dart';
import 'package:audio_fixer/core/models/source_query_report.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Clock {
  DateTime value = DateTime.utc(2026);
  final pauses = <Duration>[];
  DateTime now() => value;
  void advance(Duration duration) => value = value.add(duration);
  Future<void> pause(Duration duration) async {
    pauses.add(duration);
    advance(duration);
  }
}

Uri _lyrics([String title = '夜曲', String duration = '240']) => Uri.https(
  'lrclib.net',
  '/api/get',
  {'track_name': title, 'artist_name': '周杰伦', 'duration': duration},
);

HttpJsonApiClient _client(
  _Clock clock,
  ApiTransport transport, {
  Directory? cacheDirectory,
  int maxCacheEntries = 256,
  int maxCacheBytes = 4 * 1024 * 1024,
  int maxInFlightRequests = 128,
}) => HttpJsonApiClient(
  now: clock.now,
  pause: clock.pause,
  transport: transport,
  cacheDirectory: cacheDirectory,
  maxCacheEntries: maxCacheEntries,
  maxCacheBytes: maxCacheBytes,
  maxInFlightRequests: maxInFlightRequests,
);

Future<ApiException> _failure(Future<Object?> request) async {
  try {
    await request;
  } on ApiException catch (error) {
    return error;
  }
  fail('Expected ApiException');
}

void main() {
  test('NetEase detail endpoint is allowed, deduplicated and empty results expire on negative TTL', () async {
    final clock = _Clock();
    var calls = 0;
    final client = _client(clock, (_, _) async {
      calls++;
      return const ApiResponse(200, '{"code":200,"songs":[]}');
    });
    final uri = Uri.https('music.163.com', '/api/song/detail', {
      'ids': '[123]',
    });
    await Future.wait([client.getJson(uri), client.getJson(uri)]);
    expect(calls, 1);
    clock.advance(const Duration(minutes: 9));
    await client.getJson(uri);
    expect(calls, 1);
    clock.advance(const Duration(minutes: 2));
    await client.getJson(uri);
    expect(calls, 2);
    await _failure(
      client.getJson(Uri.https('music.163.com', '/api/user/detail')),
    );
    expect(calls, 2);
  });

  test(
    'malformed NetEase success envelope is not stored as a success',
    () async {
      final clock = _Clock();
      var calls = 0;
      final client = _client(clock, (_, _) async {
        calls++;
        return const ApiResponse(200, '{}');
      });
      final uri = Uri.https('music.163.com', '/api/search/get');
      await _failure(client.getJson(uri));
      await _failure(client.getJson(uri));
      expect(calls, 1);
      clock.advance(const Duration(seconds: 30));
      await _failure(client.getJson(uri));
      expect(calls, 2);
    },
  );

  for (final code in [301, 401, 403, 400]) {
    test(
      'NetEase HTTP200 code$code stays an error and cools down the provider',
      () async {
        final clock = _Clock();
        var calls = 0;
        final client = _client(clock, (_, _) async {
          calls++;
          return ApiResponse(200, jsonEncode({'code': code}));
        });
        final uri = Uri.https('music.163.com', '/api/search/get', {'s': '夜曲'});
        final error = await _failure(client.getJson(uri));
        expect(error.statusCode, code);
        expect(error.retryAfter, clock.now().add(const Duration(seconds: 30)));
        expect((await _failure(client.getJson(uri))).statusCode, code);
        expect(calls, 1);
        clock.advance(const Duration(seconds: 30));
        await _failure(client.getJson(uri));
        expect(calls, 2);
      },
    );
  }

  for (final payload in [
    {
      'code': 200,
      'result': {'songs': []},
    },
    {'code': 200, 'result': <String, Object?>{}},
    {
      'code': 200,
      'lrc': {'lyric': ''},
    },
    {'code': 200, 'uncollected': true},
  ]) {
    test(
      'NetEase empty payload $payload uses the short negative TTL',
      () async {
        final clock = _Clock();
        var calls = 0;
        final client = _client(clock, (_, _) async {
          calls++;
          return ApiResponse(200, jsonEncode(payload));
        });
        final path = payload.containsKey('result')
            ? '/api/search/get'
            : '/api/song/lyric';
        final uri = Uri.https('music.163.com', path, {'id': '123'});
        await client.getJson(uri);
        clock.advance(const Duration(minutes: 9));
        await client.getJson(uri);
        expect(calls, 1);
        clock.advance(const Duration(minutes: 1));
        await client.getJson(uri);
        expect(calls, 2);
      },
    );
  }

  test(
    'an interrupted staging file is reused and does not accumulate',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-http-');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/source-http-cache-v1.json.tmp')
          .writeAsString('interrupted');
      final client = _client(
        _Clock(),
        (_, _) async => const ApiResponse(200, '{"id":1}'),
        cacheDirectory: directory,
      );
      await client.getJson(_lyrics());
      final files = await directory.list().toList();
      expect(files, hasLength(1));
      expect(files.single.path.endsWith('source-http-cache-v1.json'), isTrue);
    },
  );

  test('disabling the cache does not disable provider throttling', () async {
    final clock = _Clock();
    var calls = 0;
    final client = _client(
      clock,
      (_, _) async {
        calls++;
        return const ApiResponse(200, '{"id":1}');
      },
      maxCacheEntries: 0,
      maxCacheBytes: 0,
    );
    await client.getJson(_lyrics());
    await client.getJson(_lyrics());
    expect(calls, 2);
    expect(clock.pauses, [const Duration(milliseconds: 400)]);
  });

  test(
    'same canonical URI shares one in-flight request and independent JSON',
    () async {
      final started = Completer<void>();
      final response = Completer<ApiResponse>();
      var calls = 0;
      final client = _client(_Clock(), (_, _) {
        calls++;
        started.complete();
        return response.future;
      });
      final first = client.getJson(_lyrics());
      await started.future;
      final second = client.getJson(_lyrics().replace(fragment: 'ignored'));
      response.complete(const ApiResponse(200, '{"lyrics":["夜曲"]}'));
      final results = await Future.wait([first, second]);
      expect(calls, 1);
      (results[0] as Map)['lyrics'] = 'mutated';
      expect(results[1], {
        'lyrics': ['夜曲'],
      });
      expect(await client.getJson(_lyrics()), {
        'lyrics': ['夜曲'],
      });
      expect(calls, 1);
    },
  );

  test(
    'album, duration, title and repeated-query differences never share cache',
    () async {
      var calls = 0;
      final client = _client(_Clock(), (uri, _) async {
        calls++;
        return ApiResponse(200, jsonEncode({'uri': uri.toString()}));
      });
      final uris = [
        _lyrics(),
        _lyrics('夜曲', '241'),
        _lyrics('夜曲 (Live)'),
        _lyrics().replace(
          queryParameters: {
            ..._lyrics().queryParameters,
            'album_name': '十一月的萧邦',
          },
        ),
        _lyrics().replace(query: '${_lyrics().query}&duration=241'),
      ];
      for (final uri in uris) {
        expect(await client.getJson(uri), {'uri': uri.toString()});
      }
      expect(calls, uris.length);
    },
  );

  test('positive JSON expires at 24 hours', () async {
    final clock = _Clock();
    var calls = 0;
    final client = _client(clock, (_, _) async {
      calls++;
      return const ApiResponse(200, '{"plainLyrics":"歌词"}');
    });
    await client.getJson(_lyrics());
    clock.advance(const Duration(hours: 23, minutes: 59));
    await client.getJson(_lyrics());
    expect(calls, 1);
    clock.advance(const Duration(minutes: 1));
    await client.getJson(_lyrics());
    expect(calls, 2);
  });

  for (final response in [
    const ApiResponse(404, ''),
    const ApiResponse(200, 'null'),
    const ApiResponse(200, '[]'),
    const ApiResponse(200, '{}'),
    const ApiResponse(200, '{"recordings":[]}'),
    const ApiResponse(200, '{"images":[]}'),
    const ApiResponse(200, '{"plainLyrics":null,"syncedLyrics":""}'),
  ]) {
    test(
      'no-match ${response.statusCode}/${response.body} expires after 10 minutes',
      () async {
        final clock = _Clock();
        var calls = 0;
        final client = _client(clock, (_, _) async {
          calls++;
          return response;
        });
        await client.getJson(_lyrics());
        clock.advance(const Duration(minutes: 9));
        await client.getJson(_lyrics());
        expect(calls, 1);
        clock.advance(const Duration(minutes: 1));
        await client.getJson(_lyrics());
        expect(calls, 2);
      },
    );
  }

  test('LRU cache evicts oldest untouched entry at its entry bound', () async {
    var calls = 0;
    final client = _client(_Clock(), (_, _) async {
      calls++;
      return const ApiResponse(200, '{"id":1}');
    }, maxCacheEntries: 2);
    await client.getJson(_lyrics('A'));
    await client.getJson(_lyrics('B'));
    await client.getJson(_lyrics('A'));
    await client.getJson(_lyrics('C'));
    await client.getJson(_lyrics('A'));
    expect(calls, 3);
    await client.getJson(_lyrics('B'));
    expect(calls, 4);
  });

  test(
    'cache byte bound includes encoded keys and JSON and skips huge entries',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-http-');
      addTearDown(() => directory.delete(recursive: true));
      var calls = 0;
      final client = _client(
        _Clock(),
        (_, _) async {
          calls++;
          return ApiResponse(200, jsonEncode({'lyrics': '歌' * 500}));
        },
        cacheDirectory: directory,
        maxCacheBytes: 1000,
      );
      await client.getJson(_lyrics());
      await client.getJson(_lyrics());
      expect(calls, 2);
      expect(await directory.list().isEmpty, isTrue);
    },
  );

  test(
    'cache byte budget evicts entries before writing durable snapshot',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-http-');
      addTearDown(() => directory.delete(recursive: true));
      final client = _client(
        _Clock(),
        (_, _) async => ApiResponse(200, jsonEncode({'lyrics': 'a' * 100})),
        cacheDirectory: directory,
        maxCacheBytes: 1000,
      );
      for (var i = 0; i < 10; i++) {
        await client.getJson(_lyrics('track$i'));
      }
      final file = (await directory.list().toList()).single as File;
      final data = jsonDecode(await file.readAsString()) as Map;
      final entries = data['responses'] as List;
      expect(entries.length, lessThan(10));
      final bytes = entries.fold<int>(
        0,
        (total, entry) => total + utf8.encode(jsonEncode(entry)).length + 1,
      );
      expect(bytes, lessThanOrEqualTo(1000));
      expect(await file.length(), lessThan(1100));
    },
  );

  test(
    'bounded queue deduplicates existing request even when capacity is full',
    () async {
      final started = Completer<void>();
      final response = Completer<ApiResponse>();
      var calls = 0;
      final client = _client(_Clock(), (_, _) {
        calls++;
        started.complete();
        return response.future;
      }, maxInFlightRequests: 1);
      final first = client.getJson(_lyrics());
      await started.future;
      final duplicate = client.getJson(_lyrics());
      await _failure(client.getJson(_lyrics('another')));
      expect(calls, 1);
      response.complete(const ApiResponse(200, '{}'));
      await Future.wait([first, duplicate]);
    },
  );

  test(
    'successful and negative results survive a client restart until expiry',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-http-');
      addTearDown(() => directory.delete(recursive: true));
      final clock = _Clock();
      var calls = 0;
      Future<ApiResponse> transport(Uri uri, Map<String, String> _) async {
        calls++;
        return uri.queryParameters['track_name'] == 'missing'
            ? const ApiResponse(404, '')
            : const ApiResponse(200, '{"plainLyrics":"歌词"}');
      }

      final first = _client(clock, transport, cacheDirectory: directory);
      await first.getJson(_lyrics());
      await first.getJson(_lyrics('missing'));
      final second = _client(clock, transport, cacheDirectory: directory);
      expect(await second.getJson(_lyrics()), {'plainLyrics': '歌词'});
      expect(await second.getJson(_lyrics('missing')), isNull);
      expect(calls, 2);
      clock.advance(const Duration(minutes: 10));
      final third = _client(clock, transport, cacheDirectory: directory);
      await third.getJson(_lyrics('missing'));
      expect(calls, 3);
    },
  );

  test('corrupt and unavailable persistence never block lookup', () async {
    final directory = await Directory.systemTemp.createTemp('source-http-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/source-http-cache-v1.json');
    await file.writeAsString('{broken');
    var calls = 0;
    Future<ApiResponse> transport(Uri _, Map<String, String> _) async {
      calls++;
      return const ApiResponse(200, '{"id":1}');
    }

    expect(
      await _client(
        _Clock(),
        transport,
        cacheDirectory: directory,
      ).getJson(_lyrics()),
      {'id': 1},
    );
    // A regular file cannot be used as a directory. This fails without needing
    // OS-specific permissions or chmod (tests may run as root).
    expect(
      await _client(
        _Clock(),
        transport,
        cacheDirectory: Directory(file.path),
      ).getJson(_lyrics()),
      {'id': 1},
    );
    expect(calls, 2);
  });

  test(
    'queries containing credentials are never cached to disk or memory',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-http-');
      addTearDown(() => directory.delete(recursive: true));
      var calls = 0;
      final client = _client(_Clock(), (_, _) async {
        calls++;
        return const ApiResponse(200, '{"id":1}');
      }, cacheDirectory: directory);
      final uri = _lyrics().replace(
        queryParameters: {'access_token': 'test-secret'},
      );
      await client.getJson(uri);
      await client.getJson(uri);
      expect(calls, 2);
      expect(await directory.list().isEmpty, isTrue);
    },
  );

  test('a slow host does not block independent data sources', () async {
    final lyricsResponse = Completer<ApiResponse>();
    final lyricsStarted = Completer<void>();
    final client = HttpJsonApiClient(
      transport: (uri, _) {
        if (uri.host == 'lrclib.net') {
          lyricsStarted.complete();
          return lyricsResponse.future;
        }
        return Future.value(const ApiResponse(200, '{"recordings":[]}'));
      },
    );
    final lyrics = client.getJson(_lyrics());
    await lyricsStarted.future;
    try {
      expect(
        await client
            .getJson(Uri.https('musicbrainz.org', '/ws/2/recording/'))
            .timeout(const Duration(seconds: 1)),
        {'recordings': []},
      );
    } finally {
      lyricsResponse.complete(const ApiResponse(404, ''));
      await lyrics;
    }
  });

  test('gap starts after response completion, not request start', () async {
    final clock = _Clock();
    final starts = <DateTime>[];
    final ends = <DateTime>[];
    var active = 0;
    final client = _client(clock, (_, _) async {
      expect(active++, 0);
      starts.add(clock.now());
      clock.advance(const Duration(seconds: 4));
      await Future<void>.value();
      ends.add(clock.now());
      active--;
      return const ApiResponse(200, '{}');
    });
    await Future.wait([
      client.getJson(_lyrics('A')),
      client.getJson(_lyrics('B')),
    ]);
    expect(starts[1].difference(ends[0]), const Duration(milliseconds: 400));
  });

  for (final host in ['musicbrainz.org', 'music.163.com']) {
    test(
      '$host requests have at least 1.1s completion spacing and User-Agent',
      () async {
        final clock = _Clock();
        final starts = <DateTime>[];
        final client = _client(clock, (uri, headers) async {
          starts.add(clock.now());
          expect(headers['User-Agent'], contains('AudioFixer/0.2.0'));
          expect(
            headers['User-Agent'],
            contains('https://github.com/WangKeqing1/audio-fixer'),
          );
          return const ApiResponse(200, '{"code":200,"result":{}}');
        });
        final path = host == 'musicbrainz.org'
            ? '/ws/2/recording/'
            : '/api/search/get';
        await Future.wait([
          client.getJson(Uri.https(host, path, {'query': 'A'})),
          client.getJson(Uri.https(host, path, {'query': 'B'})),
        ]);
        expect(
          starts[1].difference(starts[0]),
          const Duration(milliseconds: 1100),
        );
      },
    );
  }

  test(
    'timeout releases queue, cools down failed host and leaves others usable',
    () async {
      final clock = _Clock();
      var calls = 0;
      final client = HttpJsonApiClient(
        requestTimeout: const Duration(milliseconds: 10),
        now: clock.now,
        pause: clock.pause,
        transport: (uri, _) {
          calls++;
          if (calls == 1) return Completer<ApiResponse>().future;
          return Future.value(const ApiResponse(200, '{}'));
        },
      );
      final first = await _failure(client.getJson(_lyrics()));
      expect(first.retryAfter, clock.now().add(const Duration(seconds: 30)));
      await _failure(client.getJson(_lyrics('second')));
      expect(calls, 1);
      expect(
        await client.getJson(Uri.https('musicbrainz.org', '/ws/2/recording/')),
        isA<Map>(),
      );
      clock.advance(const Duration(seconds: 30));
      expect(await client.getJson(_lyrics('second')), isA<Map>());
      expect(calls, 3);
    },
  );

  test('rate limit blocks queued distinct requests without retrying', () async {
    final clock = _Clock();
    var calls = 0;
    final client = _client(clock, (_, _) async {
      calls++;
      return const ApiResponse(
        429,
        '<html>limited',
        headers: {'Retry-After': '60'},
      );
    });
    final errors = await Future.wait([
      _failure(client.getJson(_lyrics('A'))),
      _failure(client.getJson(_lyrics('B'))),
      _failure(client.getJson(_lyrics('C'))),
    ]);
    expect(calls, 1);
    expect(errors.every((error) => error.statusCode == 429), isTrue);
    expect(
      errors.every(
        (error) =>
            error.retryAfter == clock.now().add(const Duration(seconds: 60)),
      ),
      isTrue,
    );
  });

  test('cooldown preserves actual429 and serverdeadline without freezing or extending', () async {
    final directory = await Directory.systemTemp.createTemp('source-status-');
    addTearDown(() => directory.delete(recursive: true));
    final clock = _Clock();
    final started = clock.now();
    var calls = 0;
    Future<ApiResponse> transport(Uri uri, Map<String, String> headers) async {
      calls++;
      return const ApiResponse(
        429,
        'private response body',
        headers: {'Retry-After': '60', 'Authorization': 'never-display-this'},
      );
    }

    final first = await _failure(
      _client(clock, transport, cacheDirectory: directory).getJson(_lyrics()),
    );
    expect(first.failureKind, SourceFailureKind.rateLimited);
    expect(first.provider, 'lrclib.net');
    expect(first.isLocalCooldown, isFalse);
    expect(first.serverRetryAfter, started.add(const Duration(seconds: 60)));
    clock.advance(const Duration(seconds: 8));
    final restored = _client(clock, transport, cacheDirectory: directory);
    final blocked = await _failure(restored.getJson(_lyrics('another')));
    expect(calls, 1);
    expect(blocked.failureKind, SourceFailureKind.rateLimited);
    expect(blocked.statusCode, 429);
    expect(blocked.isLocalCooldown, isTrue);
    expect(blocked.retryAt, first.retryAt);
    expect(blocked.serverRetryAfter, first.serverRetryAfter);
    expect(blocked.retryAt!.difference(clock.now()).inSeconds, 52);
    expect(blocked.message, isNot(contains('52')));
    expect(blocked.message, isNot(contains('private')));
    clock.advance(const Duration(seconds: 51));
    expect(
      (await _failure(restored.getJson(_lyrics()))).retryAt,
      first.retryAt,
    );
    expect(calls, 1);
    clock.advance(const Duration(seconds: 1));
    await _failure(restored.getJson(_lyrics()));
    expect(calls, 2);
  });

  for (final kind in [
    SourceFailureKind.timeout,
    SourceFailureKind.network,
    SourceFailureKind.invalidResponse,
    SourceFailureKind.serverError,
  ]) {
    test('$kind survives local backoff and never claims HTTP429', () async {
      final clock = _Clock();
      var calls = 0;
      final client = _client(clock, (_, _) async {
        calls++;
        if (kind == SourceFailureKind.timeout) {
          throw TimeoutException('private');
        }
        if (kind == SourceFailureKind.network) {
          throw const SocketException('private');
        }
        return kind == SourceFailureKind.invalidResponse
            ? const ApiResponse(200, '<html>private error</html>')
            : const ApiResponse(503, 'private');
      });
      final first = await _failure(client.getJson(_lyrics()));
      clock.advance(const Duration(seconds: 8));
      final blocked = await _failure(client.getJson(_lyrics('other')));
      expect(first.failureKind, kind);
      expect(blocked.failureKind, kind);
      expect(
        blocked.statusCode,
        kind == SourceFailureKind.serverError ? 503 : null,
      );
      expect(blocked.serverRetryAfter, isNull);
      expect(blocked.retryAt, first.retryAt);
      expect(blocked.message, isNot(contains('繁忙')));
      expect(blocked.message, isNot(contains('429')));
      expect(blocked.message, isNot(contains('private')));
      expect(calls, 1);
    });
  }

  test(
    'cached healthy lyrics survive provider cooldown without a new request',
    () async {
      final clock = _Clock();
      var calls = 0;
      final client = _client(clock, (uri, _) async {
        calls++;
        return uri.queryParameters['track_name'] == 'healthy'
            ? const ApiResponse(200, '{"plainLyrics":"verified cached lyrics"}')
            : const ApiResponse(429, '', headers: {'Retry-After': '60'});
      });
      await client.getJson(_lyrics('healthy'));
      await _failure(client.getJson(_lyrics('limited')));
      expect(await client.getJson(_lyrics('healthy')), {
        'plainLyrics': 'verified cached lyrics',
      });
      expect(calls, 2);
    },
  );

  test('future HTTP-date Retry-After is honored', () async {
    final clock = _Clock();
    var calls = 0;
    final until = clock.now().add(const Duration(minutes: 3));
    final client = _client(clock, (_, _) async {
      calls++;
      return calls == 1
          ? ApiResponse(
              503,
              '',
              headers: {'ReTrY-AfTeR': HttpDate.format(until)},
            )
          : const ApiResponse(200, '{}');
    });
    expect((await _failure(client.getJson(_lyrics()))).retryAfter, until);
    clock.advance(const Duration(minutes: 2, seconds: 59));
    await _failure(client.getJson(_lyrics()));
    expect(calls, 1);
    clock.advance(const Duration(seconds: 1));
    await client.getJson(_lyrics());
    expect(calls, 2);
  });

  for (final retryAfter in [
    '',
    'nonsense',
    '-1',
    '0',
    'Wed, 01 Jan 2025 00:00:00 GMT',
  ]) {
    test(
      'invalid/expired Retry-After "$retryAfter" uses exponential fallback',
      () async {
        final clock = _Clock();
        var calls = 0;
        final client = _client(clock, (_, _) async {
          calls++;
          return ApiResponse(503, '', headers: {'retry-after': retryAfter});
        });
        expect(
          (await _failure(client.getJson(_lyrics()))).retryAfter,
          clock.now().add(const Duration(seconds: 30)),
        );
        await _failure(client.getJson(_lyrics()));
        expect(calls, 1);
        clock.advance(const Duration(seconds: 30));
        expect(
          (await _failure(client.getJson(_lyrics()))).retryAfter,
          clock.now().add(const Duration(seconds: 60)),
        );
        expect(calls, 2);
      },
    );
  }

  test('huge Retry-After cannot overflow into an immediate retry', () async {
    final client = _client(
      _Clock(),
      (_, _) async => const ApiResponse(
        429,
        '',
        headers: {'retry-after': '9999999999999999999999999999999999999'},
      ),
    );
    expect((await _failure(client.getJson(_lyrics()))).retryAfter!.year, 9999);
  });

  test(
    '429 and failure escalation persist across restart and success resets it',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-http-');
      addTearDown(() => directory.delete(recursive: true));
      final clock = _Clock();
      var calls = 0;
      var succeed = false;
      Future<ApiResponse> transport(Uri _, Map<String, String> _) async {
        calls++;
        if (succeed) return const ApiResponse(200, '{"id":1}');
        return const ApiResponse(429, 'limited');
      }

      await _failure(
        _client(clock, transport, cacheDirectory: directory).getJson(_lyrics()),
      );
      final second = _client(clock, transport, cacheDirectory: directory);
      await _failure(second.getJson(_lyrics()));
      expect(calls, 1);
      clock.advance(const Duration(seconds: 30));
      expect(
        (await _failure(second.getJson(_lyrics()))).retryAfter,
        clock.now().add(const Duration(seconds: 60)),
      );
      clock.advance(const Duration(seconds: 60));
      succeed = true;
      await second.getJson(_lyrics());
      succeed = false;
      // Use another URI so a genuine successful cached result remains usable.
      final third = _client(clock, transport, cacheDirectory: directory);
      final error = await _failure(third.getJson(_lyrics('new')));
      expect(error.retryAfter, clock.now().add(const Duration(seconds: 30)));
      expect(await third.getJson(_lyrics()), {'id': 1});
      expect(calls, 4);
    },
  );

  test(
    'network failure backoff doubles across restarts and is capped at 30m',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-http-');
      addTearDown(() => directory.delete(recursive: true));
      final clock = _Clock();
      var calls = 0;
      Future<ApiResponse> transport(Uri _, Map<String, String> _) async {
        calls++;
        throw const SocketException('offline');
      }

      for (final seconds in [30, 60, 120, 240, 480, 960, 1800, 1800]) {
        final client = _client(clock, transport, cacheDirectory: directory);
        final error = await _failure(client.getJson(_lyrics()));
        expect(error.retryAfter, clock.now().add(Duration(seconds: seconds)));
        expect(error.statusCode, isNull);
        await _failure(client.getJson(_lyrics('other')));
        clock.advance(Duration(seconds: seconds));
      }
      expect(calls, 8);
    },
  );

  test(
    'NetEase HTTP200 provider rate limit is neither cached nor retried',
    () async {
      final clock = _Clock();
      var calls = 0;
      final client = _client(clock, (_, _) async {
        calls++;
        return const ApiResponse(200, '{"code":429,"message":"too many"}');
      });
      final uri = Uri.https('music.163.com', '/api/search/get', {'s': '夜曲'});
      expect((await _failure(client.getJson(uri))).statusCode, 429);
      expect((await _failure(client.getJson(uri))).statusCode, 429);
      expect(calls, 1);
      clock.advance(const Duration(seconds: 30));
      await _failure(client.getJson(uri));
      expect(calls, 2);
    },
  );

  test(
    '404 is no-match while invalid JSON and HTTP failures enter cooldown',
    () async {
      final missing = _client(
        _Clock(),
        (_, _) async => const ApiResponse(404, ''),
      );
      expect(await missing.getJson(_lyrics()), isNull);
      for (final response in [
        const ApiResponse(200, '<html>'),
        const ApiResponse(500, ''),
      ]) {
        var calls = 0;
        final clock = _Clock();
        final client = _client(clock, (_, _) async {
          calls++;
          return response;
        });
        final first = await _failure(client.getJson(_lyrics()));
        final blocked = await _failure(client.getJson(_lyrics()));
        expect(calls, 1);
        expect(blocked.failureKind, first.failureKind);
        expect(blocked.isLocalCooldown, isTrue);
        expect(blocked.retryAfter, first.retryAfter);
        clock.advance(const Duration(seconds: 30));
        final second = await _failure(client.getJson(_lyrics()));
        expect(calls, 2);
        expect(second.retryAfter, clock.now().add(const Duration(seconds: 60)));
      }
    },
  );

  test('redirect requests join destination provider throttle', () async {
    final clock = _Clock();
    final starts = <DateTime>[];
    final client = _client(clock, (uri, _) async {
      if (uri.host == 'coverartarchive.org') {
        return const ApiResponse(
          302,
          '',
          headers: {
            'Location':
                'https://ia800000.us.archive.org/download/test/index.json',
          },
        );
      }
      starts.add(clock.now());
      return const ApiResponse(200, '{}');
    });
    await Future.wait([
      client.getJson(Uri.https('archive.org', '/download/first/index.json')),
      client.getJson(Uri.https('coverartarchive.org', '/release/test')),
    ]);
    expect(starts, hasLength(2));
    expect(starts[1].difference(starts[0]), const Duration(milliseconds: 400));
  });

  test('HTTPS allowlist refuses downgrade, user info, ports and other NetEase paths', () async {
    final visited = <Uri>[];
    final client = _client(_Clock(), (uri, _) async {
      visited.add(uri);
      return const ApiResponse(
        307,
        '',
        headers: {'location': 'http://lrclib.net/api/get'},
      );
    });
    for (final uri in [
      Uri.https('coverartarchive.org', '/release/test'),
      Uri.parse('http://lrclib.net/api/get'),
      Uri.parse('https://user:password@lrclib.net/api/get'),
      Uri.parse('https://lrclib.net:8443/api/get'),
      Uri.https('unrelated.example', '/'),
      Uri.https('music.163.com', '/weapi/login'),
      Uri.https('music.163.com', '/api/search/get/../login'),
    ]) {
      await _failure(client.getJson(uri));
    }
    expect(visited, hasLength(1));
  });
}
