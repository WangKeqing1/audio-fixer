import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:audio_fixer/core/services/sources/lrclib_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeJsonApiClient implements JsonApiClient {
  _FakeJsonApiClient(this.responses);

  final List<Object?> responses;
  final List<Uri> requests = [];

  @override
  Future<Object?> getJson(Uri uri) async {
    requests.add(uri);
    if (responses.isEmpty) return null;
    return responses.removeAt(0);
  }
}

AudioTrack _track({
  String title = 'Song',
  String artist = 'Artist',
  String? album = 'Album',
  int durationMs = 180000,
}) => AudioTrack(
  id: 'track',
  fileName: 'track.mp3',
  sizeBytes: 1,
  importedAt: DateTime(2026),
  title: title,
  artist: artist,
  album: album,
  durationMs: durationMs,
);

Map<String, dynamic> _record({
  int? id = 7,
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  double duration = 180,
  bool instrumental = false,
  String? plain = 'These are real words in the song.',
  String? synced,
}) => {
  'id': id,
  'trackName': title,
  'artistName': artist,
  'albumName': album,
  'duration': duration,
  'instrumental': instrumental,
  'plainLyrics': plain,
  'syncedLyrics': synced,
};

void main() {
  test(
    'equally matched instrumental search results veto vocal lyrics',
    () async {
      final client = _FakeJsonApiClient([
        null,
        [_record(id: 1), _record(id: 2, instrumental: true, plain: null)],
      ]);
      expect(
        await LrclibSource(client).lookup(_track(), {AudioField.lyrics}),
        isEmpty,
      );
    },
  );

  test(
    'a leading artist can match a credit containing featured performers',
    () async {
      final client = _FakeJsonApiClient([
        _record(artist: 'Artist feat. Guest'),
      ]);
      final result = await LrclibSource(client)
          .lookup(_track(), {AudioField.lyrics});
      expect(result, hasLength(1));
    },
  );

  test('rejects a guest artist credit as a primary artist identity', () async {
    final client = _FakeJsonApiClient([
      _record(artist: 'Someone Else feat. Artist'),
      [_record(artist: 'Someone Else, Artist')],
    ]);
    expect(
      await LrclibSource(client).lookup(_track(), {AudioField.lyrics}),
      isEmpty,
    );
  });

  test(
    'conflicting equally matched lyrics are not chosen by id or sync status',
    () async {
      final client = _FakeJsonApiClient([
        null,
        [
          _record(id: 1, synced: '[00:01.00]Words from one recording'),
          _record(id: 2, plain: 'Words from another recording'),
        ],
      ]);
      expect(
        await LrclibSource(client).lookup(_track(), {AudioField.lyrics}),
        isEmpty,
      );
    },
  );

  test('duplicate lyric text prefers synchronized presentation', () async {
    final client = _FakeJsonApiClient([
      null,
      [
        _record(id: 1, plain: 'The same lyric words'),
        _record(id: 2, synced: '[00:01.00]The same lyric words'),
      ],
    ]);
    final result = await LrclibSource(client)
        .lookup(_track(), {AudioField.lyrics});
    expect(result.single.sourceUrl, endsWith('/2'));
    expect(result.single.matchDescription, contains('同步歌词'));
  });

  test(
    'known album can disambiguate otherwise conflicting search lyrics',
    () async {
      final client = _FakeJsonApiClient([
        null,
        [
          _record(
            id: 1,
            album: 'Another Album',
            plain: 'A different recording',
          ),
          _record(id: 2, plain: 'The correct album recording'),
        ],
      ]);
      final result = await LrclibSource(client)
          .lookup(_track(), {AudioField.lyrics});
      expect(result.single.sourceUrl, endsWith('/2'));
      expect(result.single.matchDescription, contains('专辑匹配'));
    },
  );

  test(
    'LRC metadata alone is not lyrics and short Chinese lyrics remain usable',
    () async {
      final client = _FakeJsonApiClient([
        _record(synced: '[ar:Artist]\n[ti:Song]\n[00:00.00]', plain: '我爱你'),
      ]);
      final result = await LrclibSource(client)
          .lookup(_track(), {AudioField.lyrics});
      expect(result.single.value, '我爱你');
      expect(result.single.matchDescription, contains('纯文本歌词'));
    },
  );

  test('synced field without a timestamp falls back to plain lyrics', () async {
    final client = _FakeJsonApiClient([
      _record(
        synced: 'This field is not synchronized',
        plain: 'Actual plain lyrics',
      ),
    ]);
    final result = await LrclibSource(client)
        .lookup(_track(), {AudioField.lyrics});
    expect(result.single.value, 'Actual plain lyrics');
    expect(result.single.matchDescription, contains('纯文本歌词'));
  });

  test(
    'search result without id links to the search that returned it',
    () async {
      final client = _FakeJsonApiClient([
        null,
        [_record(id: null)],
      ]);
      final result = await LrclibSource(client)
          .lookup(_track(), {AudioField.lyrics});
      expect(Uri.parse(result.single.sourceUrl!).path, '/api/search');
    },
  );

  test(
    'prefers usable synchronized lyrics and exposes the LRCLIB URL',
    () async {
      final client = _FakeJsonApiClient([
        _record(synced: '[00:01.00]These are synchronized words in the song.'),
      ]);

      final result = await LrclibSource(client)
          .lookup(_track(), const {AudioField.lyrics});

      expect(result, hasLength(1));
      expect(result.single.value, startsWith('[00:01.00]'));
      expect(result.single.source, 'LRCLIB');
      expect(result.single.sourceUrl, 'https://lrclib.net/api/get/7');
      expect(result.single.matchDescription, contains('同步歌词'));
      expect(client.requests.single.path, '/api/get');
    },
  );

  test('rejects wrong artist, version, and duration candidates', () async {
    final client = _FakeJsonApiClient([
      _record(artist: 'Other Artist'),
      [
        _record(artist: 'Other Artist'),
        _record(title: 'Song (Live)'),
        _record(duration: 190),
      ],
    ]);

    final result = await LrclibSource(client)
        .lookup(_track(), const {AudioField.lyrics});

    expect(result, isEmpty);
    expect(client.requests.map((uri) => uri.path), ['/api/get', '/api/search']);
  });

  test(
    'matching instrumental records do not trigger search fallback',
    () async {
      final client = _FakeJsonApiClient([
        _record(instrumental: true, plain: 'These are real words in the song.'),
        [_record(id: 99)],
      ]);

      final result = await LrclibSource(client)
          .lookup(_track(), const {AudioField.lyrics});

      expect(result, isEmpty);
      expect(client.requests.map((uri) => uri.path), ['/api/get']);
    },
  );

  test('unmatched instrumental records may fall back to search', () async {
    final client = _FakeJsonApiClient([
      _record(instrumental: true, artist: 'Other Artist'),
      [_record(id: 99)],
    ]);

    final result = await LrclibSource(client)
        .lookup(_track(), const {AudioField.lyrics});

    expect(result, hasLength(1));
    expect(client.requests.map((uri) => uri.path), ['/api/get', '/api/search']);
  });

  test(
    '404/null get response falls back to a verified search candidate',
    () async {
      final client = _FakeJsonApiClient([
        null,
        [
          _record(
            id: 19,
            album: 'Compilation',
            synced: '[00:01.00]These are synchronized words in the song.',
          ),
        ],
      ]);

      final result = await LrclibSource(client)
          .lookup(_track(), const {AudioField.lyrics});

      expect(result.single.sourceUrl, 'https://lrclib.net/api/get/19');
      expect(client.requests.last.path, '/api/search');
    },
  );

  test(
    'filters the short probe placeholder from both lyric variants',
    () async {
      final client = _FakeJsonApiClient([
        _record(plain: 'probe', synced: '[00:00.00]probe'),
        [_record(plain: 'probe', synced: '[00:00.00]probe')],
      ]);

      final result = await LrclibSource(client)
          .lookup(_track(), const {AudioField.lyrics});

      expect(result, isEmpty);
    },
  );

  test(
    'uses the full signature URL when the candidate id is invalid',
    () async {
      final client = _FakeJsonApiClient([_record(id: null)]);

      final result = await LrclibSource(client)
          .lookup(_track(), const {AudioField.lyrics});

      final sourceUri = Uri.parse(result.single.sourceUrl!);
      expect(sourceUri.path, '/api/get');
      expect(sourceUri.queryParameters['track_name'], 'Song');
      expect(sourceUri.queryParameters['artist_name'], 'Artist');
      expect(sourceUri.queryParameters['duration'], '180');
    },
  );

  test('propagates non-404 API failures', () async {
    final client = _ThrowingClient(const ApiException('offline'));

    expect(
      () => LrclibSource(client).lookup(_track(), const {AudioField.lyrics}),
      throwsA(isA<ApiException>()),
    );
  });

  test('does not query LRCLIB without an artist', () async {
    final client = _FakeJsonApiClient([]);
    final result = await LrclibSource(client)
        .lookup(_track(artist: ''), const {AudioField.lyrics});

    expect(result, isEmpty);
    expect(client.requests, isEmpty);
  });
}

class _ThrowingClient implements JsonApiClient {
  const _ThrowingClient(this.error);

  final Object error;

  @override
  Future<Object?> getJson(Uri uri) async => throw error;
}
