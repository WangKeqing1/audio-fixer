import 'package:audio_fixer/core/models/audio_track.dart';
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
