import '../../models/audio_track.dart';
import '../../models/completion_task.dart';
import '../metadata_source.dart';
import 'json_api_client.dart';
import 'track_search.dart';

/// Lyrics adapter for the public LRCLIB API.
///
/// This adapter only returns a preview candidate. It never writes to the
/// source audio file or to the local track model.
class LrclibSource implements MetadataSource, SourceConnectionTester {
  LrclibSource(this.client);

  static const _host = 'lrclib.net';
  static const _baseUrl = 'https://lrclib.net';

  final JsonApiClient client;

  @override
  String get name => 'LRCLIB';

  @override
  Set<AudioField> get supportedFields => const {AudioField.lyrics};

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    if (!requestedFields.contains(AudioField.lyrics)) return const [];

    final search = TrackSearch.fromTrack(track);
    // LRCLIB requires an artist for a signature lookup. Do not issue a broad
    // title-only query because same-title tracks are common.
    if (!hasText(search.title) || !hasText(search.artist)) return const [];

    final signatureUri = _getUri(search);
    final direct = await _getSignature(signatureUri);
    final directRecord = _record(direct);
    if (directRecord != null &&
        _matchesIdentityAndDuration(directRecord, search) &&
        _isTrue(directRecord['instrumental'])) {
      // A matching instrumental record is an authoritative no-lyrics result.
      // Do not let /api/search select a same-title vocal recording instead.
      return const [];
    }

    final directCandidate = _candidateFor(direct, search);
    if (directCandidate != null) {
      return [_suggestion(directCandidate, search, signatureUri)];
    }

    final searchUri = _searchUri(search);
    final response = await client.getJson(searchUri);
    final candidates = _searchCandidates(response, search);
    if (candidates.isEmpty) return const [];

    candidates.sort((left, right) => _compareCandidates(left, right, search));
    final best = candidates.first;
    final tied = candidates.where(
      (candidate) => _compareEvidence(candidate, best, search) == 0,
    );
    // Sync timestamps and record IDs describe presentation, not recording
    // identity. Never use them to choose between conflicting lyric texts.
    final texts = tied.map((candidate) => _lyricText(candidate.lyrics)).toSet();
    if (texts.length > 1) return const [];
    if (response is List &&
        response.any((item) {
          final record = _record(item);
          if (record == null ||
              !_isTrue(record['instrumental']) ||
              !_matchesIdentityAndDuration(record, search)) {
            return false;
          }
          final instrumental = _LrclibCandidate(
            id: _id(record['id']),
            album: _text(record['albumName']),
            duration: _number(record['duration']),
            lyrics: '',
            synced: false,
          );
          return _compareEvidence(instrumental, best, search) <= 0;
        })) {
      return const [];
    }
    return [_suggestion(best, search, searchUri)];
  }

  @override
  Future<void> checkConnection() async {
    final response = await client.getJson(
      Uri.https(_host, '/api/search', const {
        'track_name': 'Never Gonna Give You Up',
        'artist_name': 'Rick Astley',
      }),
    );
    if (response is! List) {
      throw const FormatException('LRCLIB search response is not an array.');
    }
  }

  Future<Object?> _getSignature(Uri uri) async {
    try {
      return await client.getJson(uri);
    } on ApiException catch (error) {
      // JsonApiClient normally maps a 404 to null. Treat an explicitly
      // surfaced 404 the same way so alternate clients retain the fallback.
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Uri _getUri(TrackSearch search) {
    final parameters = <String, String>{
      'track_name': search.title,
      'artist_name': search.artist!,
    };
    if (hasText(search.album)) parameters['album_name'] = search.album!;
    if (search.durationSeconds != null) {
      parameters['duration'] = _formatDuration(search.durationSeconds!);
    }
    return Uri.https(_host, '/api/get', parameters);
  }

  Uri _searchUri(TrackSearch search) => Uri.https(_host, '/api/search', {
    'track_name': search.title,
    'artist_name': search.artist!,
  });

  String _formatDuration(double value) {
    if (value == value.roundToDouble()) return value.round().toString();
    return value.toString();
  }

  _LrclibCandidate? _candidateFor(Object? payload, TrackSearch search) {
    final record = _record(payload);
    if (record == null) return null;
    return _candidateFromRecord(record, search);
  }

  List<_LrclibCandidate> _searchCandidates(
    Object? payload,
    TrackSearch search,
  ) {
    if (payload == null) return const [];
    if (payload is! List) {
      throw const FormatException('LRCLIB search response is not an array.');
    }

    final candidates = <_LrclibCandidate>[];
    for (final item in payload) {
      final candidate = _candidateFor(item, search);
      if (candidate != null) candidates.add(candidate);
    }
    return candidates;
  }

  _LrclibCandidate? _candidateFromRecord(
    Map<String, dynamic> record,
    TrackSearch search,
  ) {
    if (!_matchesIdentityAndDuration(record, search)) return null;
    if (_isTrue(record['instrumental'])) return null;

    final duration = _number(record['duration']);

    final lyric = _lyrics(record);
    if (lyric == null) return null;

    return _LrclibCandidate(
      id: _id(record['id']),
      album: _text(record['albumName']),
      duration: duration,
      lyrics: lyric.value,
      synced: lyric.synced,
    );
  }

  bool _matchesIdentityAndDuration(
    Map<String, dynamic> record,
    TrackSearch search,
  ) {
    final title = _text(record['trackName']) ?? _text(record['name']);
    final artist = _text(record['artistName']);
    if (title == null || artist == null) return false;
    if (!search.matchesTitle(title)) return false;
    if (!search.matchesArtist(_artistAlternatives(artist))) return false;
    return search.matchesDuration(_number(record['duration']), tolerance: 3);
  }

  Iterable<String> _artistAlternatives(String artist) sync* {
    yield artist;
    // A tag may omit featured performers. Only the leading artist is an
    // alternative; a guest alone cannot identify the recording. Commas are
    // not safe separators (for example, "Earth, Wind & Fire").
    final feature = RegExp(
      r'\s+(?:feat\.?|ft\.?|featuring)\s+',
      caseSensitive: false,
    ).firstMatch(artist);
    if (feature != null) yield artist.substring(0, feature.start).trim();
  }

  _Lyrics? _lyrics(Map<String, dynamic> record) {
    final synced = _text(record['syncedLyrics']);
    if (synced != null &&
        _timestamp.hasMatch(synced) &&
        _isUsableLyrics(synced)) {
      return _Lyrics(synced, synced: true);
    }

    final plain = _text(record['plainLyrics']);
    if (plain != null && _isUsableLyrics(plain)) {
      return _Lyrics(plain, synced: false);
    }
    return null;
  }

  static final _timestamp = RegExp(r'\[\d{1,3}:[0-5]\d(?:[.:]\d{1,3})?\]');
  static final _metadata = RegExp(
    r'\[(?:ar|al|ti|au|by|re|ve|length|offset):[^\]]*\]',
    caseSensitive: false,
  );

  String _lyricText(String value) => value
      .replaceAll(_timestamp, ' ')
      .replaceAll(_metadata, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();

  bool _isUsableLyrics(String value) {
    final content = _lyricText(value);
    // Avoid a Latin-centric minimum length: a short Chinese lyric can be
    // meaningful. Metadata and timestamps alone are not song lyrics.
    if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(content)) return false;
    const placeholders = {
      'placeholder',
      'test',
      'testing',
      'probe',
      'lyrics unavailable',
      'lyrics not available',
      'no lyrics',
      'instrumental',
      '暂无歌词',
      '纯音乐',
    };
    return !placeholders.contains(content);
  }

  int _compareCandidates(
    _LrclibCandidate left,
    _LrclibCandidate right,
    TrackSearch search,
  ) {
    final evidenceOrder = _compareEvidence(left, right, search);
    if (evidenceOrder != 0) return evidenceOrder;

    final syncOrder = (left.synced ? 0 : 1).compareTo(right.synced ? 0 : 1);
    if (syncOrder != 0) return syncOrder;

    return (left.id ?? '').compareTo(right.id ?? '');
  }

  int _compareEvidence(
    _LrclibCandidate left,
    _LrclibCandidate right,
    TrackSearch search,
  ) {
    final albumOrder = _albumOrder(
      left,
      search,
    ).compareTo(_albumOrder(right, search));
    if (albumOrder != 0) return albumOrder;

    final leftDuration = _durationDistance(left, search);
    final rightDuration = _durationDistance(right, search);
    final durationOrder = leftDuration.compareTo(rightDuration);
    if (durationOrder != 0) return durationOrder;

    return 0;
  }

  int _albumOrder(_LrclibCandidate candidate, TrackSearch search) {
    if (!hasText(search.album)) return 0;
    return normalizedIdentity(search.album!) ==
            normalizedIdentity(candidate.album ?? '')
        ? 0
        : 1;
  }

  double _durationDistance(_LrclibCandidate candidate, TrackSearch search) {
    if (search.durationSeconds == null || candidate.duration == null) {
      return double.infinity;
    }
    return (search.durationSeconds! - candidate.duration!).abs();
  }

  FieldSuggestion _suggestion(
    _LrclibCandidate candidate,
    TrackSearch search,
    Uri signatureUri,
  ) {
    final duration = _durationDistance(candidate, search);
    final durationText = duration.isFinite
        ? '时长匹配（相差${duration.toStringAsFixed(1)}秒）'
        : '时长未核对';
    final lyricType = candidate.synced ? '同步歌词' : '纯文本歌词';
    final albumText = !hasText(search.album)
        ? '专辑未核对'
        : _albumOrder(candidate, search) == 0
        ? '专辑匹配'
        : '来自其他或未知专辑';
    return FieldSuggestion(
      provenance:
          duration.isFinite ||
              (hasText(search.album) && _albumOrder(candidate, search) == 0)
          ? SuggestionProvenance.verifiedRecording
          : SuggestionProvenance.unverified,
      field: AudioField.lyrics,
      value: candidate.lyrics,
      source: name,
      sourceUrl: _sourceUrl(candidate.id, signatureUri),
      matchDescription: '歌名/歌手匹配；$albumText；$durationText；$lyricType',
    );
  }

  String _sourceUrl(String? id, Uri signatureUri) => id == null
      ? signatureUri.toString()
      : '$_baseUrl/api/get/${Uri.encodeComponent(id)}';

  Map<String, dynamic>? _record(Object? value) {
    if (value is! Map) return null;
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      result[entry.key.toString()] = entry.value;
    }
    return result;
  }

  String? _text(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  double? _number(Object? value) {
    final number = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value.trim())
        : null;
    return number != null && number.isFinite && number > 0 ? number : null;
  }

  bool _isTrue(Object? value) =>
      value == true ||
      (value is String && value.trim().toLowerCase() == 'true');

  String? _id(Object? value) {
    if (value is num) {
      final numeric = value.toDouble();
      if (!numeric.isFinite ||
          numeric <= 0 ||
          numeric != numeric.roundToDouble()) {
        return null;
      }
      return numeric.toInt().toString();
    }
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null && parsed > 0) return parsed.toString();
    }
    return null;
  }
}

class _LrclibCandidate {
  const _LrclibCandidate({
    required this.id,
    required this.album,
    required this.duration,
    required this.lyrics,
    required this.synced,
  });

  final String? id;
  final String? album;
  final double? duration;
  final String lyrics;
  final bool synced;
}

class _Lyrics {
  const _Lyrics(this.value, {required this.synced});

  final String value;
  final bool synced;
}
