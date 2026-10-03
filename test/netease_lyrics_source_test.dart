import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
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
    final result = responses.removeAt(0);
    if (result is Exception) throw result;
    return result;
  }
}

AudioTrack track({
  String title = '歌曲',
  String? artist = '歌手',
  int? duration = 180000,
  String? album = '专辑',
}) => AudioTrack(
  id: '1',
  fileName: '$title.mp3',
  sizeBytes: 1,
  importedAt: DateTime(2026),
  title: title,
  artist: artist,
  album: album,
  durationMs: duration,
);
Map<String, Object?> song({
  int id = 123,
  String title = '歌曲',
  String artist = '歌手',
  int duration = 180000,
  String album = '专辑',
  int albumId = 10,
  String? artwork,
}) => {
  'id': id,
  'name': title,
  'artists': [
    {'name': artist},
  ],
  'album': {'id': albumId, 'name': album, 'picUrl': ?artwork},
  'duration': duration,
};
Map<String, Object?> search(List<Object?> songs) => {
  'code': 200,
  'result': {'songs': songs},
};
Map<String, Object?> detail(List<Object?> songs) => {
  'code': 200,
  'songs': songs,
};
const cover =
    'https://p1.music.126.net/W6MDlem6_FsymbnxKc_BKQ==/109951171530948990.jpg';
Map<String, Object?> lyrics({
  String original = '[00:01.000]Original example',
  String translated = '[00:01.000]原创测试译文',
}) => {
  'code': 200,
  'lrc': {'lyric': original},
  'tlyric': {'lyric': translated},
};

void main() {
  test(
    'matches Chinese identity duration and retains provider attribution',
    () async {
      final client = _Client([
        search([song()]),
        lyrics(),
      ]);
      final result = await NeteaseLyricsSource(client)
          .lookup(track(), {AudioField.lyrics});
      expect(result, hasLength(1));
      expect(result.single.sourceUrl, 'https://music.163.com/song?id=123');
      expect(result.single.chineseTranslation, '[00:01.000]原创测试译文');
      expect(client.calls, hasLength(2));
      expect(client.calls.first.queryParameters['s'], '歌曲 歌手');
    },
  );
  test(
    'does not accept same-title wrong artist, live version, or duration',
    () async {
      for (final candidate in [
        song(artist: '其他歌手'),
        song(title: '歌曲 Live'),
        song(duration: 250000),
      ]) {
        final client = _Client([
          search([candidate]),
        ]);
        expect(
          await NeteaseLyricsSource(client)
              .lookup(track(), {AudioField.lyrics}),
          isEmpty,
        );
        expect(client.calls, hasLength(1));
      }
    },
  );
  test('title only and unsupported fields cause no network request', () async {
    final client = _Client([]);
    expect(
      await NeteaseLyricsSource(client)
          .lookup(track(artist: null), {AudioField.lyrics}),
      isEmpty,
    );
    expect(
      await NeteaseLyricsSource(client).lookup(track(), {AudioField.composer}),
      isEmpty,
    );
    expect(client.calls, isEmpty);
  });
  test(
    'equally matched different recordings are not silently chosen',
    () async {
      final client = _Client([
        search([song(), song(id: 124)]),
      ]);
      expect(
        await NeteaseLyricsSource(client).lookup(track(), {AudioField.lyrics}),
        isEmpty,
      );
      expect(client.calls, hasLength(1));
    },
  );
  test('unknown duration also requires exact album evidence', () async {
    final client = _Client([
      search([song()]),
    ]);
    expect(
      await NeteaseLyricsSource(client)
          .lookup(track(duration: null, album: null), {AudioField.lyrics}),
      isEmpty,
    );
  });
  test('timestamp placeholders never count as Chinese translation', () async {
    final client = _Client([
      search([song()]),
      lyrics(translated: '[00:01.000]'),
    ]);
    final candidate = (await NeteaseLyricsSource(
      client,
    ).lookup(track(), {AudioField.lyrics})).single;
    expect(candidate.chineseTranslation, isNull);
    expect(candidate.matchDescription, contains('未提供'));
  });
  test('access denied stays an error and does not request lyrics', () async {
    final client = _Client([
      {'code': 403},
    ]);
    await expectLater(
      NeteaseLyricsSource(client).lookup(track(), {AudioField.lyrics}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
    );
    expect(client.calls, hasLength(1));
  });
  test(
    'translation defaults on and opt-out preserves original exactly',
    () async {
      for (final include in [true, false]) {
        final client = _Client([
          search([song()]),
          lyrics(),
        ]);
        final service = CompletionService(
          sources: [NeteaseLyricsSource(client)],
        );
        final result = await service.preview(
          track(),
          AppSettings(
            metadata: false,
            artwork: false,
            includeChineseTranslation: include,
          ),
        );
        expect(result.suggestions.single.value.contains('【中文】'), include);
        expect(
          result.suggestions.single.originalLyrics,
          '[00:01.000]Original example',
        );
      }
    },
  );
  test(
    'Chinese metadata cover and lyrics retain the same verified song ID',
    () async {
      final client = _Client([
        search([song(title: '红豆', artist: '王菲', album: '唱游')]),
        detail([song(title: '红豆', artist: '王菲', album: '唱游', artwork: cover)]),
        lyrics(),
      ]);
      final source = NeteaseLyricsSource(client);
      final result = await source.lookup(
        track(title: '红豆', artist: '王菲', album: '唱游'),
        source.supportedFields,
      );
      expect(result, hasLength(5));
      final values = {for (final item in result) item.field: item.value};
      expect(values[AudioField.title], '红豆');
      expect(values[AudioField.artist], '王菲');
      expect(values[AudioField.album], '唱游');
      expect(values[AudioField.artwork], cover);
      expect(result.every((item) => item.source == source.name), isTrue);
      expect(
        result.every(
          (item) => item.sourceUrl == 'https://music.163.com/song?id=123',
        ),
        isTrue,
      );
      expect(
        result
            .singleWhere((item) => item.field == AudioField.lyrics)
            .chineseTranslation,
        '[00:01.000]原创测试译文',
      );
      expect(client.calls.map((uri) => uri.path), [
        '/api/search/get',
        '/api/song/detail',
        '/api/song/lyric',
      ]);
      expect(client.calls[1].queryParameters, {'ids': '[123]'});
      expect(client.calls[2].queryParameters['id'], '123');
    },
  );
  test('metadata-only and cover-only requests never fetch lyrics', () async {
    for (final fields in [
      {AudioField.title, AudioField.artist, AudioField.album},
      {AudioField.artwork},
    ]) {
      final client = _Client([
        search([song()]),
        detail([song(artwork: cover)]),
      ]);
      final result = await NeteaseLyricsSource(client).lookup(track(), fields);
      expect(result.map((item) => item.field).toSet(), fields);
      expect(client.calls.map((uri) => uri.path), [
        '/api/search/get',
        '/api/song/detail',
      ]);
    }
  });
  test('lyric-only requests do not fetch details or album artwork', () async {
    final client = _Client([
      search([song(artwork: 'https://untrusted.example/image.jpg')]),
      lyrics(),
    ]);
    final result = await NeteaseLyricsSource(client)
        .lookup(track(), {AudioField.lyrics});
    expect(result.single.field, AudioField.lyrics);
    expect(client.calls.map((uri) => uri.path), [
      '/api/search/get',
      '/api/song/lyric',
    ]);
  });
  test(
    'metadata request rejects ambiguous recordings before detail read',
    () async {
      final client = _Client([
        search([song(), song(id: 124)]),
      ]);
      expect(
        await NeteaseLyricsSource(client)
            .lookup(track(), {AudioField.title, AudioField.artwork}),
        isEmpty,
      );
      expect(client.calls, hasLength(1));
    },
  );
  test(
    'metadata revalidates returned ID title full credits duration and album',
    () async {
      for (final incorrect in [
        song(id: 124),
        song(title: '歌曲 (Live)'),
        song(artist: '其他歌手'),
        song(duration: 181000),
        song(album: '其他专辑'),
        song(albumId: 11),
        {
          ...song(),
          'artists': [
            {'name': '歌手'},
            {'name': '额外嘉宾'},
          ],
        },
        {...song(), 'duration': double.nan},
      ]) {
        final client = _Client([
          search([song()]),
          detail([incorrect]),
        ]);
        await expectLater(
          NeteaseLyricsSource(client).lookup(track(), {AudioField.title}),
          throwsA(
            isA<ApiException>().having(
              (error) => error.message,
              'message',
              contains('不一致'),
            ),
          ),
        );
        expect(client.calls, hasLength(2));
      }
    },
  );
  test(
    'metadata uses full artist credit but a guest alone cannot match',
    () async {
      final duet = {
        ...song(),
        'artists': [
          {'name': '歌手'},
          {'name': '嘉宾'},
        ],
      };
      for (final queryArtist in ['歌手', '歌手 & 嘉宾']) {
        final client = _Client([
          search([duet]),
          detail([duet]),
        ]);
        final result = await NeteaseLyricsSource(client)
            .lookup(track(artist: queryArtist), {AudioField.artist});
        expect(result.single.value, '歌手/嘉宾');
      }
      final client = _Client([
        search([duet]),
      ]);
      expect(
        await NeteaseLyricsSource(client)
            .lookup(track(artist: '嘉宾'), {AudioField.artist}),
        isEmpty,
      );
      expect(client.calls, hasLength(1));
    },
  );
  test(
    'detail mismatch retains separately matched lyrics with a warning',
    () async {
      final client = _Client([
        search([song()]),
        detail([song(id: 124)]),
        lyrics(),
      ]);
      final result =
          await CompletionService(sources: [NeteaseLyricsSource(client)])
              .preview(
                track(),
                const AppSettings(),
                requestedFields: {AudioField.title, AudioField.lyrics},
              );
      expect(result.suggestions.single.field, AudioField.lyrics);
      expect(result.message, contains('不一致'));
      expect(client.calls.last.queryParameters['id'], '123');
    },
  );
  test(
    'lyric failure retains verified metadata and visible source warning',
    () async {
      final client = _Client([
        search([song()]),
        detail([song()]),
        const ApiException('来源拒绝访问', statusCode: 403),
      ]);
      final result =
          await CompletionService(sources: [NeteaseLyricsSource(client)])
              .preview(
                track(),
                const AppSettings(),
                requestedFields: {AudioField.album, AudioField.lyrics},
              );
      expect(result.suggestions.single.field, AudioField.album);
      expect(result.suggestions.single.value, '专辑');
      expect(result.message, contains('歌词：来源拒绝访问'));
    },
  );
  test('missing lyrics do not discard available metadata', () async {
    for (final unavailable in [
      {'code': 200, 'nolyric': true},
      {'code': 200, 'uncollected': true},
      lyrics(original: '[00:00.000]'),
    ]) {
      final client = _Client([
        search([song()]),
        detail([song()]),
        unavailable,
      ]);
      final result = await NeteaseLyricsSource(client)
          .lookup(track(), {AudioField.title, AudioField.lyrics});
      expect(result.single.field, AudioField.title);
    }
  });
  test(
    'detail refusal or cooldown prevents any subsequent lyric request',
    () async {
      for (final failure in [
        {'code': 403},
        {'code': 429},
        {'code': 503},
        ApiException('网络冷却', retryAfter: DateTime(2030)),
      ]) {
        final client = _Client([
          search([song()]),
          failure,
        ]);
        await expectLater(
          NeteaseLyricsSource(client)
              .lookup(track(), {AudioField.artwork, AudioField.lyrics}),
          throwsA(isA<ApiException>()),
        );
        expect(client.calls, hasLength(2));
      }
    },
  );
  test('only exact HTTPS provider cover assets are accepted', () {
    for (var index = 1; index <= 4; index++) {
      expect(
        isNeteaseArtworkUri(Uri.parse(cover.replaceFirst('p1.', 'p$index.'))),
        isTrue,
      );
    }
    for (final address in [
      cover.replaceFirst('https:', 'http:'),
      cover.replaceFirst('p1.', 'p5.'),
      cover.replaceFirst('music.126.net', 'music.126.net.evil.example'),
      cover.replaceFirst('p1.music.126.net', 'user@p1.music.126.net'),
      cover.replaceFirst('p1.music.126.net', 'p1.music.126.net:8443'),
      '$cover?redirect=https://evil.example',
      '$cover#fragment',
      cover.replaceFirst('.jpg', '.svg'),
      cover.replaceFirst('/109951171530948990', '/../109951171530948990'),
      'https://p1.music.126.net/api/redirect',
      'https://evil.example/image.jpg',
    ]) {
      expect(isNeteaseArtworkUri(Uri.parse(address)), isFalse, reason: address);
    }
  });
  test(
    'unsafe detail cover is rejected while verified title stays reviewable',
    () async {
      for (final address in [
        cover.replaceFirst('https:', 'http:'),
        'https://evil.example/image.jpg',
        '$cover?redirect=https://evil.example',
      ]) {
        final client = _Client([
          search([song()]),
          detail([song(artwork: address)]),
        ]);
        await expectLater(
          NeteaseLyricsSource(client)
              .lookup(track(), {AudioField.title, AudioField.artwork}),
          throwsA(
            isA<PartialSourceException>()
                .having((error) => error.suggestions.length, 'count', 1)
                .having(
                  (error) => error.suggestions.single.field,
                  'field',
                  AudioField.title,
                )
                .having((error) => error.message, 'warning', contains('HTTPS')),
          ),
        );
        expect(client.calls, hasLength(2));
      }
    },
  );
}
