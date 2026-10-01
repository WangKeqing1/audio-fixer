import 'dart:async';

import 'package:audio_fixer/core/services/sources/http_json_api_client.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
          expect(headers['User-Agent'], contains('AudioFixer/'));
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
