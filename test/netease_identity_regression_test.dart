import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/recording_candidate.dart';
import 'package:audio_fixer/core/models/source_query_report.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
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

// Minimal public metadata observed from the exact production search/detail
// endpoints on 2026-10-04. No audio, private tags or real lyric text is retained.
const _records = [
  (354682, '我从草原来', '凤凰传奇', '我从草原来 新歌+精选', 220115, 35000),
  (
    32235934,
    'きっと青春が聞こえる',
    "μ's",
    "μ's Best Album Best Live! Collection Ⅱ",
    247866,
    3154379,
  ),
  (437605605, 'きっと青春が聞こえる', '流田Project', "流's the COVER", 252173, 34943511),
];
typedef _Record = (int, String, String, String, int, int);
Map<String, Object?> _song(_Record r, {bool detail = false}) => {
  'id': r.$1,
  'name': r.$2,
  'artists': [
    {'id': 1, 'name': r.$3},
  ],
  'album': {
    'id': r.$6,
    'name': r.$4,
    if (detail) 'picUrl': 'https://p1.music.126.net/sample/123.jpg',
    if (detail)
      'artists': [
        {'id': 1, 'name': r.$3},
      ],
  },
  'duration': r.$5,
};
Map<String, Object?> _detail(Object? song) => {
  'code': 200,
  'songs': [song],
};
AudioTrack _track(_Record r, {String? artist, String? fileName}) => AudioTrack(
  id: 'regression',
  title: r.$2,
  fileName: fileName ?? '${r.$2}.flac',
  artist: artist,
  durationMs: r.$1 == 354682 ? 220115 : 249443,
  importedAt: DateTime(2026),
  sizeBytes: 1,
);
RecordingCandidate _candidate(_Record r, {String? album}) => RecordingCandidate(
  sourceName: '网易云音乐（实验性）',
  sourceId: 'netease:${r.$1}',
  sourceUrl: 'https://music.163.com/song?id=${r.$1}',
  title: r.$2,
  artist: r.$3,
  album: album ?? r.$4,
  durationMs: r.$5,
  matchDescription: '已展示待确认的公开录音',
);

void main() {
  for (final r in _records) {
    test(
      'observed search/detail identity for ${r.$1} verifies selected recording',
      () async {
        final client = _Client([
          {
            'code': 200,
            'result': {
              'songs': [_song(r)],
              'songCount': 1,
            },
          },
          _detail(_song(r, detail: true)),
          {
            'code': 200,
            'lrc': {'lyric': '[00:01.00]Synthetic regression lyric'},
          },
        ]);
        final source = NeteaseLyricsSource(client);
        final track = r.$1 == 354682
            ? _track(r, artist: '006.凤凰传奇', fileName: '006.凤凰传奇 - 我从草原来.flac')
            : _track(r);
        final before = track.toJson();
        final discovered = await source.discover(track);
        expect(discovered.candidates.single.sourceId, 'netease:${r.$1}');
        final values = await source.lookupConfirmed(
          track,
          discovered.candidates.single,
          {
            AudioField.title,
            AudioField.artist,
            AudioField.album,
            AudioField.albumArtist,
            AudioField.artwork,
            AudioField.lyrics,
          },
        );
        expect(values, hasLength(6));
        expect(
          values.every((value) => value.sourceUrl == _candidate(r).sourceUrl),
          isTrue,
        );
        expect(client.calls.map((uri) => uri.path), [
          '/api/search/get',
          '/api/song/detail',
          '/api/song/lyric',
        ]);
        expect(client.calls.last.queryParameters['id'], r.$1.toString());
        expect(track.toJson(), before);
      },
    );
  }

  test(
    'same exact recording can fill a missing search album from detail',
    () async {
      final r = _records.first;
      final client = _Client([_detail(_song(r, detail: true))]);
      final result = await NeteaseLyricsSource(client).lookupConfirmed(
        _track(r),
        _candidate(r, album: ''),
        {AudioField.album},
      );
      expect(result.single.value, r.$4);
      expect(client.calls, hasLength(1));
    },
  );

  test('missing detail, incomplete response, provider failure and conflict stay distinct', () async {
    final r = _records.first;
    final original = _song(r, detail: true);
    final cases = <(Object?, SourceQueryOutcome, SourceFailureKind?, String)>[
      (
        {'code': 200, 'songs': []},
        SourceQueryOutcome.noMatch,
        null,
        'ID 354682',
      ),
      (
        {'code': 200, 'songs': 'bad'},
        SourceQueryOutcome.failed,
        SourceFailureKind.invalidResponse,
        '格式异常',
      ),
      (
        _detail({...original, 'artists': []}),
        SourceQueryOutcome.failed,
        SourceFailureKind.invalidResponse,
        '不完整',
      ),
      (
        _detail({...original, 'album': null}),
        SourceQueryOutcome.failed,
        SourceFailureKind.invalidResponse,
        '不完整',
      ),
      (
        {'code': 429},
        SourceQueryOutcome.failed,
        SourceFailureKind.rateLimited,
        '429',
      ),
      (
        _detail({...original, 'id': 123}),
        SourceQueryOutcome.failed,
        SourceFailureKind.identityConflict,
        'ID不一致',
      ),
      (
        _detail({...original, 'name': '${r.$2} (Live)'}),
        SourceQueryOutcome.failed,
        SourceFailureKind.identityConflict,
        '歌名不一致',
      ),
      (
        _detail({
          ...original,
          'artists': [
            {'name': r.$3},
            {'name': 'Guest'},
          ],
        }),
        SourceQueryOutcome.failed,
        SourceFailureKind.identityConflict,
        '完整歌手不一致',
      ),
      (
        _detail({
          ...original,
          'album': {'id': 999, 'name': 'Other album'},
        }),
        SourceQueryOutcome.failed,
        SourceFailureKind.identityConflict,
        '专辑不一致',
      ),
      (
        _detail({...original, 'duration': r.$5 + 1}),
        SourceQueryOutcome.failed,
        SourceFailureKind.identityConflict,
        '时长不一致',
      ),
    ];
    for (final c in cases) {
      final client = _Client([c.$1]);
      final result =
          await CompletionService(sources: [NeteaseLyricsSource(client)])
              .preview(
                _track(r),
                const AppSettings(),
                confirmedRecording: _candidate(r),
                requestedFields: {AudioField.title, AudioField.lyrics},
              );
      final report = result.sourceReports.single;
      expect(report.outcome, c.$2);
      expect(report.failureKind, c.$3);
      expect(report.message, contains(c.$4));
      expect(result.suggestions, isEmpty);
      expect(client.calls.single.path, '/api/song/detail');
      expect(SourceQueryReport.fromJson(report.toJson()).failureKind, c.$3);
    }
  });

  test(
    'query conflict is not incorrectly blamed on matching provider detail',
    () async {
      final r = _records.first;
      final client = _Client([_detail(_song(r, detail: true))]);
      final result =
          await CompletionService(sources: [NeteaseLyricsSource(client)])
              .preview(
                _track(r, artist: 'Someone else'),
                const AppSettings(),
                confirmedRecording: _candidate(r),
                requestedFields: {AudioField.lyrics},
              );
      expect(result.status, TaskStatus.failed);
      final report = result.sourceReports.single;
      expect(report.failureKind, SourceFailureKind.identityConflict);
      expect(report.message, contains('详情一致，但当前检索歌手'));
      expect(client.calls, hasLength(1));
    },
  );
}
