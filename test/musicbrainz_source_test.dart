import 'dart:async';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/source_query_report.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:audio_fixer/core/services/sources/musicbrainz_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeJsonApiClient implements JsonApiClient {
  _FakeJsonApiClient(this.handler);

  final Future<Object?> Function(Uri uri) handler;
  final calls = <Uri>[];

  @override
  Future<Object?> getJson(Uri uri) {
    calls.add(uri);
    return handler(uri);
  }
}

AudioTrack _track({
  String? title = 'Never Gonna Give You Up',
  String? artist = 'Rick Astley',
  String? album,
  int? durationMs = 213000,
  String fileName = 'track.mp3',
}) => AudioTrack(
  id: 'track',
  fileName: fileName,
  sizeBytes: 1,
  importedAt: DateTime(2026),
  title: title,
  artist: artist,
  album: album,
  durationMs: durationMs,
);

Map<String, Object?> _recording({
  String id = 'recording-1',
  String title = 'Never Gonna Give You Up',
  String artist = 'Rick Astley',
  int length = 213000,
  List<Map<String, Object?>> releases = const [],
}) => {
  'id': id,
  'title': title,
  'length': length,
  'artist-credit': [
    {
      'name': artist,
      'artist': {'name': artist},
    },
  ],
  'releases': releases,
};

Map<String, Object?> _release({
  String id = 'release-1',
  String title = 'Whenever You Need Somebody',
  String groupId = 'group-1',
  String status = 'Official',
  String primaryType = 'Album',
}) => {
  'id': id,
  'title': title,
  'status': status,
  'release-group': {'id': groupId, 'primary-type': primaryType},
};

void main() {
  test(
    'later release rate limit survives an earlier malformed recording detail',
    () async {
      final until = DateTime.utc(2026, 1, 1, 0, 1);
      final client = _FakeJsonApiClient((uri) async {
        if (uri.path == '/ws/2/recording/') {
          return {
            'recordings': [_recording()],
          };
        }
        if (uri.path.startsWith('/ws/2/recording/')) return {'id': 'wrong-id'};
        if (uri.path == '/ws/2/release') {
          throw ApiException(
            '请求限制。',
            statusCode: 429,
            retryAfter: until,
            serverRetryAfter: until,
            provider: 'musicbrainz.org',
          );
        }
        throw StateError('Unexpected endpoint');
      });
      final result =
          await CompletionService(
            sources: [MusicBrainzMetadataSource(MusicBrainzCatalog(client))],
          ).preview(
            _track(),
            const AppSettings(),
            requestedFields: {
              AudioField.title,
              AudioField.genre,
              AudioField.year,
            },
          );
      expect(
        result.suggestions.first.provenance,
        SuggestionProvenance.verifiedRecording,
      );
      final report = result.sourceReports.single;
      expect(report.outcome, SourceQueryOutcome.partial);
      expect(report.failureKind, SourceFailureKind.rateLimited);
      expect(report.retryAt, until);
      expect(report.serverRetryAt, until);
      expect(result.suggestions.single.field, AudioField.title);
      expect(client.calls, hasLength(3));
    },
  );

  test('no-result cache expires so a later retry reaches the source', () async {
    var now = DateTime(2026);
    final client = _FakeJsonApiClient((_) async => null);
    final catalog = MusicBrainzCatalog(client, now: () => now);
    await catalog.findMatch(_track());
    await catalog.findMatch(_track());
    expect(client.calls, hasLength(1));
    now = now.add(const Duration(seconds: 31));
    await catalog.findMatch(_track());
    expect(client.calls, hasLength(2));
  });

  test('reusing a cached signature refreshes its eviction order', () async {
    final client = _FakeJsonApiClient((_) async => null);
    final catalog = MusicBrainzCatalog(client, maxCacheEntries: 2);
    await catalog.findMatch(_track(title: 'A'));
    await catalog.findMatch(_track(title: 'B'));
    await catalog.findMatch(_track(title: 'A'));
    await catalog.findMatch(_track(title: 'C'));
    await catalog.findMatch(_track(title: 'A'));
    expect(client.calls, hasLength(3));
    await catalog.findMatch(_track(title: 'B'));
    expect(client.calls, hasLength(4));
  });

  test(
    'an evicted failed request cannot discard a newer cached request',
    () async {
      final first = Completer<Object?>();
      var calls = 0;
      final client = _FakeJsonApiClient((_) {
        calls++;
        return calls == 1 ? first.future : Future.value(null);
      });
      final catalog = MusicBrainzCatalog(client, maxCacheEntries: 1);
      final pending = catalog.findMatch(_track(title: 'A'));
      final failure = expectLater(pending, throwsA(isA<ApiException>()));
      await catalog.findMatch(_track(title: 'B'));
      await catalog.findMatch(_track(title: 'A'));
      first.completeError(const ApiException('old request failed'));
      await failure;
      await catalog.findMatch(_track(title: 'A'));
      expect(calls, 3);
    },
  );

  test('a truncated result page cannot establish a unique recording', () async {
    final client = _FakeJsonApiClient(
      (_) async => {
        'count': 26,
        'offset': 0,
        'recordings': [_recording()],
      },
    );
    expect(await MusicBrainzCatalog(client).findMatch(_track()), isNull);
  });

  test(
    'guest-only artist matches are not enough to identify a recording',
    () async {
      final recording = _recording();
      recording['artist-credit'] = [
        {'name': 'Someone Else', 'joinphrase': ' feat. '},
        {'name': 'Rick Astley'},
      ];
      final client = _FakeJsonApiClient(
        (_) async => {
          'recordings': [recording],
        },
      );
      expect(await MusicBrainzCatalog(client).findMatch(_track()), isNull);
    },
  );

  test(
    'different albums remain ambiguous regardless of release date',
    () async {
      final client = _FakeJsonApiClient(
        (_) async => {
          'recordings': [
            _recording(
              releases: [
                {
                  ..._release(id: 'later', title: 'Later Album'),
                  'date': '2000-02-01',
                },
                {
                  ..._release(id: 'earlier', title: 'Earlier Album'),
                  'date': '1987',
                },
              ],
            ),
          ],
        },
      );
      final match = await MusicBrainzCatalog(client).findMatch(_track());
      expect(match?.releaseId, isNull);
      expect(match?.releaseTitle, isNull);
    },
  );

  test(
    'punctuation-distinct queries do not reuse another cached signature',
    () async {
      final client = _FakeJsonApiClient((_) async => {'recordings': []});
      final catalog = MusicBrainzCatalog(client);
      await catalog.findMatch(_track(title: 'A/B'));
      await catalog.findMatch(_track(title: 'AB'));
      expect(client.calls, hasLength(2));
    },
  );

  test('matches exact title, artist credit and duration range', () async {
    final client = _FakeJsonApiClient(
      (_) async => {
        'recordings': [
          _recording(id: 'wrong-duration', length: 91000),
          _recording(id: 'right', length: 214000),
        ],
      },
    );
    final match = await MusicBrainzCatalog(client).findMatch(_track());

    expect(match?.id, 'right');
    expect(client.calls, hasLength(1));
    expect(client.calls.single.queryParameters['limit'], '25');
    expect(client.calls.single.queryParameters['query'], contains('dur:['));
  });

  test('prefers an exact existing album release', () async {
    final client = _FakeJsonApiClient(
      (_) async => {
        'recordings': [
          _recording(
            releases: [
              _release(id: 'other', title: 'Different Album'),
              _release(id: 'wanted', title: 'Target Album'),
            ],
          ),
        ],
      },
    );
    final match = await MusicBrainzCatalog(client)
        .findMatch(_track(album: 'target album'));

    expect(match?.releaseId, 'wanted');
    expect(match?.releaseTitle, 'Target Album');
    expect(match?.releaseGroupId, 'group-1');
  });

  test(
    'prefers the sole official album release among unknown competitors',
    () async {
      final client = _FakeJsonApiClient(
        (_) async => {
          'recordings': [
            _recording(
              id: 'unknown-release-recording',
              title: 'Yellow',
              artist: 'Coldplay',
              length: 269000,
              releases: [
                _release(
                  id: 'unknown-parachutes',
                  title: 'Parachutes',
                  status: '',
                ),
              ],
            ),
            _recording(
              id: 'official-release-recording',
              title: 'Yellow',
              artist: 'Coldplay',
              length: 269110,
              releases: [
                _release(
                  id: 'official-parachutes',
                  title: 'Parachutes',
                  status: 'Official',
                ),
              ],
            ),
            _recording(
              id: 'acoustic-recording',
              title: 'Yellow (acoustic)',
              artist: 'Coldplay',
              length: 269000,
              releases: [
                _release(
                  id: 'acoustic-parachutes',
                  title: 'Parachutes',
                  status: 'Official',
                ),
              ],
            ),
          ],
        },
      );
      final match = await MusicBrainzCatalog(client).findMatch(
        _track(
          title: 'Yellow',
          artist: 'Coldplay',
          album: 'Parachutes',
          durationMs: 266000,
        ),
      );

      expect(match?.id, 'official-release-recording');
      expect(match?.releaseId, 'official-parachutes');
    },
  );

  test('keeps two equally official album recordings ambiguous', () async {
    final client = _FakeJsonApiClient(
      (_) async => {
        'recordings': [
          _recording(
            id: 'official-one',
            title: 'Yellow',
            artist: 'Coldplay',
            length: 269000,
            releases: [_release(id: 'official-album-one', title: 'Parachutes')],
          ),
          _recording(
            id: 'official-two',
            title: 'Yellow',
            artist: 'Coldplay',
            length: 269110,
            releases: [_release(id: 'official-album-two', title: 'Parachutes')],
          ),
        ],
      },
    );
    final match = await MusicBrainzCatalog(client).findMatch(
      _track(
        title: 'Yellow',
        artist: 'Coldplay',
        album: 'Parachutes',
        durationMs: 266000,
      ),
    );

    expect(match, isNull);
  });

  test('supports Chinese identity normalization', () async {
    final client = _FakeJsonApiClient(
      (_) async => {
        'recordings': [
          _recording(id: 'zh', title: '夜曲', artist: '周杰伦', length: 180000),
        ],
      },
    );
    final match = await MusicBrainzCatalog(client)
        .findMatch(_track(title: '夜曲', artist: ' 周杰伦 ', durationMs: 180000));
    expect(match?.id, 'zh');
  });

  test('404 becomes no match and is cached', () async {
    final client = _FakeJsonApiClient((_) async => null);
    final catalog = MusicBrainzCatalog(client);
    expect(await catalog.findMatch(_track()), isNull);
    expect(await catalog.findMatch(_track()), isNull);
    expect(client.calls, hasLength(1));
  });

  test(
    'connection probe looks up the known recording and validates its id',
    () async {
      final client = _FakeJsonApiClient(
        (uri) async => {
          'id': 'a4fd9f68-0907-47ee-a30d-5ce6185b25da',
          'title': 'Known recording',
        },
      );
      await MusicBrainzCatalog(client).checkConnection();
      expect(
        client.calls.single.path,
        '/ws/2/recording/a4fd9f68-0907-47ee-a30d-5ce6185b25da',
      );
      expect(client.calls.single.queryParameters, {'fmt': 'json'});
    },
  );

  test(
    'a successful search with no recordings array is a protocol error',
    () async {
      final client = _FakeJsonApiClient((_) async => {'count': 0});
      final catalog = MusicBrainzCatalog(client);
      await expectLater(
        catalog.findMatch(_track()),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('temporary failures propagate and can be retried', () async {
    var attempts = 0;
    final client = _FakeJsonApiClient((_) async {
      attempts++;
      if (attempts == 1) throw const ApiException('offline');
      return {'recordings': []};
    });
    final catalog = MusicBrainzCatalog(client);
    expect(() => catalog.findMatch(_track()), throwsA(isA<ApiException>()));
    await Future<void>.delayed(Duration.zero);
    expect(await catalog.findMatch(_track()), isNull);
    expect(attempts, 2);
  });

  test('does not force a title-only unique match', () async {
    final client = _FakeJsonApiClient(
      (_) async => {
        'recordings': [_recording()],
      },
    );
    final match = await MusicBrainzCatalog(client).findMatch(
      _track(title: 'Never Gonna Give You Up', artist: null, durationMs: null),
    );
    expect(match, isNull);
    expect(client.calls, isEmpty);
  });

  test(
    'filename provides the artist/title query when tags are absent',
    () async {
      final client = _FakeJsonApiClient(
        (_) async => {
          'recordings': [_recording(id: 'filename-match')],
        },
      );
      final match = await MusicBrainzCatalog(client).findMatch(
        _track(
          title: null,
          artist: null,
          durationMs: 213000,
          fileName: 'Rick Astley - Never Gonna Give You Up.mp3',
        ),
      );
      expect(match?.id, 'filename-match');
    },
  );
}
