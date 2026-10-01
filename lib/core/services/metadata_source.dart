import '../models/audio_track.dart';
import '../models/completion_task.dart';

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
