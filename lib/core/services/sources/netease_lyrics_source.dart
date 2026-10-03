import '../../models/audio_track.dart';
import '../../models/completion_task.dart';
import '../../models/lyrics_content.dart';
import '../metadata_source.dart';
import 'json_api_client.dart';
import 'track_search.dart';

/// Experimental anonymous, read-only endpoint, not the authenticated OpenAPI.
/// No login cookies, browser impersonation, audio download, or API bypass.
/// Public availability is not a service guarantee; see docs/LYRICS_SOURCES.md.
class NeteaseLyricsSource implements MetadataSource, SourceConnectionTester {
  NeteaseLyricsSource(this.client);
  final JsonApiClient client;

  @override
  String get name => '网易云音乐（实验性）';
  @override
  Set<AudioField> get supportedFields => const {AudioField.lyrics};

  static Uri _searchUri(String title, String artist) => Uri.https(
    'music.163.com',
    '/api/search/get',
    {'s': '$title $artist', 'type': '1', 'limit': '20', 'offset': '0'},
  );

  Map<String, dynamic> _response(Object? response) {
    if (response is! Map) throw const ApiException('网易云返回格式异常。');
    final data = Map<String, dynamic>.from(response);
    if (data['code'] != 200) {
      final code = data['code'];
      throw ApiException(
        code == 429 || code == 503
            ? '网易云暂时限流，请稍后重试。'
            : code == 301 || code == 401 || code == 403
            ? '网易云当前不允许匿名访问，已停止请求。'
            : '网易云暂时不可用（${code ?? '未知状态'}）。',
        statusCode: code is int ? code : null,
      );
    }
    return data;
  }

  @override
  Future<void> checkConnection() async {
    final result = _response(await client.getJson(_searchUri('红豆', '王菲')));
    if (result['result'] is! Map) {
      throw const ApiException('网易云搜索暂时不可用。');
    }
  }

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    if (!requestedFields.contains(AudioField.lyrics)) return const [];
    final search = TrackSearch.fromTrack(track);
    // Title-only hits cannot establish artist/version identity.
    if (!hasText(search.title) || !hasText(search.artist)) return const [];
    final response = _response(
      await client.getJson(_searchUri(search.title, search.artist!)),
    );
    final rawSongs = (response['result'] as Map?)?['songs'];
    if (rawSongs == null) return const [];
    if (rawSongs is! List) throw const ApiException('网易云搜索结果格式异常。');
    final matches = <_Song>[];
    for (final raw in rawSongs) {
      if (raw is! Map) continue;
      final id = raw['id'];
      final title = raw['name'];
      final artists = raw['artists'];
      final durationMs = raw['duration'];
      if (id is! int ||
          id <= 0 ||
          title is! String ||
          artists is! List ||
          durationMs is! num ||
          durationMs <= 0 ||
          !durationMs.isFinite) {
        continue;
      }
      final names = artists
          .whereType<Map>()
          .map((a) => a['name'])
          .whereType<String>()
          .toList();
      // Joined or leading full artist credit is acceptable; a guest alone is
      // insufficient. No fuzzy/title-only matches or live-version stripping.
      final artistCredits = [
        if (names.isNotEmpty) names.first,
        names.join('/'),
        names.join(' & '),
        names.join('、'),
      ];
      if (!search.matchesTitle(title) ||
          !search.matchesArtist(artistCredits) ||
          !search.matchesDuration(durationMs / 1000, tolerance: 3)) {
        continue;
      }
      final album = (raw['album'] as Map?)?['name'];
      matches.add(
        _Song(id, title, album is String ? album : '', durationMs / 1000),
      );
    }
    if (matches.isEmpty) return const [];
    int albumRank(_Song song) =>
        hasText(search.album) &&
            normalizedIdentity(song.album) == normalizedIdentity(search.album!)
        ? 0
        : 1;
    double distance(_Song song) => search.durationSeconds == null
        ? 0
        : (song.duration - search.durationSeconds!).abs();
    matches.sort((a, b) {
      final album = albumRank(a).compareTo(albumRank(b));
      return album == 0 ? distance(a).compareTo(distance(b)) : album;
    });
    final best = matches.first;
    // With no corroborating album/duration, same-title releases are ambiguous.
    // Never fetch every hit hoping a lyric text will disambiguate recordings.
    final ties = matches
        .where(
          (song) =>
              albumRank(song) == albumRank(best) &&
              distance(song) == distance(best),
        )
        .map((song) => song.id)
        .toSet();
    if (ties.length > 1) return const [];
    if (search.durationSeconds == null &&
        (!hasText(search.album) || albumRank(best) != 0)) {
      return const [];
    }

    final lyrics = _response(
      await client.getJson(
        Uri.https('music.163.com', '/api/song/lyric', {
          'id': best.id.toString(),
          'lv': '-1',
          'tv': '-1',
        }),
      ),
    );
    if (lyrics['nolyric'] == true || lyrics['uncollected'] == true) {
      return const [];
    }
    final original = (lyrics['lrc'] as Map?)?['lyric'];
    if (original is! String || !LyricsContent.usable(original)) return const [];
    final translated = (lyrics['tlyric'] as Map?)?['lyric'];
    final content = LyricsContent(
      original,
      chineseTranslation: translated is String ? translated : null,
    );
    final translation = content.hasChineseTranslation
        ? content.chineseTranslation
        : null;
    final delta = distance(best);
    return [
      FieldSuggestion(
        field: AudioField.lyrics,
        value: original,
        originalLyrics: original,
        chineseTranslation: translation,
        source: name,
        sourceUrl: 'https://music.163.com/song?id=${best.id}',
        matchDescription:
            '歌名/歌手匹配；${albumRank(best) == 0 ? '专辑匹配' : '专辑未核对'}；'
            '${search.durationSeconds == null ? '时长未核对' : '时长相差${delta.toStringAsFixed(1)}秒'}；${content.status}',
      ),
    ];
  }
}

class _Song {
  const _Song(this.id, this.title, this.album, this.duration);
  final int id;
  final String title;
  final String album;
  final double duration;
}
