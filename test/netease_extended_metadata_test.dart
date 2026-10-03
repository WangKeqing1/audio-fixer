import 'dart:convert';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/services/sources/http_json_api_client.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:audio_fixer/core/services/sources/netease_lyrics_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client implements JsonApiClient {
  _Client(this.responses);
  final List<Object?> responses;
  final List<Uri> calls = [];

  @override
  Future<Object?> getJson(Uri uri) async {
    calls.add(uri);
    return responses.removeAt(0);
  }
}

final _track = AudioTrack(
  id: 'extended-tags',
  fileName: 'Song.mp3',
  sizeBytes: 1,
  importedAt: DateTime(2026),
  title: 'Song',
  artist: 'Track Artist',
  album: 'Album',
  durationMs: 180000,
);

Map<String, Object?> _song({
  Map<String, Object?> albumChanges = const {},
  Map<String, Object?> changes = const {},
}) => {
  'id': 123,
  'name': 'Song',
  'artists': [
    {'id': 30, 'name': 'Track Artist'},
  ],
  'duration': 180000,
  'no': 9,
  'position': 9,
  'disc': '1',
  'album': {
    'id': 10,
    'name': 'Album',
    'size': 13,
    // Same observed field types/structure as the anonymous detail response.
    'publishTime': 907257600000,
    'artist': {'id': 0, 'name': ''},
    'artists': [
      {'id': 40, 'name': 'Album Artist'},
      {'id': 41, 'name': 'Second Album Artist'},
    ],
    ...albumChanges,
  },
  ...changes,
};

Map<String, Object?> _search(Map<String, Object?> song) => {
  'code': 200,
  'result': {
    'songs': [song],
  },
};

Map<String, Object?> _detail(Map<String, Object?> song) => {
  'code': 200,
  'songs': [song],
};

const _extendedFields = {
  AudioField.albumArtist,
  AudioField.year,
  AudioField.trackNumber,
};

Future<List<FieldSuggestion>> _lookup(
  Map<String, Object?> song,
  Set<AudioField> fields,
) =>
    NeteaseLyricsSource(_Client([_search(song), _detail(song)]))
        .lookup(_track, fields);

void main() {
  test(
    'extended values belong to the verified album and current song',
    () async {
      final client = _Client([_search(_song()), _detail(_song())]);
      final result = await NeteaseLyricsSource(client)
          .lookup(_track, _extendedFields);
      expect(
        {for (final item in result) item.field: item.value},
        {
          AudioField.albumArtist: 'Album Artist/Second Album Artist',
          AudioField.year: '1998',
          AudioField.trackNumber: '9',
        },
      );
      expect(
        result.every(
          (item) => item.sourceUrl == 'https://music.163.com/song?id=123',
        ),
        isTrue,
      );
      expect(
        result.every((item) => item.matchDescription!.contains('专辑 ID 10')),
        isTrue,
      );
      expect(
        result
            .singleWhere((item) => item.field == AudioField.year)
            .matchDescription,
        contains('publishTime=907257600000'),
      );
      expect(client.calls.map((uri) => uri.path), [
        '/api/search/get',
        '/api/song/detail',
      ]);
    },
  );

  test('absent extended fields are not fabricated from other song values', () async {
    final result = await _lookup(
      _song(
        albumChanges: {'artists': null, 'publishTime': null},
        changes: {'no': null, 'publishTime': 907257600000},
      ),
      _extendedFields,
    );
    // Song artists, song date and position are not interchangeable album tags.
    expect(result, isEmpty);
  });

  test(
    'album artist never falls back to the track or incomplete credits',
    () async {
      for (final credits in [
        'Album Artist',
        [
          {'name': 'Album Artist'},
          {'name': ''},
        ],
        [
          {'name': 'Album Artist'},
          'Second Album Artist',
        ],
      ]) {
        await expectLater(
          _lookup(_song(albumChanges: {'artists': credits}), {
            AudioField.title,
            AudioField.albumArtist,
          }),
          throwsA(
            isA<PartialSourceException>()
                .having(
                  (error) => error.suggestions.single.field,
                  'retained field',
                  AudioField.title,
                )
                .having((error) => error.message, 'warning', contains('专辑歌手')),
          ),
        );
      }
    },
  );

  test(
    'zero and invalid timestamps warn without discarding other metadata',
    () async {
      for (final timestamp in [0, '1998', 907257600000.5, 8640000000000001]) {
        await expectLater(
          _lookup(_song(albumChanges: {'publishTime': timestamp}), {
            AudioField.albumArtist,
            AudioField.year,
          }),
          throwsA(
            isA<PartialSourceException>()
                .having(
                  (error) => error.suggestions.single.field,
                  'retained field',
                  AudioField.albumArtist,
                )
                .having((error) => error.message, 'warning', contains('发行时间')),
          ),
        );
      }
    },
  );

  test('negative timestamp is a valid release before 1970', () async {
    final result = await _lookup(
      _song(
        albumChanges: {
          'publishTime': DateTime.utc(1965, 8, 6).millisecondsSinceEpoch,
        },
      ),
      {AudioField.year},
    );
    expect(result.single.value, '1965');
  });

  test('a cross-year timestamp needs timezone evidence', () async {
    await expectLater(
      _lookup(
        _song(
          albumChanges: {
            'publishTime': DateTime.utc(
              1998,
              12,
              31,
              16,
            ).millisecondsSinceEpoch,
          },
        ),
        {AudioField.year},
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'warning',
          contains('跨年时区边界'),
        ),
      ),
    );
  });

  test('missing album identity prevents album-dependent tags', () async {
    for (final albumChanges in [
      {'id': null},
      {'id': 0},
      {'name': ''},
    ]) {
      await expectLater(
        _lookup(_song(albumChanges: albumChanges), {
          AudioField.title,
          ..._extendedFields,
        }),
        throwsA(
          isA<PartialSourceException>()
              .having(
                (error) => error.suggestions.single.field,
                'retained field',
                AudioField.title,
              )
              .having((error) => error.message, 'warning', contains('专辑身份')),
        ),
      );
    }
  });

  test(
    'detail album mismatch rejects extended fields with the recording',
    () async {
      for (final albumChanges in [
        {'id': 11},
        {'name': 'Other album'},
      ]) {
        final client = _Client([
          _search(_song()),
          _detail(_song(albumChanges: albumChanges)),
        ]);
        await expectLater(
          NeteaseLyricsSource(client).lookup(_track, _extendedFields),
          throwsA(
            isA<ApiException>().having(
              (error) => error.message,
              'warning',
              contains('不一致'),
            ),
          ),
        );
        expect(client.calls, hasLength(2));
      }
    },
  );

  test(
    'equally matched album recordings warn without reading details',
    () async {
      final client = _Client([
        {
          'code': 200,
          'result': {
            'songs': [
              _song(),
              _song(changes: {'id': 124}),
            ],
          },
        },
      ]);
      await expectLater(
        NeteaseLyricsSource(client).lookup(_track, _extendedFields),
        throwsA(
          isA<SourceNoMatch>().having(
            (error) => error.message,
            'warning',
            contains('歧义'),
          ),
        ),
      );
      expect(client.calls, hasLength(1));
    },
  );

  test(
    'album ambiguity is a visible no-match instead of a source failure',
    () async {
      final client = _Client([
        {
          'code': 200,
          'result': {
            'songs': [
              _song(),
              _song(changes: {'id': 124}),
            ],
          },
        },
      ]);
      final result = await CompletionService(
        sources: [NeteaseLyricsSource(client)],
      ).preview(_track, const AppSettings(), requestedFields: _extendedFields);
      expect(result.status, TaskStatus.noMatch);
      expect(result.suggestions, isEmpty);
      expect(result.message, contains('候选录音或专辑存在歧义'));
      expect(result.message, isNot(contains('查询失败或超时')));
      expect(client.calls, hasLength(1));
    },
  );

  test(
    'invalid or contradictory track numbers are omitted with a warning',
    () async {
      for (final number in [0, -1, 14, 65536, 1.5, '9']) {
        await expectLater(
          _lookup(_song(changes: {'no': number}), {
            AudioField.title,
            AudioField.trackNumber,
          }),
          throwsA(
            isA<PartialSourceException>()
                .having(
                  (error) => error.suggestions.single.field,
                  'retained field',
                  AudioField.title,
                )
                .having((error) => error.message, 'warning', contains('音轨序号')),
          ),
        );
      }
    },
  );

  test('unrequested invalid extended fields neither leak nor warn', () async {
    final result = await _lookup(
      _song(
        albumChanges: {'artists': 'bad', 'publishTime': 0},
        changes: {'no': 0},
      ),
      {AudioField.title},
    );
    expect(result.single.field, AudioField.title);
  });

  test('detail size and disc never fabricate total or disc tags', () async {
    const unsupported = {
      AudioField.trackTotal,
      AudioField.discNumber,
      AudioField.discTotal,
      AudioField.composer,
      AudioField.genre,
      AudioField.comment,
    };
    final client = _Client([]);
    final source = NeteaseLyricsSource(client);
    expect(source.supportedFields.intersection(unsupported), isEmpty);
    expect(await source.lookup(_track, unsupported), isEmpty);
    expect(client.calls, isEmpty);
  });

  test('extended metadata shares bounded exact-request HTTP cache', () async {
    final requests = <Uri>[];
    final client = HttpJsonApiClient(
      pause: (_) async {},
      transport: (uri, headers) async {
        requests.add(uri);
        final data = uri.path == '/api/search/get'
            ? _search(_song())
            : _detail(_song());
        return ApiResponse(200, jsonEncode(data));
      },
    );
    final source = NeteaseLyricsSource(client);
    final first = await source.lookup(_track, _extendedFields);
    final second = await source.lookup(_track, _extendedFields);
    expect(first, hasLength(3));
    expect(second.map((item) => item.value), first.map((item) => item.value));
    expect(requests.map((uri) => uri.path), [
      '/api/search/get',
      '/api/song/detail',
    ]);
  });
}
