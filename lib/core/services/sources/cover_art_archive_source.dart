import '../../models/audio_track.dart';
import '../../models/completion_task.dart';
import '../metadata_source.dart';
import 'json_api_client.dart';
import 'musicbrainz_source.dart';

/// Looks up a verified front cover from Cover Art Archive for the recording
/// selected by [MusicBrainzCatalog].
class CoverArtArchiveSource implements MetadataSource, SourceConnectionTester {
  CoverArtArchiveSource(this.client, this.catalog);

  static const _host = 'coverartarchive.org';
  static const _probeReleaseId = '76df3287-6cda-33eb-8e9a-044b5e15ffdd';

  final JsonApiClient client;
  final MusicBrainzCatalog catalog;

  @override
  String get name => 'Cover Art Archive';

  @override
  Set<AudioField> get supportedFields => const {AudioField.artwork};

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    if (!requestedFields.contains(AudioField.artwork)) return const [];
    final match = await catalog.findMatch(track);
    if (match == null) return const [];

    final cover = await _findCover(match);
    if (cover == null) return const [];
    return [
      FieldSuggestion(
        provenance: SuggestionProvenance.verifiedRecording,
        field: AudioField.artwork,
        value: cover.imageUrl,
        source: name,
        sourceUrl: cover.sourceUrl,
        matchDescription: match.matchDescription,
      ),
    ];
  }

  /// A 404 from the probe is a valid response from a reachable API.  Other
  /// errors deliberately propagate through [JsonApiClient].
  @override
  Future<void> checkConnection() async {
    final response = await client.getJson(_releaseUri(_probeReleaseId));
    if (response == null) return;
    _validatedImages(response);
  }

  Future<_CoverCandidate?> _findCover(MusicBrainzMatch match) async {
    if (hasText(match.releaseId)) {
      final releaseUri = _releaseUri(match.releaseId!);
      final response = await client.getJson(releaseUri);
      final cover = _parseCover(response, releaseUri);
      if (cover != null) return cover;

      // The API returns null for a 404.  A release-group image is a bounded
      // fallback and is attempted only after that missing release response.
      if (response == null && hasText(match.releaseGroupId)) {
        final groupUri = _releaseGroupUri(match.releaseGroupId!);
        final groupResponse = await client.getJson(groupUri);
        return _parseCover(groupResponse, groupUri);
      }
      return null;
    }

    if (hasText(match.releaseGroupId)) {
      final groupUri = _releaseGroupUri(match.releaseGroupId!);
      final response = await client.getJson(groupUri);
      return _parseCover(response, groupUri);
    }
    return null;
  }

  _CoverCandidate? _parseCover(Object? response, Uri sourceUri) {
    final images = _validatedImages(response);
    if (images == null) return null;
    for (final image in images) {
      if (image is! Map) continue;
      if (image['front'] != true || image['approved'] != true) continue;
      final urls = <String>[];
      final thumbnails = image['thumbnails'];
      if (thumbnails is Map) {
        // Prefer bounded real thumbnail sizes before the original image, then
        // retain deterministic ordering for custom thumbnail keys.
        for (final key in const ['500', '1200', 'large', '250', 'small']) {
          final value = thumbnails[key];
          if (value is String) urls.add(value);
        }
        final remainingKeys =
            thumbnails.keys
                .where(
                  (key) => !const [
                    '500',
                    '1200',
                    'large',
                    '250',
                    'small',
                  ].contains('$key'),
                )
                .map((key) => '$key')
                .toList()
              ..sort();
        for (final key in remainingKeys) {
          final value = thumbnails[key];
          if (value is String) urls.add(value);
        }
      }
      final direct = image['image'];
      if (direct is String) urls.add(direct);
      for (final url in urls) {
        final normalizedUrl = _normalizeArtworkUrl(url);
        if (normalizedUrl != null) {
          return _CoverCandidate(
            imageUrl: normalizedUrl,
            sourceUrl: sourceUri.toString(),
          );
        }
      }
    }
    return null;
  }

  List<Object?>? _validatedImages(Object? response) {
    if (response == null) return null;
    if (response is! Map || !response.containsKey('images')) {
      throw const FormatException(
        'Cover Art Archive response is missing the images array',
      );
    }
    final images = response['images'];
    if (images is! List) {
      throw const FormatException(
        'Cover Art Archive response has an invalid images array',
      );
    }
    return List<Object?>.from(images);
  }

  Uri _releaseUri(String id) => Uri.https(_host, '/release/$id');

  Uri _releaseGroupUri(String id) => Uri.https(_host, '/release-group/$id');

  String? _normalizeArtworkUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    if (uri.userInfo.isNotEmpty || uri.hasPort) return null;
    final host = uri.host.toLowerCase();
    final allowedHost =
        host == _host ||
        host.endsWith('.$_host') ||
        host == 'archive.org' ||
        host.endsWith('.archive.org');
    if (!allowedHost) return null;
    return uri.replace(scheme: 'https').toString();
  }
}

class _CoverCandidate {
  const _CoverCandidate({required this.imageUrl, required this.sourceUrl});

  final String imageUrl;
  final String sourceUrl;
}
