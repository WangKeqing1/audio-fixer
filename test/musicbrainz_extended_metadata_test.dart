import 'dart:convert';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/services/sources/http_json_api_client.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:audio_fixer/core/services/sources/musicbrainz_source.dart';
import 'package:flutter_test/flutter_test.dart';

const _recordingId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _groupId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _extended = {
  AudioField.albumArtist,
  AudioField.year,
  AudioField.genre,
  AudioField.trackNumber,
  AudioField.trackTotal,
  AudioField.discNumber,
  AudioField.discTotal,
  AudioField.composer,
};

class _Client implements JsonApiClient {
  _Client({
    this.detail,
    this.releases = const [],
    this.recordings,
    this.handler,
  });
  final Map<String, Object?>? detail;
  final List<Map<String, Object?>> releases;
  final List<Map<String, Object?>>? recordings;
  final Future<Object?> Function(Uri)? handler;
  final calls = <Uri>[];
  @override
  Future<Object?> getJson(Uri uri) async {
    calls.add(uri);
    if (handler != null) return handler!(uri);
    return response(uri);
  }

  Object? response(Uri uri) {
    if (uri.queryParameters.containsKey('query')) {
      return {
        'count': 1,
        'offset': 0,
        'recordings': recordings ?? [_recording()],
      };
    }
    if (uri.path.startsWith('/ws/2/recording/')) return detail ?? _recording();
    return {
      'release-count': releases.length,
      'release-offset': 0,
      'releases': releases,
    };
  }
}

AudioTrack _track({String artist = 'Performer', String? album = 'Album'}) =>
    AudioTrack(
      id: 'local',
      fileName: 'Song.mp3',
      sizeBytes: 1,
      importedAt: DateTime(2026),
      title: 'Song',
      artist: artist,
      album: album,
      durationMs: 200000,
    );
List<Map<String, Object?>> _credits(String name) => [
  {
    'name': name,
    'artist': {'name': name},
  },
];
Map<String, Object?> _recording({String artist = 'Performer'}) => {
  'id': _recordingId,
  'title': 'Song',
  'length': 200000,
  'artist-credit': _credits(artist),
  'releases': <Object?>[],
};
Map<String, Object?> _release({
  String id = 'edition-one',
  String title = 'Album',
  String group = _groupId,
  String? date = '2003-12-04',
  int disc = 2,
  int discs = 2,
  int position = 2,
  int total = 3,
}) => {
  'id': id,
  'title': title,
  'date': date,
  'status': 'Official',
  'release-group': {'id': group},
  'artist-credit': [
    {'name': 'Album Artist', 'joinphrase': ' & '},
    {'name': 'Guest'},
  ],
  'genres': [
    {'name': 'art pop', 'count': 2},
  ],
  'media': [
    for (var medium = 1; medium <= discs; medium++)
      {
        'position': medium,
        'track-count': medium == disc ? total : 1,
        'track-offset': 0,
        'tracks': [
          for (var track = 1; track <= (medium == disc ? total : 1); track++)
            {
              'position': track,
              'number': medium == disc ? 'B$track' : '$track',
              'title': medium == disc && track == position ? 'Song' : 'Other',
              'length': 200000,
              'recording': medium == disc && track == position
                  ? _recording()
                  : {
                      'id': 'other-$medium-$track',
                      'title': 'Other',
                      'length': 200000,
                      'artist-credit': _credits('Performer'),
                    },
            },
        ],
      },
  ],
};
Map<String, Object?> _detail() => {
  ..._recording(),
  'genres': [
    {'name': 'synth-pop', 'count': 3},
    {'name': 'pop', 'count': 1},
    {'name': 'rock', 'count': 0},
    {'name': 'unpopular', 'count': -1},
  ],
  'relations': [
    {
      'target-type': 'work',
      'type': 'performance',
      'direction': 'forward',
      'type-id': 'a3005666-a872-32c3-ad06-98af558e99b0',
      'work': {
        'id': 'work-one',
        'title': 'Song',
        'relations': [
          {
            'target-type': 'artist',
            'type': 'composer',
            'direction': 'backward',
            'type-id': 'd59d99ea-23d4-4a80-b066-edca32ee158f',
            'target-credit': 'Credited Composer',
            'artist': {'id': 'composer-one', 'name': 'Canonical Composer'},
          },
          {
            'target-type': 'artist',
            'type': 'lyricist',
            'direction': 'backward',
            'artist': {'id': 'lyricist-one', 'name': 'Lyricist'},
          },
        ],
      },
    },
  ],
};
Future<List<FieldSuggestion>> _lookup(
  _Client client, {
  Set<AudioField> fields = _extended,
  AudioTrack? track,
}) =>
    MusicBrainzMetadataSource(MusicBrainzCatalog(client))
        .lookup(track ?? _track(), fields);
Map<AudioField, String> _values(List<FieldSuggestion> suggestions) => {
  for (final suggestion in suggestions) suggestion.field: suggestion.value,
};

void main() {
  test(
    'reads eight extended fields with proper recording and release provenance',
    () async {
      final client = _Client(detail: _detail(), releases: [_release()]);
      final suggestions = await _lookup(client);
      expect(_values(suggestions), {
        AudioField.albumArtist: 'Album Artist & Guest',
        AudioField.year: '2003',
        AudioField.genre: 'pop; synth-pop',
        AudioField.trackNumber: '2',
        AudioField.trackTotal: '3',
        AudioField.discNumber: '2',
        AudioField.discTotal: '2',
        AudioField.composer: 'Credited Composer',
      });
      expect(
        suggestions
            .singleWhere((s) => s.field == AudioField.composer)
            .sourceUrl,
        'https://musicbrainz.org/work/work-one',
      );
      expect(
        suggestions
            .singleWhere((s) => s.field == AudioField.trackNumber)
            .sourceUrl,
        'https://musicbrainz.org/release/edition-one',
      );
      expect(client.calls, hasLength(3));
      expect(
        client.calls[1].queryParameters['inc'],
        contains('work-level-rels'),
      );
      expect(client.calls[2].queryParameters['recording'], _recordingId);
      expect(client.calls[2].queryParameters['inc'], contains('recordings'));
    },
  );

  test('core-only request does not perform enrichment and comment remains unsupported', () async {
    final client = _Client();
    final source = MusicBrainzMetadataSource(MusicBrainzCatalog(client));
    expect(source.supportedFields, containsAll(_extended));
    expect(source.supportedFields, isNot(contains(AudioField.comment)));
    expect(await source.lookup(_track(), {AudioField.comment}), isEmpty);
    expect(client.calls, isEmpty);
    expect(_values(await source.lookup(_track(), {AudioField.title})), {
      AudioField.title: 'Song',
    });
    expect(client.calls, hasLength(1));
  });

  test(
    'consensus is per field across editions, without selecting first edition',
    () async {
      final editions = [
        _release(),
        _release(id: 'edition-two', date: '2004', total: 4),
      ];
      for (final releases in [editions, editions.reversed.toList()]) {
        final result = await _lookup(_Client(releases: releases));
        final values = _values(result);
        expect(values[AudioField.albumArtist], 'Album Artist & Guest');
        expect(values[AudioField.trackNumber], '2');
        expect(values[AudioField.discNumber], '2');
        expect(values[AudioField.year], isNull);
        expect(values[AudioField.trackTotal], isNull);
        expect(
          result.first.sourceUrl,
          'https://musicbrainz.org/release-group/$_groupId',
        );
      }
    },
  );

  test(
    'same-title albums with different group identities remain ambiguous',
    () async {
      final result = await _lookup(
        _Client(
          releases: [
            _release(),
            _release(id: 'other', group: 'other-group'),
          ],
        ),
      );
      expect(result, isEmpty);
    },
  );

  test(
    'an absent album requires a unique album identity over all releases',
    () async {
      final client = _Client(
        releases: [
          _release(),
          _release(id: 'other', title: 'Compilation'),
        ],
      );
      expect(await _lookup(client, track: _track(album: null)), isEmpty);
    },
  );

  test(
    'wrong album and wrong recording cannot supply release fields',
    () async {
      final wrongRecording = _release();
      final media = wrongRecording['media']! as List;
      for (final medium in media) {
        for (final item in (medium as Map)['tracks'] as List) {
          ((item as Map)['recording'] as Map)['id'] = 'other-recording';
        }
      }
      for (final release in [_release(title: 'Other album'), wrongRecording]) {
        expect(
          await _lookup(
            _Client(releases: [release]),
            fields: {AudioField.albumArtist, AudioField.trackNumber},
          ),
          isEmpty,
        );
      }
    },
  );

  test('wrong nested recording title artist or duration prevents release suggestions', () async {
    for (final replacement in [
      {'title': 'Song (live)'},
      {'length': 220000},
      {'artist-credit': _credits('Wrong artist')},
    ]) {
      final release = _release();
      final item =
          (((release['media']! as List)[1] as Map)['tracks'] as List)[1] as Map;
      (item['recording'] as Map).addAll(replacement);
      expect(
        await _lookup(
          _Client(releases: [release]),
          fields: {AudioField.trackNumber},
        ),
        isEmpty,
      );
    }
  });

  test(
    'repeated recording omits positions but preserves album artist and year',
    () async {
      final release = _release();
      final tracks = ((release['media']! as List)[1] as Map)['tracks'] as List;
      (tracks[0] as Map)['recording'] = _recording();
      (tracks[0] as Map)['title'] = 'Song';
      final values = _values(await _lookup(_Client(releases: [release])));
      expect(values[AudioField.albumArtist], 'Album Artist & Guest');
      expect(values[AudioField.year], '2003');
      expect(values[AudioField.trackNumber], isNull);
      expect(values[AudioField.discNumber], isNull);
    },
  );

  test('truncated tracklists never produce totals or positions', () async {
    final release = _release();
    ((release['media']! as List)[1] as Map)['track-count'] = 4;
    final values = _values(await _lookup(_Client(releases: [release])));
    expect(values[AudioField.albumArtist], 'Album Artist & Guest');
    for (final field in [
      AudioField.trackNumber,
      AudioField.trackTotal,
      AudioField.discNumber,
      AudioField.discTotal,
    ]) {
      expect(values[field], isNull);
    }
  });

  test('absent and invalid values are omitted, not inferred from first release date or tags', () async {
    final release = _release(date: '2003-02-30');
    release.remove('artist-credit');
    release.remove('genres');
    final detail = _recording()
      ..addAll({
        'tags': [
          {'name': 'pop', 'count': 3},
        ],
        'first-release-date': '1987',
      });
    final values = _values(
      await _lookup(_Client(detail: detail, releases: [release])),
    );
    expect(values[AudioField.year], isNull);
    expect(values[AudioField.genre], isNull);
    expect(values[AudioField.albumArtist], isNull);
    expect(values[AudioField.composer], isNull);
  });

  test('uses real release genres only when recording has none', () async {
    final values = _values(
      await _lookup(
        _Client(releases: [_release()]),
        fields: {AudioField.genre},
      ),
    );
    expect(values, {AudioField.genre: 'art pop'});
  });

  test(
    'artist aliases verify identity without replacing the credited name',
    () async {
      final recording = _recording(artist: 'Credited Performer');
      recording['artist-credit'] = [
        {
          'name': 'Credited Performer',
          'artist': {
            'name': 'Performer',
            'aliases': [
              {'name': '别名'},
            ],
          },
        },
      ];
      final client = _Client(recordings: [recording], detail: _detail());
      final result = await _lookup(
        client,
        fields: {AudioField.artist, AudioField.composer},
        track: _track(artist: '别名'),
      );
      expect(_values(result), {
        AudioField.artist: 'Credited Performer',
        AudioField.composer: 'Credited Composer',
      });
    },
  );

  test('featured artist aliases never identify the primary artist', () async {
    final recording = _recording();
    recording['artist-credit'] = [
      {'name': 'Another Performer', 'joinphrase': ' feat. '},
      {
        'name': 'Guest',
        'artist': {
          'name': 'Guest',
          'aliases': [
            {'name': 'Performer'},
          ],
        },
      },
    ];
    expect(await _lookup(_Client(recordings: [recording])), isEmpty);
  });

  test(
    'version in recording disambiguation cannot silently match studio title',
    () async {
      final recording = _recording()..['disambiguation'] = 'live at Wembley';
      expect(await _lookup(_Client(recordings: [recording])), isEmpty);
    },
  );

  test('composer requires actual work composer relationships and every medley work', () async {
    final missingWork = _detail();
    (missingWork['relations']! as List).add({
      'target-type': 'work',
      'type': 'performance',
      'work': {'id': 'second-work', 'relations': []},
    });
    final wrongRole = _detail();
    final work =
        ((wrongRole['relations']! as List).single as Map)['work'] as Map;
    ((work['relations'] as List).first as Map)['type'] = 'writer';
    for (final detail in [missingWork, wrongRole]) {
      expect(
        await _lookup(_Client(detail: detail), fields: {AudioField.composer}),
        isEmpty,
      );
    }
  });

  test('recording detail failure preserves independently verified release and core fields', () async {
    final fixture = _Client(releases: [_release()]);
    final client = _Client(
      handler: (uri) async {
        if (uri.path.endsWith(_recordingId)) {
          throw const ApiException('offline');
        }
        return fixture.response(uri);
      },
    );
    await expectLater(
      _lookup(
        client,
        fields: {AudioField.title, AudioField.composer, AudioField.albumArtist},
      ),
      throwsA(
        isA<PartialSourceException>().having(
          (e) => _values(e.suggestions),
          'safe fields',
          {
            AudioField.title: 'Song',
            AudioField.albumArtist: 'Album Artist & Guest',
          },
        ),
      ),
    );
  });

  test('release failure preserves genre and composer and does not cache failed enrichment', () async {
    final fixture = _Client(detail: _detail(), releases: [_release()]);
    var failing = true;
    final client = _Client(
      handler: (uri) async {
        if (uri.path == '/ws/2/release' && failing) {
          throw const ApiException('offline');
        }
        return fixture.response(uri);
      },
    );
    final source = MusicBrainzMetadataSource(MusicBrainzCatalog(client));
    await expectLater(
      source.lookup(_track(), _extended),
      throwsA(
        isA<PartialSourceException>().having(
          (e) => _values(e.suggestions),
          'safe fields',
          {
            AudioField.genre: 'pop; synth-pop',
            AudioField.composer: 'Credited Composer',
          },
        ),
      ),
    );
    failing = false;
    expect(await source.lookup(_track(), _extended), hasLength(8));
    expect(
      client.calls.where((uri) => uri.queryParameters.containsKey('query')),
      hasLength(1),
    );
  });

  test('missing recording detail and wrong ID never donate metadata', () async {
    final fixture = _Client();
    for (final detail in [
      null,
      {..._detail(), 'id': 'wrong-id'},
    ]) {
      final client = _Client(
        handler: (uri) async =>
            uri.path.endsWith(_recordingId) ? detail : fixture.response(uri),
      );
      if (detail == null) {
        expect(await _lookup(client, fields: {AudioField.composer}), isEmpty);
      } else {
        await expectLater(
          _lookup(client, fields: {AudioField.composer}),
          throwsA(isA<PartialSourceException>()),
        );
      }
    }
  });

  test(
    'browse follows actual page length then requires a complete stable catalog',
    () async {
      final fixture = _Client();
      final client = _Client(
        handler: (uri) async {
          if (uri.path != '/ws/2/release') return fixture.response(uri);
          final offset = int.parse(uri.queryParameters['offset']!);
          return {
            'release-count': 2,
            'release-offset': offset,
            'releases': [_release(id: 'edition-$offset')],
          };
        },
      );
      expect(_values(await _lookup(client, fields: {AudioField.trackNumber})), {
        AudioField.trackNumber: '2',
      });
      expect(client.calls.last.queryParameters['offset'], '1');
    },
  );

  test('browse is bounded and declines all edition fields when pages remain unseen', () async {
    final fixture = _Client(detail: _detail());
    final client = _Client(
      handler: (uri) async {
        if (uri.path != '/ws/2/release') return fixture.response(uri);
        final offset = int.parse(uri.queryParameters['offset']!);
        return {
          'release-count': 1000,
          'release-offset': offset,
          'releases': [_release(id: 'edition-$offset')],
        };
      },
    );
    await expectLater(
      _lookup(client),
      throwsA(
        isA<PartialSourceException>()
            .having((e) => _values(e.suggestions), 'safe fields', {
              AudioField.genre: 'pop; synth-pop',
              AudioField.composer: 'Credited Composer',
            })
            .having((e) => e.message, 'reason', contains('发行版本过多')),
      ),
    );
    expect(client.calls.where((u) => u.path == '/ws/2/release'), hasLength(3));
  });

  test(
    'slow pages stop inside caller deadline and preserve verified fields',
    () async {
      var now = DateTime(2026);
      final fixture = _Client(detail: _detail());
      final client = _Client(
        handler: (uri) async {
          now = now.add(const Duration(seconds: 11));
          if (uri.path != '/ws/2/release') return fixture.response(uri);
          return {
            'release-count': 2,
            'release-offset': 0,
            'releases': [_release()],
          };
        },
      );
      final source = MusicBrainzMetadataSource(
        MusicBrainzCatalog(client, now: () => now),
      );
      await expectLater(
        source.lookup(_track(), {..._extended, AudioField.title}),
        throwsA(
          isA<PartialSourceException>()
              .having((e) => _values(e.suggestions), 'safe fields', {
                AudioField.title: 'Song',
                AudioField.genre: 'pop; synth-pop',
                AudioField.composer: 'Credited Composer',
              })
              .having((e) => e.message, 'reason', contains('时限')),
        ),
      );
      // Search + recording details + one page consumed 33 seconds. There is
      // insufficient budget for another 12-second request and its throttle.
      expect(client.calls, hasLength(3));
      await Future<void>.delayed(Duration.zero);
      expect(client.calls, hasLength(3));
    },
  );

  test(
    'repeated page or changed total cannot establish release consensus',
    () async {
      final fixture = _Client();
      for (final changedCount in [false, true]) {
        final client = _Client(
          handler: (uri) async {
            if (uri.path != '/ws/2/release') return fixture.response(uri);
            final offset = int.parse(uri.queryParameters['offset']!);
            return {
              'release-count': changedCount && offset > 0 ? 3 : 2,
              'release-offset': offset,
              'releases': [
                _release(id: changedCount ? 'edition-$offset' : 'same-edition'),
              ],
            };
          },
        );
        expect(
          await _lookup(client, fields: {AudioField.trackNumber}),
          isEmpty,
        );
      }
    },
  );

  test('enrichment reuses the HTTP cache and existing one-second MusicBrainz budget', () async {
    final fixture = _Client(detail: _detail(), releases: [_release()]);
    var now = DateTime(2026);
    final starts = <DateTime>[];
    final client = HttpJsonApiClient(
      now: () => now,
      pause: (delay) async {
        now = now.add(delay);
      },
      transport: (uri, headers) async {
        starts.add(now);
        return ApiResponse(200, jsonEncode(fixture.response(uri)));
      },
    );
    final source = MusicBrainzMetadataSource(MusicBrainzCatalog(client));
    expect(await source.lookup(_track(), _extended), hasLength(8));
    expect(await source.lookup(_track(), _extended), hasLength(8));
    expect(starts, hasLength(3));
    expect(
      starts[1].difference(starts[0]),
      greaterThanOrEqualTo(const Duration(seconds: 1)),
    );
    expect(
      starts[2].difference(starts[1]),
      greaterThanOrEqualTo(const Duration(seconds: 1)),
    );
  });
}
