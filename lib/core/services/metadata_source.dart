import '../models/audio_track.dart';
import '../models/completion_task.dart';

/// A source may verify independent fields before another endpoint fails.
/// The caller still validates field scope and displays the partial failure.
class PartialSourceException implements Exception {
  const PartialSourceException(this.suggestions, this.message);
  final List<FieldSuggestion> suggestions;
  final String message;
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
