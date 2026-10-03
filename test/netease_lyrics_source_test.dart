import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
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
}) => {
  'id': id,
  'name': title,
  'artists': [
    {'name': artist},
  ],
  'album': {'name': album},
  'duration': duration,
};
Map<String, Object?> search(List<Object?> songs) => {
  'code': 200,
  'result': {'songs': songs},
};
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
      await NeteaseLyricsSource(client).lookup(track(), {AudioField.artwork}),
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
}
