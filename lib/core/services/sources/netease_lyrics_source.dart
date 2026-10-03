import '../../models/audio_track.dart';
import '../../models/completion_task.dart';
import '../../models/lyrics_content.dart';
import '../metadata_source.dart';
import 'json_api_client.dart';
import 'track_search.dart';

/// Only provider-returned static HTTPS cover assets may be previewed/saved.
/// Callers downloading bytes must revalidate every redirect with this rule.
bool isNeteaseArtworkUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment &&
    const {
      'p1.music.126.net',
      'p2.music.126.net',
      'p3.music.126.net',
      'p4.music.126.net',
    }.contains(uri.host) &&
    RegExp(
      r'^/[A-Za-z0-9_-]+={0,2}/[0-9]+\.(?:jpg|jpeg|png)$',
      caseSensitive: false,
    ).hasMatch(uri.path);

/// Experimental anonymous, read-only endpoint, not the authenticated OpenAPI.
/// No login cookies, browser impersonation, audio download, or API bypass.
/// Public availability is not a service guarantee; see docs/LYRICS_SOURCES.md.
class NeteaseLyricsSource implements MetadataSource, SourceConnectionTester {
  NeteaseLyricsSource(this.client);
  final JsonApiClient client;

  @override
  String get name => '网易云音乐（实验性）';
  @override
  Set<AudioField> get supportedFields => const {
    AudioField.title,
    AudioField.artist,
    AudioField.album,
    AudioField.artwork,
    AudioField.lyrics,
  };

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
    final fields = requestedFields.intersection(supportedFields);
    if (fields.isEmpty) return const [];
    final search = TrackSearch.fromTrack(track);
    // Title-only hits cannot establish artist/version identity.
    if (!hasText(search.title) || !hasText(search.artist)) return const [];
    final response = _response(
      await client.getJson(_searchUri(search.title, search.artist!)),
    );
    final result = response['result'];
    if (result is! Map) throw const ApiException('网易云搜索结果格式异常。');
    final rawSongs = result['songs'];
    if (rawSongs == null) return const [];
    if (rawSongs is! List) throw const ApiException('网易云搜索结果格式异常。');
    final matches = <_Song>[];
    for (final raw in rawSongs) {
      final song = _Song.parse(raw);
      if (song != null && song.matches(search)) matches.add(song);
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

    final suggestions = <FieldSuggestion>[];
    final failures = <String>[];
    ApiException? firstFailure;
    var stopRequests = false;
    String matching(_Song song) =>
        '歌名/歌手匹配；${albumRank(song) == 0 ? '专辑匹配' : '专辑未核对'}；'
        '${search.durationSeconds == null ? '时长未核对' : '时长相差${distance(song).toStringAsFixed(1)}秒'}';
    if (fields.any((field) => field != AudioField.lyrics)) {
      try {
        final detail = _response(
          await client.getJson(
            Uri.https('music.163.com', '/api/song/detail', {
              'ids': '[${best.id}]',
            }),
          ),
        );
        final songs = detail['songs'];
        if (songs is! List || songs.length != 1) {
          throw const ApiException('网易云歌曲详情缺失或格式异常。');
        }
        final verified = _Song.parse(songs.single);
        if (verified == null ||
            !verified.matches(search) ||
            !verified.sameRecordingAs(best)) {
          throw const ApiException('网易云歌曲详情与已匹配录音不一致，未采用资料。');
        }
        void add(AudioField field, String value) {
          if (!fields.contains(field) || !hasText(value)) return;
          suggestions.add(
            FieldSuggestion(
              field: field,
              value: value,
              source: name,
              sourceUrl: 'https://music.163.com/song?id=${verified.id}',
              matchDescription: '${matching(verified)}；同一歌曲 ID 详情已复核',
            ),
          );
        }

        add(AudioField.title, verified.title);
        add(AudioField.artist, verified.artists.join('/'));
        add(AudioField.album, verified.album);
        if (fields.contains(AudioField.artwork) &&
            hasText(verified.artworkUrl)) {
          final artwork = Uri.tryParse(verified.artworkUrl!);
          if (artwork != null && isNeteaseArtworkUri(artwork)) {
            add(AudioField.artwork, artwork.toString());
          } else {
            failures.add('封面地址未通过可信 HTTPS 校验，未采用封面。');
          }
        }
      } on ApiException catch (error) {
        firstFailure ??= error;
        failures.add('歌曲资料：${error.message}');
        // Never issue another request once transport/cooldown/access refuses
        // this provider. An independently malformed detail payload is local
        // validation failure and does not invalidate the search identity.
        stopRequests = error.retryAfter != null || error.statusCode != null;
      }
    }
    if (fields.contains(AudioField.lyrics) && !stopRequests) {
      try {
        final lyric = await _lyrics(best, matching(best));
        if (lyric != null) suggestions.add(lyric);
      } on ApiException catch (error) {
        if (suggestions.isEmpty && failures.isEmpty) rethrow;
        firstFailure ??= error;
        failures.add('歌词：${error.message}');
      }
    }
    if (failures.isNotEmpty) {
      if (suggestions.isEmpty) {
        throw ApiException(
          failures.join('；'),
          statusCode: firstFailure?.statusCode,
          retryAfter: firstFailure?.retryAfter,
        );
      }
      throw PartialSourceException(
        List.unmodifiable(suggestions),
        failures.join('；'),
      );
    }
    return suggestions;
  }

  Future<FieldSuggestion?> _lyrics(_Song song, String matching) async {
    final lyrics = _response(
      await client.getJson(
        Uri.https('music.163.com', '/api/song/lyric', {
          'id': song.id.toString(),
          'lv': '-1',
          'tv': '-1',
        }),
      ),
    );
    if (lyrics['nolyric'] == true || lyrics['uncollected'] == true) {
      return null;
    }
    final originalBlock = lyrics['lrc'];
    if (originalBlock != null && originalBlock is! Map) {
      throw const ApiException('网易云歌词格式异常。');
    }
    final original = originalBlock is Map ? originalBlock['lyric'] : null;
    if (original is! String || !LyricsContent.usable(original)) return null;
    final translationBlock = lyrics['tlyric'];
    final translated = translationBlock is Map
        ? translationBlock['lyric']
        : null;
    final content = LyricsContent(
      original,
      chineseTranslation: translated is String ? translated : null,
    );
    final translation = content.hasChineseTranslation
        ? content.chineseTranslation
        : null;
    return FieldSuggestion(
      field: AudioField.lyrics,
      value: original,
      originalLyrics: original,
      chineseTranslation: translation,
      source: name,
      sourceUrl: 'https://music.163.com/song?id=${song.id}',
      matchDescription: '$matching；${content.status}',
    );
  }
}

class _Song {
  const _Song({
    required this.id,
    required this.title,
    required this.artists,
    required this.album,
    required this.duration,
    this.albumId,
    this.artworkUrl,
  });
  final int id;
  final String title;
  final List<String> artists;
  final String album;
  final double duration;
  final int? albumId;
  final String? artworkUrl;

  static _Song? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['name'];
    final artists = raw['artists'];
    final durationMs = raw['duration'];
    final album = raw['album'];
    if (id is! int ||
        id <= 0 ||
        title is! String ||
        !hasText(title) ||
        artists is! List ||
        artists.isEmpty ||
        artists.any(
          (artist) =>
              artist is! Map ||
              artist['name'] is! String ||
              !hasText(artist['name'] as String),
        ) ||
        durationMs is! num ||
        durationMs <= 0 ||
        !durationMs.isFinite ||
        (album != null && album is! Map)) {
      return null;
    }
    final names = artists
        .cast<Map>()
        .map((artist) => artist['name'] as String)
        .toList(growable: false);
    final albumName = album is Map ? album['name'] : null;
    final albumId = album is Map ? album['id'] : null;
    final artwork = album is Map ? album['picUrl'] : null;
    return _Song(
      id: id,
      title: title,
      artists: names,
      album: albumName is String ? albumName : '',
      duration: durationMs / 1000,
      albumId: albumId is int && albumId > 0 ? albumId : null,
      artworkUrl: artwork is String ? artwork : null,
    );
  }

  // Joined or leading full artist credit is acceptable; a guest alone is
  // insufficient. No fuzzy/title-only matches or live-version stripping.
  bool matches(TrackSearch search) =>
      search.matchesTitle(title) &&
      search.matchesArtist([
        artists.first,
        artists.join('/'),
        artists.join(' & '),
        artists.join('、'),
      ]) &&
      search.matchesDuration(duration, tolerance: 3);

  bool sameRecordingAs(_Song song) =>
      id == song.id &&
      normalizedIdentity(title) == normalizedIdentity(song.title) &&
      artists.length == song.artists.length &&
      Iterable<int>.generate(artists.length).every(
        (index) =>
            normalizedIdentity(artists[index]) ==
            normalizedIdentity(song.artists[index]),
      ) &&
      (duration - song.duration).abs() < 0.001 &&
      (!hasText(song.album) ||
          normalizedIdentity(album) == normalizedIdentity(song.album)) &&
      (song.albumId == null || albumId == song.albumId);
}
