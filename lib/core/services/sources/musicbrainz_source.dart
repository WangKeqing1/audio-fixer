import 'dart:async';
import 'dart:collection';

import '../../models/audio_track.dart';
import '../../models/completion_task.dart';
import '../metadata_source.dart';
import 'json_api_client.dart';
import 'track_search.dart';

/// A recording selected from the MusicBrainz recording search result.
///
/// The match is deliberately separate from [AudioTrack].  It is provenance
/// for a preview suggestion and never writes to the local file or its tags.
class MusicBrainzMatch {
  const MusicBrainzMatch({
    this.id,
    this.title,
    this.artist,
    this.artistIdentities = const [],
    this.releaseId,
    this.releaseTitle,
    this.releaseGroupId,
    this.durationMs,
    this.sourceUrl,
    this.matchDescription,
  });

  final String? id;
  final String? title;
  final String? artist;
  final List<String> artistIdentities;
  final String? releaseId;
  final String? releaseTitle;
  final String? releaseGroupId;
  final int? durationMs;
  final String? sourceUrl;
  final String? matchDescription;
}

/// A bounded, shared MusicBrainz recording catalog.
///
/// Both the metadata and cover sources receive the same catalog instance, so
/// a preview does not issue one recording search per source.  Successful
/// matches and clean no-result responses are cached.  Exceptions are removed
/// from the cache so a temporary network failure can be retried.
class MusicBrainzCatalog {
  MusicBrainzCatalog(
    this.client, {
    int maxCacheEntries = 128,
    DateTime Function()? now,
  }) : _maxCacheEntries = maxCacheEntries < 1 ? 1 : maxCacheEntries,
       _now = now ?? DateTime.now;

  static const _musicBrainzHost = 'musicbrainz.org';
  static const _recordingPath = '/ws/2/recording/';
  static const _probeRecordingId = 'a4fd9f68-0907-47ee-a30d-5ce6185b25da';
  static const _durationToleranceMs = 5000;

  final JsonApiClient client;
  final int _maxCacheEntries;
  final DateTime Function() _now;
  final LinkedHashMap<String, _CatalogEntry> _cache =
      LinkedHashMap<String, _CatalogEntry>();

  /// Finds a single safe recording candidate for [track].
  ///
  /// MusicBrainz relevance scores are intentionally ignored.  A result must
  /// have an exact normalized title and, when available, an exact normalized
  /// artist credit.  Known durations are used both in the query and during
  /// local validation.  Ambiguous candidates are returned as no match rather
  /// than selecting an arbitrary recording.
  Future<MusicBrainzMatch?> findMatch(AudioTrack track) {
    final search = TrackSearch.fromTrack(track);
    final key = search.key;
    final cached = _cache[key];
    if (cached != null &&
        (cached.expiresAt == null || _now().isBefore(cached.expiresAt!))) {
      // Refresh insertion order so eviction preserves recently reused matches.
      _cache.remove(key);
      _cache[key] = cached;
      return cached.pending;
    }

    final entry = _CatalogEntry(_query(search));
    _cache[key] = entry;
    _trimCache();
    unawaited(
      entry.pending.then<void>(
        (match) {
          // Share one request within a preview, but do not cache no-match forever:
          // later retries must be able to see corrections at the source.
          entry.expiresAt = _now().add(
            match == null
                ? const Duration(seconds: 30)
                : const Duration(minutes: 5),
          );
        },
        onError: (Object _, StackTrace _) {
          // An evicted in-flight request may fail after a replacement was added.
          // Remove only its own entry, never that newer request.
          if (identical(_cache[key], entry)) _cache.remove(key);
        },
      ),
    );
    return entry.pending;
  }

  /// Performs a real, harmless MusicBrainz API request for connectivity.
  ///
  /// The known recording must return its own ID.  The HTTP client remains
  /// responsible for translating non-404 failures into ApiException.
  Future<void> checkConnection() async {
    final response = await client.getJson(_buildProbeUri());
    final json = _asMap(response);
    if (json == null || json['id'] != _probeRecordingId) {
      throw const FormatException(
        'MusicBrainz connection probe returned an unexpected recording',
      );
    }
  }

  Future<MusicBrainzMatch?> _query(TrackSearch search) async {
    if (!hasText(search.title)) return null;

    // A title alone is too weak for a unique recording.  A filename-derived
    // artist or a known duration is enough to continue because both are then
    // checked against every returned candidate.
    if (!hasText(search.artist) && search.durationSeconds == null) return null;

    final response = await client.getJson(_buildSearchUri(search));
    if (response == null) return null;
    final json = _asMap(response);
    if (json == null || !json.containsKey('recordings')) {
      throw const FormatException(
        'MusicBrainz response is missing the recordings array',
      );
    }
    final recordings = _asList(json['recordings']);
    if (recordings == null) {
      throw const FormatException(
        'MusicBrainz response has an invalid recordings array',
      );
    }
    if (recordings.isEmpty) return null;
    // The API ranks and paginates results. One matching item on the first page
    // is not proof of uniqueness if additional candidates were not inspected.
    final count = _asInt(json['count']);
    final offset = _asInt(json['offset']) ?? 0;
    if (offset != 0 || (count != null && count > recordings.length)) {
      return null;
    }

    final candidates = <_RecordingCandidate>[];
    for (final item in recordings) {
      final candidate = _RecordingCandidate.fromJson(item);
      if (candidate == null || !_matches(search, candidate)) continue;
      if (!_hasRequestedAlbum(search, candidate)) continue;
      candidates.add(candidate);
    }
    if (candidates.isEmpty) return null;

    // Multiple releases can describe the same recording.  They are one
    // identity; different recording IDs with the same known fields are
    // ambiguous and must not be chosen by API score or list order.
    final byIdentity = <String, _RecordingCandidate>{};
    for (final candidate in candidates) {
      byIdentity.putIfAbsent(candidate.identityKey, () => candidate);
    }
    final candidate = _chooseRecording(search, byIdentity.values);
    if (candidate == null) return null;
    final release = _chooseRelease(search, candidate.releases);
    final match = MusicBrainzMatch(
      id: candidate.id,
      title: candidate.title,
      artist: candidate.artist,
      artistIdentities: candidate.artistCredits,
      releaseId: release?.id,
      releaseTitle: release?.title,
      releaseGroupId: release?.releaseGroupId,
      durationMs: candidate.durationMs,
      sourceUrl: candidate.id == null
          ? null
          : 'https://$_musicBrainzHost/recording/${candidate.id}',
      matchDescription: _describe(search, candidate, release),
    );
    return match;
  }

  _RecordingCandidate? _chooseRecording(
    TrackSearch search,
    Iterable<_RecordingCandidate> candidates,
  ) {
    final list = candidates.toList(growable: false);
    if (list.length == 1) return list.single;
    // Without a local album identity there is no evidence that makes one of
    // otherwise identical recordings safer than another.
    if (!hasText(search.album)) return null;

    final official = list
        .where(
          (candidate) => _hasOfficialAlbumRelease(candidate, search.album!),
        )
        .toList(growable: false);
    if (official.length != 1) return null;
    final winner = official.single;
    final competitors = list.where((candidate) => candidate != winner);
    if (!competitors.every(
      (candidate) =>
          _hasOnlyUnknownOrBootlegAlbumRelease(candidate, search.album!),
    )) {
      return null;
    }
    return winner;
  }

  bool _hasOfficialAlbumRelease(_RecordingCandidate candidate, String album) =>
      _matchingAlbumReleases(
        candidate,
        album,
      ).any((release) => release.status?.trim().toLowerCase() == 'official');

  bool _hasOnlyUnknownOrBootlegAlbumRelease(
    _RecordingCandidate candidate,
    String album,
  ) {
    final releases = _matchingAlbumReleases(candidate, album);
    // A recording with no expanded releases carries no contrary status
    // evidence, so it is treated as unknown for this one disambiguation.
    if (releases.isEmpty) return candidate.releases.isEmpty;
    return releases.every((release) {
      final status = release.status?.trim().toLowerCase();
      return status == null || status.isEmpty || status == 'bootleg';
    });
  }

  List<_ReleaseCandidate> _matchingAlbumReleases(
    _RecordingCandidate candidate,
    String album,
  ) {
    final wanted = normalizedIdentity(album);
    return candidate.releases
        .where((release) => normalizedIdentity(release.title) == wanted)
        .toList(growable: false);
  }

  bool _matches(TrackSearch search, _RecordingCandidate candidate) {
    if (!search.matchesTitle(candidate.title) ||
        _hasConflictingVersion(search.title, candidate.disambiguation)) {
      return false;
    }
    if (!search.matchesArtist(candidate.artistCredits)) return false;
    if (!search.matchesDuration(
      candidate.durationMs == null ? null : candidate.durationMs! / 1000,
      tolerance: _durationToleranceMs / 1000,
    )) {
      return false;
    }
    return true;
  }

  bool _hasRequestedAlbum(TrackSearch search, _RecordingCandidate candidate) {
    if (!hasText(search.album) || candidate.releases.isEmpty) return true;
    final wanted = normalizedIdentity(search.album!);
    return candidate.releases.any(
      (release) => normalizedIdentity(release.title) == wanted,
    );
  }

  _ReleaseCandidate? _chooseRelease(
    TrackSearch search,
    List<_ReleaseCandidate> releases,
  ) {
    if (releases.isEmpty) return null;
    final candidates = hasText(search.album)
        ? releases
              .where(
                (release) =>
                    normalizedIdentity(release.title) ==
                    normalizedIdentity(search.album!),
              )
              .toList()
        : List<_ReleaseCandidate>.from(releases);
    if (candidates.isEmpty) return null;
    // A recording can occur on several editions with different dates and
    // tracklists. Never use relevance, release date, or UUID order to select
    // an edition. A shared album identity can still supply album/group data.
    final identities = <String, _ReleaseCandidate>{};
    for (final candidate in candidates) {
      identities.putIfAbsent(candidate.id ?? candidate.title, () => candidate);
    }
    if (identities.length == 1) return identities.values.single;
    final first = candidates.first;
    if (!hasText(first.releaseGroupId) ||
        !candidates.every(
          (item) =>
              item.releaseGroupId == first.releaseGroupId &&
              normalizedIdentity(item.title) == normalizedIdentity(first.title),
        )) {
      return null;
    }
    return _ReleaseCandidate(
      id: null,
      title: first.title,
      releaseGroupId: first.releaseGroupId,
      status: null,
      primaryType: null,
      date: null,
    );
  }

  String _describe(
    TrackSearch search,
    _RecordingCandidate candidate,
    _ReleaseCandidate? release,
  ) {
    final duration = candidate.durationMs == null
        ? '未知'
        : '${(candidate.durationMs! / 1000).toStringAsFixed(1)}秒';
    return '标题=${candidate.title}；歌手=${candidate.artist ?? '未知'}；'
        '专辑=${release?.title ?? search.album ?? '未知'}；时长=$duration';
  }

  Uri _buildSearchUri(TrackSearch search) {
    final clauses = <String>['recording:"${_escapeLucene(search.title)}"'];
    if (hasText(search.artist)) {
      clauses.add('artist:"${_escapeLucene(search.artist!)}"');
    }
    if (hasText(search.album)) {
      clauses.add('release:"${_escapeLucene(search.album!)}"');
    }
    if (search.durationSeconds != null) {
      final durationMs = (search.durationSeconds! * 1000).round();
      final minimum = (durationMs - _durationToleranceMs).clamp(0, 1 << 31);
      final maximum = durationMs + _durationToleranceMs;
      clauses.add('dur:[$minimum TO $maximum]');
    }
    return Uri.https(_musicBrainzHost, _recordingPath, {
      'query': clauses.join(' AND '),
      'fmt': 'json',
      'limit': '25',
      'inc': 'artist-credits releases release-groups',
    });
  }

  Uri _buildProbeUri() => Uri.https(
    _musicBrainzHost,
    '$_recordingPath$_probeRecordingId',
    {'fmt': 'json'},
  );

  void _trimCache() {
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  static String _escapeLucene(String value) {
    const reserved = r'+-&|!(){}[]^"~*?:\/';
    final buffer = StringBuffer();
    for (final character in value.runes) {
      final text = String.fromCharCode(character);
      if (reserved.contains(text)) buffer.write('\\');
      buffer.write(text);
    }
    return buffer.toString();
  }
}

class _CatalogEntry {
  _CatalogEntry(this.pending);

  final Future<MusicBrainzMatch?> pending;
  DateTime? expiresAt;
}

class MusicBrainzMetadataSource
    implements MetadataSource, SourceConnectionTester {
  MusicBrainzMetadataSource(this.catalog);

  final MusicBrainzCatalog catalog;

  static const _releaseFields = {
    AudioField.albumArtist,
    AudioField.year,
    AudioField.trackNumber,
    AudioField.trackTotal,
    AudioField.discNumber,
    AudioField.discTotal,
  };
  // MusicBrainz may return fewer than the requested releases because a page
  // includes at most 500 tracks. Never keep crawling a popular catalog.
  static const _maxReleasePages = 3;

  @override
  String get name => 'MusicBrainz';

  @override
  Set<AudioField> get supportedFields => const {
    AudioField.title,
    AudioField.artist,
    AudioField.album,
    AudioField.albumArtist,
    AudioField.year,
    AudioField.genre,
    AudioField.trackNumber,
    AudioField.trackTotal,
    AudioField.discNumber,
    AudioField.discTotal,
    AudioField.composer,
  };

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    final fields = requestedFields.intersection(supportedFields);
    if (fields.isEmpty) return const [];
    final budget = _LookupBudget(catalog._now);
    final match = await budget.run(
      () => catalog.findMatch(track),
      initial: true,
    );
    if (match == null) return const [];

    final suggestions = <FieldSuggestion>[];
    void add(AudioField field, String? value, {String? url, String? context}) {
      if (!fields.contains(field) || !hasText(value)) return;
      suggestions.add(
        FieldSuggestion(
          field: field,
          value: value!.trim(),
          source: name,
          sourceUrl: url ?? match.sourceUrl,
          matchDescription: context ?? match.matchDescription,
        ),
      );
    }

    add(AudioField.title, match.title);
    add(AudioField.artist, match.artist);
    add(AudioField.album, match.releaseTitle);
    if (!hasText(match.id)) return suggestions;

    // Each independent endpoint may fail without discarding verified fields
    // from another endpoint. The completion layer displays partial failures.
    final failures = <String>[];
    String? recordingGenre;
    if (fields.contains(AudioField.genre) ||
        fields.contains(AudioField.composer)) {
      try {
        final detail = await _recordingDetails(track, match, budget);
        if (detail != null) {
          recordingGenre = _genres(detail);
          add(AudioField.genre, recordingGenre);
          final composer = _composer(detail);
          add(AudioField.composer, composer?.name, url: composer?.url);
        }
      } on TimeoutException {
        failures.add('查询达到时限，已保留已核实资料');
      } on Exception {
        failures.add('录音流派或作曲资料查询失败');
      }
    }

    if (fields.intersection(_releaseFields).isNotEmpty ||
        (fields.contains(AudioField.genre) && recordingGenre == null)) {
      try {
        final releases = await _releaseDetails(track, match, budget);
        if (releases != null && releases.isNotEmpty) {
          final group = _asString(
            _asMap(releases.first['release-group'])?['id'],
          );
          final url = releases.length == 1
              ? 'https://musicbrainz.org/release/${releases.single['id']}'
              : 'https://musicbrainz.org/release-group/$group';
          final context =
              '${match.matchDescription}；'
              '${releases.length == 1 ? '已核对发行版本' : '${releases.length} 个同专辑版本资料一致'}';
          final values = releases
              .map((release) => _releaseValues(release, match.id!))
              .toList();
          for (final field in _releaseFields) {
            add(
              field,
              _consensus(values.map((value) => value[field])),
              url: url,
              context: context,
            );
          }
          if (recordingGenre == null) {
            add(
              AudioField.genre,
              _consensus(releases.map(_genres)),
              url: url,
              context: context,
            );
          }
        }
      } on TimeoutException {
        failures.add('查询达到时限，发行版本资料未确认');
      } on _IncompleteReleaseBrowse {
        failures.add('发行版本过多，未遍历的版本仍可能不同，发行资料暂不提供');
      } on Exception {
        failures.add('发行版本或音轨资料查询失败');
      }
    }
    if (failures.isNotEmpty) {
      throw PartialSourceException(
        suggestions,
        'MusicBrainz：${failures.join('；')}',
      );
    }
    return suggestions;
  }

  @override
  Future<void> checkConnection() => catalog.checkConnection();

  Future<Map<String, Object?>?> _recordingDetails(
    AudioTrack track,
    MusicBrainzMatch match,
    _LookupBudget budget,
  ) async {
    final response = await budget.run(
      () => catalog.client.getJson(
        Uri.https('musicbrainz.org', '/ws/2/recording/${match.id}', {
          'fmt': 'json',
          'inc': 'artist-credits genres work-rels work-level-rels artist-rels',
        }),
      ),
    );
    if (response == null) return null;
    final detail = _asMap(response);
    if (detail == null || detail['id'] != match.id) {
      throw const FormatException('Unexpected MusicBrainz recording detail');
    }
    return _matchesRecording(detail, track, match) ? detail : null;
  }

  bool _matchesRecording(
    Map<String, Object?> detail,
    AudioTrack track,
    MusicBrainzMatch match,
  ) {
    final candidate = _RecordingCandidate.fromJson(detail);
    if (candidate == null || candidate.id != match.id) return false;
    final search = TrackSearch.fromTrack(track);
    if (!search.matchesTitle(candidate.title) ||
        _hasConflictingVersion(search.title, candidate.disambiguation) ||
        !search.matchesDuration(
          candidate.durationMs == null ? null : candidate.durationMs! / 1000,
          tolerance: MusicBrainzCatalog._durationToleranceMs / 1000,
        )) {
      return false;
    }
    // Preserve the exact primary credit/aliases already verified by search.
    // A secondary or featured artist is never sufficient evidence.
    return search.matchesArtist(candidate.artistCredits) ||
        candidate.artistCredits.any(
          (name) => match.artistIdentities.any(
            (identity) =>
                normalizedIdentity(identity) == normalizedIdentity(name),
          ),
        );
  }

  Future<List<Map<String, Object?>>?> _releaseDetails(
    AudioTrack track,
    MusicBrainzMatch match,
    _LookupBudget budget,
  ) async {
    final releases = <Map<String, Object?>>[];
    final ids = <String>{};
    var offset = 0;
    int? expectedCount;
    var complete = false;
    for (var page = 0; page < _maxReleasePages; page++) {
      final response = await budget.run(
        () => catalog.client.getJson(
          Uri.https('musicbrainz.org', '/ws/2/release', {
            'recording': match.id!,
            'inc': 'recordings artist-credits release-groups genres',
            'fmt': 'json',
            'limit': '100',
            'offset': '$offset',
          }),
        ),
      );
      if (response == null) return null;
      final json = _asMap(response);
      final batch = _asList(json?['releases']);
      final count = _asInt(json?['release-count']);
      final actualOffset = _asInt(json?['release-offset']);
      if (json == null ||
          batch == null ||
          count == null ||
          count < 0 ||
          actualOffset != offset) {
        throw const FormatException('Incomplete MusicBrainz release browse');
      }
      if (expectedCount != null && expectedCount != count) return null;
      expectedCount = count;
      for (final raw in batch) {
        final release = _asMap(raw);
        final id = _asString(release?['id']);
        if (release == null || !hasText(id) || !ids.add(id!)) return null;
        releases.add(release);
      }
      offset += batch.length;
      if (offset == count) {
        complete = true;
        break;
      }
      if (batch.isEmpty || offset > count) return null;
    }
    // An unseen edition could disagree with every field already observed.
    if (!complete) throw const _IncompleteReleaseBrowse();
    final search = TrackSearch.fromTrack(track);
    final selected = <Map<String, Object?>>[];
    final albumIdentities = <String>{};
    for (final release in releases) {
      final title = _asString(release['title']);
      if (!hasText(title)) return null;
      if (hasText(search.album) &&
          normalizedIdentity(title!) != normalizedIdentity(search.album!)) {
        continue;
      }
      final groupId = _asString(_asMap(release['release-group'])?['id']);
      final media = _asList(release['media']);
      if (media == null || media.isEmpty) return null;
      var containsRecording = false;
      for (final rawMedium in media) {
        final tracks = _asList(_asMap(rawMedium)?['tracks']);
        if (tracks == null) return null;
        for (final rawTrack in tracks) {
          final releaseTrack = _asMap(rawTrack);
          final recording = _asMap(releaseTrack?['recording']);
          if (recording?['id'] != match.id) continue;
          // Never borrow a different recording's sequence numbers or accept
          // contradictory title/artist/duration data even under the same ID.
          if (!_matchesRecording(recording!, track, match)) return null;
          final trackTitle = _asString(releaseTrack?['title']);
          final trackLength = _asInt(releaseTrack?['length']);
          if ((hasText(trackTitle) && !search.matchesTitle(trackTitle!)) ||
              (trackLength != null &&
                  !search.matchesDuration(
                    trackLength / 1000,
                    tolerance: MusicBrainzCatalog._durationToleranceMs / 1000,
                  ))) {
            return null;
          }
          containsRecording = true;
        }
      }
      if (!containsRecording) return null;
      // Without group IDs, only one concrete release can identify the album.
      albumIdentities.add(
        '${groupId ?? release['id']}|${normalizedIdentity(title!)}',
      );
      selected.add(release);
    }
    if (albumIdentities.length != 1) return null;
    return selected;
  }

  Map<AudioField, String?> _releaseValues(
    Map<String, Object?> release,
    String recordingId,
  ) {
    final credits = _RecordingCandidate._artistCreditNames(release);
    final result = <AudioField, String?>{
      AudioField.albumArtist: credits.isEmpty ? null : credits.last,
      AudioField.year: _releaseYear(_asString(release['date'])),
    };
    final media = _asList(release['media']);
    if (media == null || media.isEmpty) return result;
    final mediaCount = _asInt(release['media-count']);
    if (mediaCount != null && mediaCount != media.length) return result;
    final mediumPositions = <int>{};
    final occurrences = <Map<AudioField, String>>[];
    for (final rawMedium in media) {
      final medium = _asMap(rawMedium);
      final disc = _positiveInt(medium?['position']);
      final total = _positiveInt(medium?['track-count']);
      final tracks = _asList(medium?['tracks']);
      final trackOffset = _asInt(medium?['track-offset']) ?? 0;
      if (disc == null ||
          disc > media.length ||
          !mediumPositions.add(disc) ||
          total == null ||
          tracks == null ||
          tracks.length != total ||
          trackOffset != 0) {
        return result;
      }
      final positions = <int>{};
      for (final rawTrack in tracks) {
        final item = _asMap(rawTrack);
        final position = _positiveInt(item?['position']);
        if (position == null || position > total || !positions.add(position)) {
          return result;
        }
        if (_asMap(item?['recording'])?['id'] != recordingId) continue;
        occurrences.add({
          AudioField.trackNumber: '$position',
          AudioField.trackTotal: '$total',
          AudioField.discNumber: '$disc',
          AudioField.discTotal: '${media.length}',
        });
      }
    }
    // A recording repeated on a release has no uniquely known track position.
    if (occurrences.length == 1) result.addAll(occurrences.single);
    return result;
  }

  String? _genres(Map<String, Object?> json) {
    final genres = <String, String>{};
    for (final raw in _asList(json['genres']) ?? const []) {
      final item = _asMap(raw);
      final name = _asString(item?['name']);
      final votes = _asInt(item?['count']);
      if (!hasText(name) || votes == null || votes <= 0) continue;
      genres.putIfAbsent(normalizedIdentity(name!), () => name.trim());
    }
    final keys = genres.keys.toList()..sort();
    return keys.isEmpty ? null : keys.map((key) => genres[key]).join('; ');
  }

  ({String name, String url})? _composer(Map<String, Object?> recording) {
    final works = <Map<String, Object?>>[];
    for (final raw in _asList(recording['relations']) ?? const []) {
      final relation = _asMap(raw);
      if (relation?['target-type'] != 'work' ||
          relation?['type'] != 'performance') {
        continue;
      }
      final typeId = _asString(relation?['type-id']);
      if (typeId != null && typeId != 'a3005666-a872-32c3-ad06-98af558e99b0') {
        continue;
      }
      final work = _asMap(relation?['work']);
      if (work != null) works.add(work);
    }
    if (works.isEmpty) return null;
    final composers = <String, String>{};
    for (final work in works) {
      final workComposers = <String, String>{};
      for (final raw in _asList(work['relations']) ?? const []) {
        final relation = _asMap(raw);
        if (relation?['target-type'] != 'artist' ||
            relation?['type'] != 'composer' ||
            relation?['direction'] != 'backward') {
          continue;
        }
        final typeId = _asString(relation?['type-id']);
        if (typeId != null &&
            typeId != 'd59d99ea-23d4-4a80-b066-edca32ee158f') {
          continue;
        }
        final artist = _asMap(relation?['artist']);
        final credit = _asString(relation?['target-credit']);
        final name = hasText(credit) ? credit : _asString(artist?['name']);
        if (!hasText(name)) continue;
        final key = _asString(artist?['id']) ?? normalizedIdentity(name!);
        workComposers.putIfAbsent(key, () => name!.trim());
      }
      // A medley may have several works; missing credits for any one work
      // must not silently turn an incomplete composer list into a full one.
      if (workComposers.isEmpty) return null;
      composers.addAll(workComposers);
    }
    final names = composers.values.toList()..sort();
    final id = works.length == 1 ? _asString(works.single['id']) : null;
    return (
      name: names.join('; '),
      url: id == null
          ? 'https://musicbrainz.org/recording/${recording['id']}'
          : 'https://musicbrainz.org/work/$id',
    );
  }
}

String? _consensus(Iterable<String?> values) {
  final list = values.toList();
  if (list.isEmpty || !hasText(list.first)) return null;
  return list.every((value) => value == list.first) ? list.first : null;
}

class _IncompleteReleaseBrowse implements Exception {
  const _IncompleteReleaseBrowse();
}

/// Finish before CompletionService's 45-second outer timeout, retaining any
/// independently verified suggestions. Reserve a normal 12-second request
/// plus the provider throttle before starting another endpoint or page.
class _LookupBudget {
  _LookupBudget(this.now) : startedAt = now();
  final DateTime Function() now;
  final DateTime startedAt;
  static const _total = Duration(seconds: 40);
  static const _requestReserve = Duration(seconds: 14);

  Future<T> run<T>(Future<T> Function() request, {bool initial = false}) {
    final remaining = _total - now().difference(startedAt);
    if (remaining <= Duration.zero ||
        (!initial && remaining < _requestReserve)) {
      throw TimeoutException('MusicBrainz lookup budget exhausted');
    }
    // The client owns an already queued HTTP request. Timeout cannot cancel
    // that request, but stops this adapter from initiating any further pages.
    return request().timeout(remaining);
  }
}

int? _positiveInt(Object? value) {
  final number = _asInt(value);
  return number != null && number > 0 ? number : null;
}

String? _releaseYear(String? value) {
  final match = RegExp(r'^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$')
      .firstMatch(value ?? '');
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2] ?? '01');
  final day = int.parse(match[3] ?? '01');
  final date = DateTime.utc(year, month, day);
  return year > 0 && date.year == year && date.month == month && date.day == day
      ? '$year'
      : null;
}

class _RecordingCandidate {
  const _RecordingCandidate({
    required this.id,
    required this.title,
    required this.artist,
    required this.artistCredits,
    required this.disambiguation,
    required this.durationMs,
    required this.releases,
  });

  final String? id;
  final String title;
  final String? artist;
  final List<String> artistCredits;
  final String? disambiguation;
  final int? durationMs;
  final List<_ReleaseCandidate> releases;

  String get identityKey {
    if (hasText(id)) return 'id:$id';
    return [
      normalizedIdentity(title),
      normalizedIdentity(artist ?? ''),
      durationMs?.toString() ?? '',
    ].join('|');
  }

  static _RecordingCandidate? fromJson(Object? value) {
    final json = _asMap(value);
    if (json == null) return null;
    final title = _asString(json['title']);
    if (!hasText(title)) return null;
    final credits = _artistCreditNames(json);
    final artist = credits.isEmpty ? null : credits.last;
    final releases = (_asList(json['releases']) ?? const [])
        .map(_ReleaseCandidate.fromJson)
        .whereType<_ReleaseCandidate>()
        .toList();
    return _RecordingCandidate(
      id: _asString(json['id']),
      title: title!,
      artist: artist,
      artistCredits: credits,
      disambiguation: _asString(json['disambiguation']),
      durationMs: _asInt(json['length']),
      releases: releases,
    );
  }

  static List<String> _artistCreditNames(Map<String, Object?> json) {
    final names = <String>[];
    final phrase = StringBuffer();
    final credits = _asList(json['artist-credit']);
    if (credits != null) {
      for (final item in credits) {
        final credit = _asMap(item);
        if (credit == null) continue;
        final name =
            _asString(credit['name']) ??
            _asString(_asMap(credit['artist'])?['name']);
        if (!hasText(name)) continue;
        // A guest credit alone does not identify the primary recording artist.
        // Retain the first billed artist plus the complete credit phrase.
        if (names.isEmpty) {
          names.add(name!);
          final artist = _asMap(credit['artist']);
          final canonical = _asString(artist?['name']);
          if (hasText(canonical)) names.add(canonical!);
          for (final rawAlias in _asList(artist?['aliases']) ?? const []) {
            final alias = _asString(_asMap(rawAlias)?['name']);
            if (hasText(alias)) names.add(alias!);
          }
        }
        phrase.write(name);
        phrase.write(_asString(credit['joinphrase']) ?? '');
      }
    }
    final creditPhrase = phrase.toString().trim();
    if (hasText(creditPhrase)) names.add(creditPhrase);
    final explicitPhrase = _asString(json['artist-credit-phrase']);
    if (hasText(explicitPhrase)) names.add(explicitPhrase!);
    return names;
  }
}

class _ReleaseCandidate {
  const _ReleaseCandidate({
    required this.id,
    required this.title,
    required this.releaseGroupId,
    required this.status,
    required this.primaryType,
    required this.date,
  });

  final String? id;
  final String title;
  final String? releaseGroupId;
  final String? status;
  final String? primaryType;
  final String? date;

  static _ReleaseCandidate? fromJson(Object? value) {
    final json = _asMap(value);
    if (json == null) return null;
    final title = _asString(json['title']);
    if (!hasText(title)) return null;
    final group = _asMap(json['release-group']);
    return _ReleaseCandidate(
      id: _asString(json['id']),
      title: title!,
      releaseGroupId:
          _asString(json['release-group-id']) ?? _asString(group?['id']),
      status: _asString(json['status']),
      primaryType:
          _asString(group?['primary-type']) ?? _asString(json['primary-type']),
      date: _asString(json['date']),
    );
  }
}

Map<String, Object?>? _asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map<String, Object?>((key, value) => MapEntry('$key', value));
  }
  return null;
}

List<Object?>? _asList(Object? value) {
  if (value is List<Object?>) return value;
  if (value is List) return List<Object?>.from(value);
  return null;
}

String? _asString(Object? value) => value is String ? value : null;

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.isFinite ? value.round() : null;
  return int.tryParse(value?.toString() ?? '');
}

// Distinguish variants even when MusicBrainz stores the qualifier only in its
// disambiguation text instead of the recording title.
bool _hasConflictingVersion(String title, String? disambiguation) {
  if (!hasText(disambiguation)) return false;
  for (final version in const [
    'live',
    'acoustic',
    'instrumental',
    'karaoke',
    'remix',
    'demo',
  ]) {
    final pattern = RegExp('\\b$version\\b', caseSensitive: false);
    if (pattern.hasMatch(disambiguation!) && !pattern.hasMatch(title)) {
      return true;
    }
  }
  return false;
}
