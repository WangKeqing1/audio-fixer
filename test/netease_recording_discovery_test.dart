import 'dart:convert';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/recording_candidate.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/services/sources/http_json_api_client.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:audio_fixer/core/services/sources/netease_lyrics_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client implements JsonApiClient {
  _Client(this.responses);
  final List<Object?> responses;
  final calls = <Uri>[];
  @override
  Future<Object?> getJson(Uri uri) async {
    calls.add(uri);
    final result = responses.removeAt(0);
    if (result is Exception) throw result;
    return result;
  }
}

AudioTrack _track({
  String name = '極楽浄土.mp3',
  int? duration = 218828,
  String? artist,
}) => AudioTrack(
  id: 'untagged',
  fileName: name,
  sizeBytes: 1,
  importedAt: DateTime(2026),
  durationMs: duration,
  artist: artist,
);
Map<String, Object?> _song({
  int id = 411907897,
  String title = '極楽浄土',
  String artist = 'GARNiDELiA',
  int duration = 218800,
  String album = '約束 -Promise code-',
  Map<String, Object?> changes = const {},
}) => {
  'id': id,
  'name': title,
  'artists': [
    {'name': artist},
  ],
  'duration': duration,
  'album': {
    'id': 34686637,
    'name': album,
    'picUrl': 'https://p1.music.126.net/sample/123.jpg',
    'artists': [
      {'name': artist},
    ],
    'publishTime': 1470000000000,
  },
  'no': 2,
  ...changes,
};
Map<String, Object?> _search(List<Object?> songs, {int? total}) => {
  'code': 200,
  'result': {'songs': songs, 'songCount': total ?? songs.length},
};
Map<String, Object?> _detail(Map<String, Object?> song) => {
  'code': 200,
  'songs': [song],
};
const _lyric = {
  'code': 200,
  'lrc': {'lyric': '[00:01.00]Sample lyric'},
};
RecordingCandidate _candidate({Map<String, Object?> changes = const {}}) =>
    RecordingCandidate.fromJson({
      'sourceName': '网易云音乐（实验性）',
      'sourceId': 'netease:411907897',
      'sourceUrl': 'https://music.163.com/song?id=411907897',
      'title': '極楽浄土',
      'artist': 'GARNiDELiA',
      'album': '約束 -Promise code-',
      'durationMs': 218800,
      'matchDescription': '来源歌名一致；需要先确认录音',
      ...changes,
    });

void main() {
  test(
    'conflicting duplicate provider IDs cannot choose an arbitrary album',
    () async {
      final result = await NeteaseLyricsSource(
        _Client([
          _search([_song(), _song(album: 'Conflicting album'), _song()]),
        ]),
      ).discover(_track());
      expect(result.candidates, isEmpty);
      expect(result.diagnostics.join(), contains('已排除资料冲突的 1 个 ID'));
    },
  );
  test(
    'missing artist discovers bounded choices without fetching any fields',
    () async {
      final client = _Client([
        _search(List.generate(7, (i) => _song(id: 411907897 + i)), total: 302),
      ]);
      final source = NeteaseLyricsSource(client);
      final result = await source.discover(_track());
      expect(result.candidates, hasLength(5));
      expect(result.candidates.map((c) => c.sourceId).toSet(), hasLength(5));
      expect(result.candidates.every((c) => c.isValid), isTrue);
      expect(result.candidates.first.matchDescription, contains('尚未确认录音身份'));
      expect(result.diagnostics.join(), contains('仅展示前 5 条'));
      expect(result.diagnostics.join(), contains('来源报告共 302 条'));
      expect(result.diagnostics.join(), contains('未查询其余 295 条'));
      expect(client.calls.single.path, '/api/search/get');
      expect(client.calls.single.queryParameters, {
        's': '極楽浄土',
        'type': '1',
        'limit': '20',
        'offset': '0',
      });
      expect(await source.lookup(_track(), {AudioField.lyrics}), isEmpty);
      expect(
        client.calls,
        hasLength(1),
        reason: 'Strict automatic lookup stays guarded.',
      );
    },
  );

  test(
    'title, version, duration and malformed counts explain filtered results',
    () async {
      final client = _Client([
        _search([
          _song(title: '極楽浄土 (Live)'),
          _song(title: 'Other song'),
          _song(duration: 221829),
          _song(changes: {'artists': []}),
        ]),
      ]);
      final result = await NeteaseLyricsSource(client).discover(_track());
      expect(result.candidates, isEmpty);
      expect(result.hasFailures, isFalse);
      expect(result.diagnostics.join(), contains('本页返回 4 条'));
      expect(result.diagnostics.join(), contains('歌名或版本不符 2 条'));
      expect(result.diagnostics.join(), contains('时长不符 1 条'));
      expect(result.diagnostics.join(), contains('资料无效 1 条'));
      expect(client.calls, hasLength(1));
    },
  );

  test(
    '3 second boundary remains inclusive; unknown duration is visible',
    () async {
      final boundary = await NeteaseLyricsSource(
        _Client([
          _search([_song(duration: 221828), _song(id: 2, duration: 221829)]),
        ]),
      ).discover(_track());
      expect(boundary.candidates, hasLength(1));
      final unknown = await NeteaseLyricsSource(
        _Client([
          _search([_song()]),
        ]),
      ).discover(_track(duration: null));
      expect(unknown.candidates.single.matchDescription, contains('本地时长未知'));
    },
  );

  test(
    'provider aliases are exact, and never strip explicit recording versions',
    () async {
      final client = _Client([
        _search([
          _song(
            changes: {
              'transNames': ['极乐净土'],
            },
          ),
          _song(
            id: 2,
            title: '極楽浄土 (Live)',
            changes: {
              'alias': ['极乐净土'],
            },
          ),
          _song(
            id: 3,
            changes: {
              'alias': ['極樂淨土'],
            },
          ),
          _song(id: 4, changes: {'transName': '极乐净土翻唱'}),
        ]),
      ]);
      final result = await NeteaseLyricsSource(client)
          .discover(_track(name: '极乐净土.mp3'));
      expect(result.candidates.single.sourceId, 'netease:411907897');
      expect(result.candidates.single.matchDescription, contains('来源明确提供的别名'));
      final version = await NeteaseLyricsSource(
        _Client([
          _search([_song(title: '極楽浄土 (Live)'), _song()]),
        ]),
      ).discover(_track(name: '極楽浄土 (Live).mp3'));
      expect(version.candidates.single.title, '極楽浄土 (Live)');
    },
  );

  test(
    'no hits, malformed response and provider rate failure remain distinct',
    () async {
      final empty = await NeteaseLyricsSource(_Client([_search([])]))
          .discover(_track());
      expect(empty.diagnostics.single, contains('来源返回 0 条'));
      for (final response in [
        {'code': 200, 'result': 'bad'},
        {
          'code': 200,
          'result': {'songs': 'bad'},
        },
        {'code': 429},
        {'code': 403},
      ]) {
        final client = _Client([response]);
        await expectLater(
          NeteaseLyricsSource(client).discover(_track()),
          throwsA(isA<ApiException>()),
        );
        expect(client.calls, hasLength(1));
      }
    },
  );

  test('confirmed lookup fetches only the chosen ID and all fields share provenance', () async {
    final client = _Client([_detail(_song()), _lyric]);
    final result = await NeteaseLyricsSource(client)
        .lookupConfirmed(_track(), _candidate(), {
          AudioField.title,
          AudioField.artist,
          AudioField.album,
          AudioField.artwork,
          AudioField.lyrics,
          AudioField.albumArtist,
          AudioField.year,
          AudioField.trackNumber,
        });
    expect(result, hasLength(8));
    expect(result.every((s) => s.sourceUrl == _candidate().sourceUrl), isTrue);
    expect(result.every((s) => s.matchDescription!.contains('已复核')), isTrue);
    expect(client.calls.map((u) => u.path), [
      '/api/song/detail',
      '/api/song/lyric',
    ]);
    expect(client.calls.first.queryParameters['ids'], '[411907897]');
    expect(client.calls.last.queryParameters['id'], '411907897');
  });

  test('lyrics-only confirmation first rejects changed identity without lyric request', () async {
    for (final song in [
      _song(id: 2),
      _song(title: '極楽浄土 (Live)'),
      _song(artist: 'GARNiDELiA/Guest'),
      _song(album: 'Other album'),
      _song(duration: 218801),
      _song(
        changes: {
          'artists': [
            {'name': 'GARNiDELiA'},
            {'name': 'Guest'},
          ],
        },
      ),
    ]) {
      final client = _Client([_detail(song)]);
      await expectLater(
        NeteaseLyricsSource(client)
            .lookupConfirmed(_track(), _candidate(), {AudioField.lyrics}),
        throwsA(isA<ApiException>()),
      );
      expect(client.calls.single.path, '/api/song/detail');
    }
  });

  test(
    'altered candidate ID URL or source is rejected before any network request',
    () async {
      for (final changes in [
        {'sourceId': 'netease:2'},
        {'sourceName': 'Wrong source'},
        {'sourceUrl': 'https://music.163.com/song?id=2'},
        {'sourceId': 'other:411907897'},
        {'sourceUrl': 'https://evil.example/song?id=411907897'},
      ]) {
        final client = _Client([]);
        await expectLater(
          NeteaseLyricsSource(client).lookupConfirmed(
            _track(),
            _candidate(changes: changes),
            {AudioField.lyrics},
          ),
          throwsA(isA<ApiException>()),
        );
        expect(client.calls, isEmpty);
      }
    },
  );

  test('changed local title duration or known artist cannot reuse a chosen recording', () async {
    for (final local in [
      _track(name: 'Other song.mp3'),
      _track(duration: 250000),
      _track(artist: 'Someone else'),
    ]) {
      final client = _Client([_detail(_song())]);
      await expectLater(
        NeteaseLyricsSource(client)
            .lookupConfirmed(local, _candidate(), {AudioField.lyrics}),
        throwsA(isA<ApiException>()),
      );
      expect(client.calls.any((u) => u.path == '/api/song/lyric'), isFalse);
    }
  });

  test('alias confirmation needs exact retained detail evidence and never searches again', () async {
    for (final alias in [null, '極樂淨土', '极乐净土 (Live)']) {
      final client = _Client([
        _detail(_song(changes: {'transName': alias})),
      ]);
      await expectLater(
        NeteaseLyricsSource(client).lookupConfirmed(
          _track(name: '极乐净土.mp3'),
          _candidate(),
          {AudioField.lyrics},
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'notice',
            contains('别名'),
          ),
        ),
      );
      expect(client.calls.single.path, '/api/song/detail');
    }
    final client = _Client([
      _detail(_song(changes: {'transName': '极乐净土'})),
      _lyric,
    ]);
    final result = await NeteaseLyricsSource(client).lookupConfirmed(
      _track(name: '极乐净土.mp3'),
      _candidate(),
      {AudioField.lyrics},
    );
    expect(result.single.field, AudioField.lyrics);
    expect(client.calls, hasLength(2));
  });

  test('confirmed fields are scoped and failed detail never falls through to lyrics', () async {
    final client = _Client([_detail(_song())]);
    final source = NeteaseLyricsSource(client);
    expect(
      await source.lookupConfirmed(_track(), _candidate(), {
        AudioField.comment,
      }),
      isEmpty,
    );
    expect(client.calls, isEmpty);
    final result = await source.lookupConfirmed(_track(), _candidate(), {
      AudioField.artist,
    });
    expect(result.single.field, AudioField.artist);
    for (final response in [
      {'code': 429},
      {'code': 403},
      {'code': 200, 'songs': []},
    ]) {
      final failureClient = _Client([response]);
      await expectLater(
        NeteaseLyricsSource(failureClient).lookupConfirmed(
          _track(),
          _candidate(),
          {AudioField.title, AudioField.lyrics},
        ),
        throwsA(anyOf(isA<ApiException>(), isA<SourceNoMatch>())),
      );
      expect(failureClient.calls, hasLength(1));
    }
  });

  test('discovery and ID confirmation share exact bounded cache without selecting a hit', () async {
    final calls = <Uri>[];
    final client = HttpJsonApiClient(
      pause: (_) async {},
      transport: (uri, _) async {
        calls.add(uri);
        return ApiResponse(
          200,
          jsonEncode(switch (uri.path) {
            '/api/search/get' => _search([_song(), _song(id: 2)]),
            '/api/song/detail' => _detail(_song()),
            _ => _lyric,
          }),
        );
      },
    );
    final source = NeteaseLyricsSource(client);
    final first = await source.discover(_track());
    final second = await source.discover(_track());
    expect(first.candidates, hasLength(2));
    expect(second.candidates, hasLength(2));
    expect(calls, hasLength(1));
    final chosen = first.candidates.singleWhere(
      (c) => c.sourceId == 'netease:411907897',
    );
    await source.lookupConfirmed(_track(), chosen, {AudioField.lyrics});
    await source.lookupConfirmed(_track(), chosen, {AudioField.lyrics});
    expect(calls.map((u) => u.path), [
      '/api/search/get',
      '/api/song/detail',
      '/api/song/lyric',
    ]);
  });

  test(
    'rate limit uses existing cooldown and prevents an ID request afterward',
    () async {
      final calls = <Uri>[];
      final client = HttpJsonApiClient(
        pause: (_) async {},
        transport: (uri, _) async {
          calls.add(uri);
          return ApiResponse(429, '{}', headers: {'retry-after': '60'});
        },
      );
      final source = NeteaseLyricsSource(client);
      await expectLater(
        source.discover(_track()),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        source.lookupConfirmed(_track(), _candidate(), {AudioField.lyrics}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.retryAfter,
            'cooldown',
            isNotNull,
          ),
        ),
      );
      expect(calls, hasLength(1));
    },
  );
}
