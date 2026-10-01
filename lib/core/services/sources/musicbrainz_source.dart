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
    if (!search.matchesTitle(candidate.title)) return false;
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
    candidates.sort(_compareReleases);
    return candidates.first;
  }

  int _compareReleases(_ReleaseCandidate left, _ReleaseCandidate right) {
    final official = _compareBool(
      left.status?.toLowerCase() == 'official',
      right.status?.toLowerCase() == 'official',
    );
    if (official != 0) return official;

    final type = _comparePrimaryType(left.primaryType, right.primaryType);
    if (type != 0) return type;

    final date = _compareDates(left.date, right.date);
    if (date != 0) return date;

    final title = normalizedIdentity(left.title)
        .compareTo(normalizedIdentity(right.title));
    if (title != 0) return title;
    return (left.id ?? '').compareTo(right.id ?? '');
  }

  int _compareBool(bool left, bool right) {
    if (left == right) return 0;
    return left ? -1 : 1;
  }

  int _comparePrimaryType(String? left, String? right) {
    const rank = <String, int>{
      'album': 0,
      'ep': 1,
      'single': 2,
      'compilation': 3,
      'soundtrack': 4,
      'other': 5,
    };
    final leftRank = rank[left?.toLowerCase() ?? ''] ?? 6;
    final rightRank = rank[right?.toLowerCase() ?? ''] ?? 6;
    return leftRank.compareTo(rightRank);
  }

  int _compareDates(String? left, String? right) {
    final leftDate = _releaseDate(left);
    final rightDate = _releaseDate(right);
    if (leftDate == null && rightDate == null) return 0;
    if (leftDate == null) return 1;
    if (rightDate == null) return -1;
    return leftDate.compareTo(rightDate);
  }

  DateTime? _releaseDate(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$')
        .firstMatch(value);
    if (match == null) return null;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2] ?? '01');
    final day = int.parse(match[3] ?? '01');
    final date = DateTime.utc(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
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

  @override
  String get name => 'MusicBrainz';

  @override
  Set<AudioField> get supportedFields => const {
    AudioField.title,
    AudioField.artist,
    AudioField.album,
  };

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    final fields = requestedFields.intersection(supportedFields);
    if (fields.isEmpty) return const [];
    final match = await catalog.findMatch(track);
    if (match == null) return const [];

    final suggestions = <FieldSuggestion>[];
    void add(AudioField field, String? value) {
      if (!fields.contains(field) || !hasText(value)) return;
      suggestions.add(
        FieldSuggestion(
          field: field,
          value: value!.trim(),
          source: name,
          sourceUrl: match.sourceUrl,
          matchDescription: match.matchDescription,
        ),
      );
    }

    add(AudioField.title, match.title);
    add(AudioField.artist, match.artist);
    add(AudioField.album, match.releaseTitle);
    return suggestions;
  }

  @override
  Future<void> checkConnection() => catalog.checkConnection();
}

class _RecordingCandidate {
  const _RecordingCandidate({
    required this.id,
    required this.title,
    required this.artist,
    required this.artistCredits,
    required this.durationMs,
    required this.releases,
  });

  final String? id;
  final String title;
  final String? artist;
  final List<String> artistCredits;
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
        if (names.isEmpty) names.add(name!);
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
