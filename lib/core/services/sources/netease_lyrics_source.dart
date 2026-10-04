import '../../models/audio_track.dart';
import '../../models/completion_task.dart';
import '../../models/lyrics_content.dart';
import '../../models/recording_candidate.dart';
import '../../models/source_query_report.dart';
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
class NeteaseLyricsSource
    implements
        MetadataSource,
        RecordingDiscoverySource,
        SourceConnectionTester {
  NeteaseLyricsSource(this.client);
  final JsonApiClient client;

  @override
  String get name => '网易云音乐（实验性）';
  @override
  Set<AudioField> get supportedFields => const {
    AudioField.title,
    AudioField.artist,
    AudioField.album,
    AudioField.albumArtist,
    AudioField.year,
    AudioField.trackNumber,
    AudioField.artwork,
    AudioField.lyrics,
  };

  static Uri _searchUri(String title, String artist) =>
      Uri.https('music.163.com', '/api/search/get', {
        's': [title, artist].where(hasText).join(' '),
        'type': '1',
        'limit': '20',
        'offset': '0',
      });

  Map<String, dynamic> _response(Object? response) {
    if (response is! Map) {
      throw const ApiException(
        '网易云返回格式异常。',
        kind: SourceFailureKind.invalidResponse,
      );
    }
    final data = Map<String, dynamic>.from(response);
    if (data['code'] != 200) {
      final code = data['code'];
      throw ApiException(
        code == 429
            ? '网易云限制请求（429），请稍后重试。'
            : code == 503
            ? '网易云服务暂不可用（503）。'
            : code == 301 || code == 401 || code == 403
            ? '网易云当前不允许匿名访问，已停止请求。'
            : '网易云暂时不可用（${code is int ? code : '未知状态'}）。',
        statusCode: code is int ? code : null,
        kind: code is int ? null : SourceFailureKind.invalidResponse,
      );
    }
    return data;
  }

  @override
  Future<void> checkConnection() async {
    final result = _response(await client.getJson(_searchUri('红豆', '王菲')));
    if (result['result'] is! Map) {
      throw const ApiException(
        '网易云搜索暂时不可用。',
        kind: SourceFailureKind.invalidResponse,
      );
    }
  }

  @override
  Future<DiscoveryResult> discover(AudioTrack track) async {
    final search = TrackSearch.fromTrack(track);
    if (!hasText(search.title)) {
      return DiscoveryResult(diagnostics: ['没有可用于查找录音的歌名，请手动填写检索词。']);
    }
    final response = _response(
      await client.getJson(_searchUri(search.title, '')),
    );
    final result = response['result'];
    if (result is! Map) {
      throw const ApiException(
        '网易云搜索结果格式异常。',
        kind: SourceFailureKind.invalidResponse,
      );
    }
    final rawSongs = result['songs'];
    if (rawSongs != null && rawSongs is! List) {
      throw const ApiException(
        '网易云搜索结果格式异常。',
        kind: SourceFailureKind.invalidResponse,
      );
    }
    final songs = rawSongs as List? ?? const [];
    final total = result['songCount'];
    final totalNotice = total is int && total >= songs.length
        ? '（来源报告共 $total 条）'
        : '';
    if (songs.isEmpty) {
      return DiscoveryResult(diagnostics: ['按歌名查询，来源返回 0 条结果$totalNotice。']);
    }
    var invalidCount = 0;
    var titleCount = 0;
    var durationCount = 0;
    var artistCount = 0;
    var duplicateCount = 0;
    final candidates = <RecordingCandidate>[];
    final seen = <int, RecordingCandidate>{};
    final conflictingIds = <int>{};
    // Match only the bounded page actually requested; never crawl variants.
    for (final raw in songs.take(20)) {
      final song = _Song.parse(raw);
      if (song == null) {
        invalidCount++;
        continue;
      }
      final titleEvidence = song.discoveryTitleEvidence(search);
      if (titleEvidence == null) {
        titleCount++;
        continue;
      }
      if (!search.matchesDuration(song.duration, tolerance: 3)) {
        durationCount++;
        continue;
      }
      if (!song.matchesArtist(search)) {
        artistCount++;
        continue;
      }
      final candidate = RecordingCandidate(
        sourceName: name,
        sourceId: 'netease:${song.id}',
        sourceUrl: 'https://music.163.com/song?id=${song.id}',
        title: song.title,
        artist: song.artists.join('/'),
        album: song.album,
        durationMs: (song.duration * 1000).round(),
        matchDescription:
            '$titleEvidence；'
            '${search.durationSeconds == null ? '本地时长未知，未核对时长' : '时长相差${(song.duration - search.durationSeconds!).abs().toStringAsFixed(3)}秒（不超过3秒）'}；'
            '${hasText(search.artist) ? '检索歌手匹配' : '检索未限定歌手，尚未确认录音身份'}；'
            '请核对歌手、专辑和版本后选择',
      );
      if (!candidate.isValid) {
        invalidCount++;
      } else if (seen.containsKey(song.id)) {
        duplicateCount++;
        if (!seen[song.id]!.sameAs(candidate)) {
          conflictingIds.add(song.id);
          candidates.removeWhere((item) => item.sourceId == candidate.sourceId);
        }
      } else {
        seen[song.id] = candidate;
        candidates.add(candidate);
      }
    }
    if (search.durationSeconds != null) {
      candidates.sort((a, b) {
        final distance = (a.durationMs - track.durationMs!).abs().compareTo(
          (b.durationMs - track.durationMs!).abs(),
        );
        return distance == 0 ? a.sourceId.compareTo(b.sourceId) : distance;
      });
    }
    final count = candidates.length;
    return DiscoveryResult(
      candidates: candidates.take(5).toList(),
      diagnostics: [
        '按歌名查询，本页返回 ${songs.length} 条$totalNotice，检查 ${songs.take(20).length} 条；'
            '歌名或版本不符 $titleCount 条、时长不符 $durationCount 条、'
            '歌手不符 $artistCount 条、资料无效 $invalidCount 条、重复 ID $duplicateCount 条；'
            '${conflictingIds.isEmpty ? '' : '已排除资料冲突的 ${conflictingIds.length} 个 ID；'}'
            '保留 $count 条录音候选${count > 5 ? '，仅展示前 5 条' : ''}。',
        if (total is int && total > songs.length)
          '当前仅核对首个结果页，未查询其余 ${total - songs.length} 条。',
        if (count > 0)
          '${hasText(search.artist) ? '请进一步确认录音版本' : '检索未限定歌手，需要先选择并确认录音'}；'
              '不会自动选择，也尚未查询歌词或封面。',
      ],
    );
  }

  @override
  Future<List<FieldSuggestion>> lookupConfirmed(
    AudioTrack track,
    RecordingCandidate recording,
    Set<AudioField> requestedFields,
  ) async {
    final fields = requestedFields.intersection(supportedFields);
    if (fields.isEmpty) return const [];
    final match = RegExp(r'^netease:([1-9][0-9]{0,18})$')
        .firstMatch(recording.sourceId);
    final id = match == null ? null : int.tryParse(match.group(1)!);
    if (!recording.isValid ||
        recording.sourceName != name ||
        id == null ||
        recording.sourceUrl != 'https://music.163.com/song?id=$id') {
      throw const SourceNoMatch('已选录音的网易云身份无效，请重新查找并选择。');
    }
    final search = TrackSearch.fromTrack(track);
    if (!hasText(search.title) ||
        !search.matchesDuration(recording.durationMs / 1000, tolerance: 3)) {
      throw const SourceNoMatch('当前检索歌名或时长已变化，请重新查找并选择录音。');
    }
    // Confirmation is an ID lookup, never another search or best-hit fallback.
    // Even a lyrics-only request must first verify the complete chosen record.
    final detail = _response(
      await client.getJson(
        Uri.https('music.163.com', '/api/song/detail', {'ids': '[$id]'}),
      ),
    );
    final songs = detail['songs'];
    final verified = songs is List && songs.length == 1
        ? _Song.parse(songs.single)
        : null;
    if (verified == null ||
        verified.id != id ||
        verified.title != recording.title ||
        verified.artists.join('/') != recording.artist ||
        verified.album != recording.album ||
        (verified.duration * 1000).round() != recording.durationMs ||
        !verified.matchesArtist(search) ||
        !search.matchesDuration(verified.duration, tolerance: 3)) {
      throw const SourceNoMatch(
        '歌曲详情与已选录音的 ID、歌名、完整歌手、专辑或时长不一致，未采用任何资料；请重新查找。',
      );
    }
    if (verified.discoveryTitleEvidence(search) == null) {
      throw const SourceNoMatch(
        '已选录音详情未提供与原检索歌名一致的名称或来源别名，无法复核歌名证据；未查询歌词，请重新查找。',
      );
    }
    return _lookupSelected(
      search,
      verified,
      fields,
      '${recording.matchDescription}；用户已选择录音，ID、歌名、完整歌手、专辑和时长已复核',
      confirmedDetail: detail,
    );
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
    if (result is! Map) {
      throw const ApiException(
        '网易云搜索结果格式异常。',
        kind: SourceFailureKind.invalidResponse,
      );
    }
    final rawSongs = result['songs'];
    if (rawSongs == null) return const [];
    if (rawSongs is! List) {
      throw const ApiException(
        '网易云搜索结果格式异常。',
        kind: SourceFailureKind.invalidResponse,
      );
    }
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
    if (ties.length > 1) {
      if (fields.any(
        (field) => const {
          AudioField.albumArtist,
          AudioField.year,
          AudioField.trackNumber,
        }.contains(field),
      )) {
        throw const SourceNoMatch('候选录音或专辑存在歧义，未采用专辑资料。');
      }
      return const [];
    }
    if (search.durationSeconds == null &&
        (!hasText(search.album) || albumRank(best) != 0)) {
      return const [];
    }

    return _lookupSelected(
      search,
      best,
      fields,
      '歌名/歌手匹配；${albumRank(best) == 0 ? '专辑匹配' : '专辑未核对'}；'
      '${search.durationSeconds == null ? '时长未核对' : '时长相差${distance(best).toStringAsFixed(1)}秒'}',
    );
  }

  Future<List<FieldSuggestion>> _lookupSelected(
    TrackSearch search,
    _Song best,
    Set<AudioField> fields,
    String matching, {
    Map<String, dynamic>? confirmedDetail,
  }) async {
    final suggestions = <FieldSuggestion>[];
    final failures = <String>[];
    ApiException? firstFailure;
    var stopRequests = false;
    if (fields.any((field) => field != AudioField.lyrics)) {
      try {
        final detail =
            confirmedDetail ??
            _response(
              await client.getJson(
                Uri.https('music.163.com', '/api/song/detail', {
                  'ids': '[${best.id}]',
                }),
              ),
            );
        final songs = detail['songs'];
        if (songs is! List || songs.length != 1) {
          throw const ApiException(
            '网易云歌曲详情缺失或格式异常。',
            kind: SourceFailureKind.invalidResponse,
          );
        }
        final verified = _Song.parse(songs.single);
        if (verified == null ||
            (confirmedDetail == null && !verified.matches(search)) ||
            !verified.sameRecordingAs(best)) {
          throw const ApiException('网易云歌曲详情与已匹配录音不一致，未采用资料。');
        }
        void add(AudioField field, String value, {String? evidence}) {
          if (!fields.contains(field) || !hasText(value)) return;
          suggestions.add(
            FieldSuggestion(
              provenance: SuggestionProvenance.verifiedRecording,
              field: field,
              value: value,
              source: name,
              sourceUrl: 'https://music.163.com/song?id=${verified.id}',
              matchDescription:
                  '$matching；同一歌曲 ID 详情已复核'
                  '${evidence == null ? '' : '；$evidence'}',
            ),
          );
        }

        add(AudioField.title, verified.title);
        add(AudioField.artist, verified.artists.join('/'));
        add(AudioField.album, verified.album);
        final albumFields = fields.intersection(const {
          AudioField.albumArtist,
          AudioField.year,
          AudioField.trackNumber,
        });
        if (albumFields.isNotEmpty) {
          // These values describe this specific album's recording. A song
          // credit is not an album credit, nor is album.size a per-disc total.
          if (verified.albumId == null || !hasText(verified.album)) {
            failures.add('专辑身份不明确，未采用专辑歌手、年份或音轨序号。');
          } else {
            final raw = songs.single as Map;
            final album = raw['album'] as Map;
            final context = '专辑 ID ${verified.albumId}';
            if (albumFields.contains(AudioField.albumArtist)) {
              final credits = album['artists'];
              if (credits is List && credits.isNotEmpty) {
                final names = _artistNames(credits);
                if (names != null) {
                  add(
                    AudioField.albumArtist,
                    names.join('/'),
                    evidence: '$context 的完整专辑署名',
                  );
                } else {
                  failures.add('专辑歌手署名不完整，未采用专辑歌手。');
                }
              } else if (credits != null && credits is! List) {
                failures.add('专辑歌手格式异常，未采用专辑歌手。');
              }
            }
            if (albumFields.contains(AudioField.year)) {
              final timestamp = album['publishTime'];
              if (timestamp != null) {
                final date = _releaseDate(timestamp);
                if (date == null) {
                  failures.add('专辑发行时间缺失、为零或格式异常，未采用年份。');
                } else if (date.subtract(const Duration(hours: 12)).year !=
                        date.year ||
                    date.add(const Duration(hours: 14)).year != date.year) {
                  // The anonymous endpoint does not specify a release-date
                  // timezone. Do not silently choose a year at its boundary.
                  failures.add('专辑发行时间位于跨年时区边界，未推定年份。');
                } else {
                  add(
                    AudioField.year,
                    date.year.toString(),
                    evidence: '$context 的发行年份（publishTime=$timestamp，UTC）',
                  );
                }
              }
            }
            if (albumFields.contains(AudioField.trackNumber)) {
              final number = raw['no'];
              final albumSize = album['size'];
              if (number != null) {
                if (number is int &&
                    number > 0 &&
                    number <= 65535 &&
                    !(albumSize is int &&
                        albumSize > 0 &&
                        number > albumSize)) {
                  add(
                    AudioField.trackNumber,
                    number.toString(),
                    evidence: '$context 中当前歌曲的明确音轨序号',
                  );
                } else {
                  failures.add('当前歌曲的专辑音轨序号无效或冲突，未采用音轨序号。');
                }
              }
            }
          }
        }
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
        firstFailure =
            preferredSourceFailure(firstFailure, error) as ApiException;
        failures.add('歌曲资料：${error.message}');
        // Never issue another request once transport/cooldown/access refuses
        // this provider. An independently malformed detail payload is local
        // validation failure and does not invalidate the search identity.
        stopRequests = error.retryAfter != null || error.statusCode != null;
      }
    }
    if (fields.contains(AudioField.lyrics) && !stopRequests) {
      try {
        final lyric = await _lyrics(best, matching);
        if (lyric != null) suggestions.add(lyric);
      } on ApiException catch (error) {
        if (suggestions.isEmpty && failures.isEmpty) rethrow;
        firstFailure =
            preferredSourceFailure(firstFailure, error) as ApiException;
        failures.add('歌词：${error.message}');
      }
    }
    if (failures.isNotEmpty) {
      if (suggestions.isEmpty) {
        throw ApiException(
          failures.join('；'),
          statusCode: firstFailure?.statusCode,
          retryAfter: firstFailure?.retryAfter,
          kind: firstFailure?.failureKind,
          provider: firstFailure?.provider,
          serverRetryAfter: firstFailure?.serverRetryAfter,
          isLocalCooldown: firstFailure?.isLocalCooldown ?? false,
        );
      }
      throw PartialSourceException(
        List.unmodifiable(suggestions),
        failures.join('；'),
        cause: firstFailure,
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
      throw const ApiException(
        '网易云歌词格式异常。',
        kind: SourceFailureKind.invalidResponse,
      );
    }
    final original = originalBlock is Map ? originalBlock['lyric'] : null;
    if (original != null && original is! String) {
      throw const ApiException(
        '网易云歌词文本格式异常。',
        kind: SourceFailureKind.invalidResponse,
      );
    }
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
      provenance: SuggestionProvenance.verifiedRecording,
      field: AudioField.lyrics,
      value: original,
      originalLyrics: original,
      chineseTranslation: translation,
      source: name,
      sourceUrl: 'https://music.163.com/song?id=${song.id}',
      matchDescription: '$matching；${content.status}',
    );
  }

  static DateTime? _releaseDate(Object value) {
    if (value is! int || value == 0) return null;
    try {
      final date = DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      return date.year >= 1 && date.year <= 9999 ? date : null;
    } on ArgumentError {
      return null;
    }
  }
}

List<String>? _artistNames(Object? raw) {
  if (raw is! List || raw.isEmpty) return null;
  final names = <String>[];
  for (final artist in raw) {
    if (artist is! Map) return null;
    final name = artist['name'];
    if (name is! String || !hasText(name)) return null;
    names.add(name);
  }
  return names;
}

class _Song {
  const _Song({
    required this.id,
    required this.title,
    required this.artists,
    required this.album,
    required this.duration,
    this.aliases = const [],
    this.albumId,
    this.artworkUrl,
  });
  final int id;
  final String title;
  final List<String> artists;
  final String album;
  final double duration;
  final List<String> aliases;
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
      aliases: _providerAliases(raw),
      albumId: albumId is int && albumId > 0 ? albumId : null,
      artworkUrl: artwork is String ? artwork : null,
    );
  }

  // Joined or leading full artist credit is acceptable; a guest alone is
  // insufficient. No fuzzy/title-only matches or live-version stripping.
  bool matches(TrackSearch search) =>
      search.matchesTitle(title) &&
      matchesArtist(search) &&
      search.matchesDuration(duration, tolerance: 3);

  bool matchesArtist(TrackSearch search) => search.matchesArtist([
    artists.first,
    artists.join('/'),
    artists.join(' & '),
    artists.join('、'),
  ]);

  String? discoveryTitleEvidence(TrackSearch search) {
    if (search.matchesTitle(title)) return '来源歌名与检索歌名一致';
    // A bare translated/alternative alias must never erase an explicit live,
    // remix or instrumental qualifier on either title. Versioned recordings
    // use the complete primary title; no guessed alias-to-version mapping.
    if (_recordingVersion.hasMatch(title) ||
        _recordingVersion.hasMatch(search.title)) {
      return null;
    }
    for (final alias in aliases) {
      if (!_recordingVersion.hasMatch(alias) && search.matchesTitle(alias)) {
        return '来源明确提供的别名“$alias”与检索歌名一致';
      }
    }
    return null;
  }

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

final _recordingVersion = RegExp(
  r'\b(?:live|remix|instrumental|acoustic|remaster(?:ed)?|edition|version|mix|edit|karaoke|cover|bootleg|sped[ -]?up|slowed)\b|'
  r'伴奏|纯音乐|純音樂|现场|現場|重制|重製|重混|版本|翻唱|カラオケ|ライブ|リミックス|インスト',
  caseSensitive: false,
);

List<String> _providerAliases(Map raw) {
  final result = <String>{};
  for (final key in ['alias', 'transNames', 'transName']) {
    final value = raw[key];
    for (final alias in value is List ? value.take(20) : [value]) {
      if (alias is String &&
          hasText(alias) &&
          alias.length <= 1024 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(alias)) {
        result.add(alias);
      }
    }
  }
  return List.unmodifiable(result);
}
