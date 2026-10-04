import 'audio_field_validation.dart';
import 'audio_track.dart';
import 'completion_task.dart';

enum RecommendationHoldReason {
  existingValue('保留已有资料'),
  conflictingValues('候选存在分歧，需你选择'),
  unverified('需要核对来源或手动确认'),
  invalidValue('资料格式需要检查'),
  instrumental('纯音乐不补歌词'),
  unavailable('资料已变化，请重新检索');

  const RecommendationHoldReason(this.label);
  final String label;
}

/// A review default, never write permission. Only unambiguous, verified fills
/// are selected; all replacements and manual changes need a deliberate choice.
class RecommendedChanges {
  RecommendedChanges._(
    Iterable<FieldSuggestion> suggestions,
    Map<AudioField, RecommendationHoldReason> held,
  ) : suggestions = List.unmodifiable(suggestions),
      held = Map.unmodifiable(held);

  final List<FieldSuggestion> suggestions;
  final Map<AudioField, RecommendationHoldReason> held;

  factory RecommendedChanges.evaluate(AudioTrack track, CompletionTask task) {
    final grouped = <AudioField, List<FieldSuggestion>>{};
    for (final candidate in task.suggestions) {
      grouped.putIfAbsent(candidate.field, () => []).add(candidate);
    }
    final selected = <AudioField, FieldSuggestion>{};
    final held = <AudioField, RecommendationHoldReason>{};
    for (final field in AudioField.values) {
      final choices = grouped[field];
      if (choices == null) continue;
      RecommendationHoldReason? reason;
      if (track.id != task.trackId ||
          !track.detailsLoaded ||
          track.requiresTagRefresh ||
          track.readError != null ||
          task.status == TaskStatus.outdated ||
          task.status == TaskStatus.savedOriginal ||
          task.needsRecordingChoice) {
        reason = RecommendationHoldReason.unavailable;
      } else if (hasText(track.valueOf(field)) ||
          (field == AudioField.artwork &&
              (hasText(track.artworkSha256) || track.artworkNeedsCheck))) {
        reason = RecommendationHoldReason.existingValue;
      } else if (field == AudioField.lyrics && track.isInstrumental) {
        reason = RecommendationHoldReason.instrumental;
      } else if (choices.map((item) => item.value).toSet().length != 1) {
        reason = RecommendationHoldReason.conflictingValues;
      } else if (validateAudioFieldValue(field, choices.first.value) != null) {
        reason = RecommendationHoldReason.invalidValue;
      } else {
        // Equal values from duplicate providers are one decision. Choose the
        // first explicitly verified candidate, preserving stable source order.
        final verified = choices.where(
          (item) =>
              item.provenance == SuggestionProvenance.verifiedRecording &&
              !item.replaceExisting &&
              hasText(item.source) &&
              !item.machineTranslated,
        );
        if (verified.isEmpty) {
          reason = RecommendationHoldReason.unverified;
        } else {
          selected[field] = verified.first;
        }
      }
      if (reason != null) held[field] = reason;
    }
    // A pair must be valid together and against any retained existing value.
    // Do not remove unrelated good fields if one provider supplies bad counters.
    for (final (number, total) in const [
      (AudioField.trackNumber, AudioField.trackTotal),
      (AudioField.discNumber, AudioField.discTotal),
    ]) {
      final pair = <AudioField, String>{
        for (final field in [number, total])
          if (selected[field] case final candidate?) field: candidate.value,
      };
      if (pair.isNotEmpty && validateAudioFieldChanges(track, pair) != null) {
        for (final field in pair.keys) {
          selected.remove(field);
          held[field] = RecommendationHoldReason.invalidValue;
        }
      }
    }
    return RecommendedChanges._(selected.values, held);
  }
}

/// Immutable contents shown in the batch review. Opening that review creates
/// no persisted approval. Applying writes exactly these task/field snapshots.
class ReviewedTaskSelection {
  ReviewedTaskSelection({
    required this.task,
    required Iterable<FieldSuggestion> suggestions,
  }) : suggestions = List.unmodifiable(suggestions);

  final CompletionTask task;
  final List<FieldSuggestion> suggestions;
}
