import 'dart:async';

import 'package:audio_fixer/core/services/sources/http_json_api_client.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    final lyrics = client.getJson(Uri.https('lrclib.net', '/api/get'));
    await lyricsStarted.future;
    try {
      final metadata = await client
          .getJson(Uri.https('musicbrainz.org', '/ws/2/recording/'))
          .timeout(const Duration(seconds: 1));
      expect(metadata, {'recordings': []});
    } finally {
      lyricsResponse.complete(const ApiResponse(404, ''));
      await lyrics;
    }
  });

  test(
    'transport timeout releases the host queue for later requests',
    () async {
      var now = DateTime(2026);
      var calls = 0;
      final client = HttpJsonApiClient(
        requestTimeout: const Duration(milliseconds: 10),
        now: () => now,
        pause: (delay) async {
          now = now.add(delay);
        },
        transport: (_, _) {
          calls++;
          if (calls == 1) return Completer<ApiResponse>().future;
          return Future.value(const ApiResponse(200, '{}'));
        },
      );
      final uri = Uri.https('lrclib.net', '/api/get');
      await expectLater(client.getJson(uri), throwsA(isA<ApiException>()));
      expect(await client.getJson(uri), isA<Map>());
      expect(calls, 2);
    },
  );

  test('expired Retry-After dates still back off queued requests', () async {
    var calls = 0;
    final client = HttpJsonApiClient(
      now: () => DateTime.utc(2026),
      transport: (_, _) async {
        calls++;
        return const ApiResponse(
          503,
          '',
          headers: {'Retry-After': 'Wed, 01 Jan 2025 00:00:00 GMT'},
        );
      },
    );
    final uri = Uri.https('lrclib.net', '/api/get');
    await expectLater(client.getJson(uri), throwsA(isA<ApiException>()));
    await expectLater(client.getJson(uri), throwsA(isA<ApiException>()));
    expect(calls, 1);
  });

  test('redirect requests join the destination host throttle', () async {
    var now = DateTime(2026);
    final starts = <DateTime>[];
    final client = HttpJsonApiClient(
      now: () => now,
      pause: (delay) async {
        now = now.add(delay);
      },
      transport: (uri, _) async {
        if (uri.host == 'coverartarchive.org') {
          return const ApiResponse(
            302,
            '',
            headers: {
              'Location': 'https://archive.org/download/test/index.json',
            },
          );
        }
        starts.add(now);
        return const ApiResponse(200, '{}');
      },
    );
    await Future.wait([
      client.getJson(Uri.https('archive.org', '/download/first/index.json')),
      client.getJson(Uri.https('coverartarchive.org', '/release/test')),
    ]);
    expect(starts, hasLength(2));
    expect(
      starts[1].difference(starts[0]).inMilliseconds,
      greaterThanOrEqualTo(400),
    );
  });

  test(
    'MusicBrainz requests are serialized and spaced by at least one second',
    () async {
      var now = DateTime(2026);
      final starts = <DateTime>[];
      final client = HttpJsonApiClient(
        now: () => now,
        pause: (delay) async {
          now = now.add(delay);
        },
        transport: (uri, headers) async {
          starts.add(now);
          expect(headers['User-Agent'], contains('AudioFixer/0.2.0'));
          expect(
            headers['User-Agent'],
            contains('https://github.com/WangKeqing1/audio-fixer'),
          );
          return const ApiResponse(200, '{}');
        },
      );
      await Future.wait([
        client.getJson(Uri.https('musicbrainz.org', '/ws/2/recording/')),
        client.getJson(Uri.https('musicbrainz.org', '/ws/2/recording/')),
      ]);
      expect(
        starts[1].difference(starts[0]).inMilliseconds,
        greaterThanOrEqualTo(1000),
      );
    },
  );

  test(
    'rate limit blocks subsequent requests until Retry-After expires',
    () async {
      var now = DateTime(2026);
      var calls = 0;
      final client = HttpJsonApiClient(
        now: () => now,
        pause: (delay) async {
          now = now.add(delay);
        },
        transport: (_, _) async {
          calls++;
          return calls == 1
              ? const ApiResponse(429, '', headers: {'retry-after': '60'})
              : const ApiResponse(200, '{}');
        },
      );
      final uri = Uri.https('lrclib.net', '/api/search');
      await expectLater(client.getJson(uri), throwsA(isA<ApiException>()));
      await expectLater(client.getJson(uri), throwsA(isA<ApiException>()));
      expect(calls, 1);
      now = now.add(const Duration(seconds: 61));
      expect(await client.getJson(uri), isA<Map>());
      expect(calls, 2);
    },
  );

  test(
    '404 is no-match while timeout and invalid JSON remain failures',
    () async {
      final missing = HttpJsonApiClient(
        transport: (_, _) async => const ApiResponse(404, ''),
      );
      expect(
        await missing.getJson(Uri.https('lrclib.net', '/api/get')),
        isNull,
      );
      final timeout = HttpJsonApiClient(
        transport: (_, _) async => throw TimeoutException('test'),
      );
      await expectLater(
        timeout.getJson(Uri.https('lrclib.net', '/api/get')),
        throwsA(isA<ApiException>()),
      );
      final invalid = HttpJsonApiClient(
        transport: (_, _) async => const ApiResponse(200, '<html>'),
      );
      await expectLater(
        invalid.getJson(Uri.https('lrclib.net', '/api/get')),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test('HTTPS archive redirect is followed; unknown hosts and downgrade are refused', () async {
    final visited = <Uri>[];
    final client = HttpJsonApiClient(
      transport: (uri, _) async {
        visited.add(uri);
        return visited.length == 1
            ? const ApiResponse(
                307,
                '',
                headers: {
                  'location': 'https://archive.org/download/test/index.json',
                },
              )
            : const ApiResponse(200, '{"images":[]}');
      },
    );
    expect(
      await client.getJson(Uri.https('coverartarchive.org', '/release/test')),
      isA<Map>(),
    );
    expect(visited.last.host, 'archive.org');
    await expectLater(
      client.getJson(Uri.parse('http://lrclib.net/api/get')),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      client.getJson(Uri.https('unrelated.example', '/')),
      throwsA(isA<ApiException>()),
    );
    expect(visited, hasLength(2));
  });
}
