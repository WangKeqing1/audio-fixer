import 'source_query_report.dart';

/// A provider recording to be chosen by the user before field suggestions are
/// fetched. A candidate is neither a field approval nor authority to write tags.
class RecordingCandidate {
  const RecordingCandidate({
    required this.sourceName,
    required this.sourceId,
    required this.sourceUrl,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.matchDescription,
  });

  final String sourceName;
  final String sourceId;
  final String sourceUrl;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String matchDescription;

  static const maximumDurationMs = 24 * 60 * 60 * 1000;

  bool get isValid {
    final uri = Uri.tryParse(sourceUrl);
    return _validText(sourceName, 128) &&
        _validText(sourceId, 128) &&
        RegExp(r'^[a-z][a-z0-9_-]{0,31}:[A-Za-z0-9._-]{1,95}$')
            .hasMatch(sourceId) &&
        _validText(sourceUrl, 2048) &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        (!uri.hasPort || uri.port == 443) &&
        _validText(title, 4096) &&
        _validText(artist, 4096) &&
        _validText(album, 4096, allowEmpty: true) &&
        durationMs > 0 &&
        durationMs <= maximumDurationMs &&
        _validText(matchDescription, 4096);
  }

  /// Provider identity remains separate from display metadata/provenance.
  bool sameIdentity(RecordingCandidate other) =>
      sourceName == other.sourceName &&
      sourceId == other.sourceId &&
      sourceUrl == other.sourceUrl;

  /// A stored choice must still be exactly the candidate that was shown.
  bool sameAs(RecordingCandidate other) =>
      sameIdentity(other) &&
      title == other.title &&
      artist == other.artist &&
      album == other.album &&
      durationMs == other.durationMs &&
      matchDescription == other.matchDescription;

  Map<String, Object?> toJson() => {
    'sourceName': sourceName,
    'sourceId': sourceId,
    'sourceUrl': sourceUrl,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': durationMs,
    'matchDescription': matchDescription,
  };

  factory RecordingCandidate.fromJson(Map<String, dynamic> json) {
    const keys = {
      'sourceName',
      'sourceId',
      'sourceUrl',
      'title',
      'artist',
      'album',
      'durationMs',
      'matchDescription',
    };
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key)) ||
        keys
            .where((key) => key != 'durationMs')
            .any((key) => json[key] is! String) ||
        json['durationMs'] is! int) {
      throw const FormatException('录音候选格式无效。');
    }
    final result = RecordingCandidate(
      sourceName: json['sourceName'] as String,
      sourceId: json['sourceId'] as String,
      sourceUrl: json['sourceUrl'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      album: json['album'] as String,
      durationMs: json['durationMs'] as int,
      matchDescription: json['matchDescription'] as String,
    );
    if (!result.isValid) throw const FormatException('录音候选内容无效。');
    return result;
  }

  static bool _validText(String value, int limit, {bool allowEmpty = false}) =>
      value.length <= limit &&
      (allowEmpty || value.trim().isNotEmpty) &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
}

class DiscoveryResult {
  DiscoveryResult({
    List<RecordingCandidate> candidates = const [],
    List<String> diagnostics = const [],
    this.hasFailures = false,
    List<SourceQueryReport> sourceReports = const [],
  }) : candidates = List.unmodifiable(candidates),
       diagnostics = List.unmodifiable(diagnostics),
       sourceReports = List.unmodifiable(sourceReports);

  final List<RecordingCandidate> candidates;
  final List<String> diagnostics;
  final bool hasFailures;
  final List<SourceQueryReport> sourceReports;
}
