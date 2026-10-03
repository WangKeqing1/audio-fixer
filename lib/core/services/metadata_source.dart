import '../models/audio_track.dart';
import '../models/completion_task.dart';
import '../models/recording_candidate.dart';
import 'sources/json_api_client.dart';

/// A healthy source answered, but its candidates cannot be safely identified.
/// Keep the explanation visible without reporting a network/provider failure.
class SourceNoMatch implements Exception {
  const SourceNoMatch(this.message);
  final String message;
}

/// A source may verify independent fields before another endpoint fails.
/// The caller still validates field scope and displays the partial failure.
class PartialSourceException implements Exception {
  const PartialSourceException(this.suggestions, this.message, {this.cause});
  final List<FieldSuggestion> suggestions;
  final String message;
  final Object? cause;
}

/// Implement one adapter per real provider. Adapters return candidates with
/// provenance; they never mutate local tags or the original audio file.
abstract interface class MetadataSource {
  String get name;
  Set<AudioField> get supportedFields;

  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  );
}

abstract interface class SourceConnectionTester {
  Future<void> checkConnection();
}

/// Discovery may show title-only results, but may not choose one or produce
/// field suggestions. Confirmed lookup must verify and retain that recording.
abstract interface class RecordingDiscoverySource implements MetadataSource {
  Future<DiscoveryResult> discover(AudioTrack track);

  Future<List<FieldSuggestion>> lookupConfirmed(
    AudioTrack track,
    RecordingCandidate recording,
    Set<AudioField> requestedFields,
  );
}

/// Keep the actionable deadline if independent endpoints fail differently.
/// A later schema error must not erase a rate limit, and an earlier schema
/// error must not hide a later cooldown. No extra request is made here.
Object preferredSourceFailure(Object? previous, Object current) {
  if (previous == null) return current;
  if (current is ApiException && current.retryAt != null) {
    if (previous is! ApiException ||
        previous.retryAt == null ||
        !current.retryAt!.isBefore(previous.retryAt!)) {
      return current;
    }
  }
  return previous;
}
