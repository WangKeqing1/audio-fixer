import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/recommended_changes.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

FieldSuggestion suggestion(
  AudioField field,
  String value, {
  SuggestionProvenance provenance = SuggestionProvenance.verifiedRecording,
  String source = 'Verified fixture',
  bool replace = false,
}) => FieldSuggestion(
  field: field,
  value: value,
  source: source,
  provenance: provenance,
  replaceExisting: replace,
);

CompletionTask task(
  List<FieldSuggestion> choices, {
  TaskStatus status = TaskStatus.needsReview,
}) => CompletionTask(
  trackId: 'fixture',
  trackTitle: '测试歌曲',
  createdAt: DateTime(2026),
  status: status,
  message: '',
  suggestions: choices,
  isRepair: true,
);

void main() {
  test('only verified missing nonconflicting fields are recommended', () {
    final album = suggestion(AudioField.album, 'Album');
    final choices = [
      album,
      suggestion(AudioField.title, 'Replacement', replace: true),
      suggestion(AudioField.lyrics, 'Lyrics one'),
      suggestion(AudioField.lyrics, 'Lyrics two'),
      suggestion(
        AudioField.genre,
        'Manual',
        provenance: SuggestionProvenance.manual,
      ),
      suggestion(
        AudioField.composer,
        'Old source',
        provenance: SuggestionProvenance.unverified,
      ),
    ];
    final result = RecommendedChanges.evaluate(fixtureTrack(), task(choices));
    expect(result.suggestions, [same(album)]);
    expect(
      result.held[AudioField.title],
      RecommendationHoldReason.existingValue,
    );
    expect(
      result.held[AudioField.lyrics],
      RecommendationHoldReason.conflictingValues,
    );
    expect(result.held[AudioField.genre], RecommendationHoldReason.unverified);
    expect(
      result.held[AudioField.composer],
      RecommendationHoldReason.unverified,
    );
  });

  test('duplicate equal values choose one deterministic trusted candidate', () {
    final first = suggestion(AudioField.album, 'Album', source: 'A');
    final second = suggestion(AudioField.album, 'Album', source: 'B');
    final result = RecommendedChanges.evaluate(
      fixtureTrack(),
      task([first, second]),
    );
    expect(result.suggestions.single, same(first));
    expect(result.held, isEmpty);
  });

  test('an unverified competing value still prevents a default choice', () {
    final result = RecommendedChanges.evaluate(
      fixtureTrack(),
      task([
        suggestion(AudioField.album, 'Album'),
        suggestion(
          AudioField.album,
          'Another',
          provenance: SuggestionProvenance.unverified,
        ),
      ]),
    );
    expect(result.suggestions, isEmpty);
    expect(
      result.held[AudioField.album],
      RecommendationHoldReason.conflictingValues,
    );
  });

  test(
    'existing values and artwork digest stay untouched even without a path',
    () {
      final track = AudioTrack(
        id: 'fixture',
        fileName: 'test.mp3',
        sizeBytes: 1,
        importedAt: DateTime(2026),
        album: 'Keep this',
        artworkSha256: 'retained-cover',
      );
      final result = RecommendedChanges.evaluate(
        track,
        task([
          suggestion(AudioField.album, 'New', replace: true),
          suggestion(AudioField.artwork, 'https://example.test/new.jpg'),
        ]),
      );
      expect(result.suggestions, isEmpty);
      expect(
        result.held.values,
        everyElement(RecommendationHoldReason.existingValue),
      );
    },
  );

  test(
    'invalid numeric values and contradictory pairs are held independently',
    () {
      final album = suggestion(AudioField.album, 'Album');
      final result = RecommendedChanges.evaluate(
        fixtureTrack(),
        task([
          album,
          suggestion(AudioField.year, 'unknown'),
          suggestion(AudioField.trackNumber, '12'),
          suggestion(AudioField.trackTotal, '10'),
        ]),
      );
      expect(result.suggestions, [same(album)]);
      expect(
        result.held.values,
        everyElement(RecommendationHoldReason.invalidValue),
      );
    },
  );

  test(
    'no defaults for unreadable, outdated, stale-tag or instrumental lyrics',
    () {
      final lyrics = suggestion(AudioField.lyrics, 'Lyrics');
      expect(
        RecommendedChanges.evaluate(
          fixtureTrack(readError: 'Failed'),
          task([lyrics]),
        ).suggestions,
        isEmpty,
      );
      expect(
        RecommendedChanges.evaluate(
          fixtureTrack(),
          task([lyrics], status: TaskStatus.outdated),
        ).suggestions,
        isEmpty,
      );
      final stale = AudioTrack.fromJson({
        ...fixtureTrack().toJson(),
        'tagReadVersion': 0,
      });
      expect(
        RecommendedChanges.evaluate(stale, task([lyrics])).suggestions,
        isEmpty,
      );
      final instrumental = RecommendedChanges.evaluate(
        fixtureTrack().withInstrumental(true),
        task([lyrics]),
      );
      expect(instrumental.suggestions, isEmpty);
      expect(
        instrumental.held[AudioField.lyrics],
        RecommendationHoldReason.instrumental,
      );
    },
  );

  test('typed provenance survives transformations and persistence; old data is untrusted', () {
    const candidate = FieldSuggestion(
      field: AudioField.lyrics,
      value: 'Original lyrics',
      source: 'Fixture',
      chineseTranslation: '中文歌词',
      provenance: SuggestionProvenance.verifiedRecording,
    );
    final transformed = candidate
        .withChineseTranslation(false)
        .withReplacement(true)
        .withTranslation(chineseLyrics: '另一段中文');
    expect(transformed.provenance, SuggestionProvenance.verifiedRecording);
    expect(
      FieldSuggestion.fromJson(candidate.toJson()).provenance,
      SuggestionProvenance.verifiedRecording,
    );
    final legacy = candidate.toJson()..remove('provenance');
    expect(
      FieldSuggestion.fromJson(legacy).provenance,
      SuggestionProvenance.unverified,
    );
    final future = {...candidate.toJson(), 'provenance': 'unknownFutureTrust'};
    expect(
      FieldSuggestion.fromJson(future).provenance,
      SuggestionProvenance.unverified,
    );
    expect(candidate.permits(FieldSuggestion.fromJson(legacy)), isFalse);
  });

  test(
    'failed artwork extraction is unknown, never a safe missing-art fill',
    () {
      final track = AudioTrack.fromJson({
        ...fixtureTrack().toJson(),
        'artworkError': 'Embedded artwork could not be decoded',
        'artworkPath': null,
        'artworkSha256': null,
      });
      final result = RecommendedChanges.evaluate(
        track,
        task([
          suggestion(AudioField.artwork, 'https://example.test/cover.jpg'),
        ]),
      );
      expect(result.suggestions, isEmpty);
      expect(
        result.held[AudioField.artwork],
        RecommendationHoldReason.existingValue,
      );
    },
  );

  test('match description and source name cannot grant trust', () {
    const prose = FieldSuggestion(
      field: AudioField.album,
      value: 'Album',
      source: 'MusicBrainz',
      matchDescription: '已核对同一录音，100%匹配',
    );
    expect(
      RecommendedChanges.evaluate(fixtureTrack(), task([prose])).suggestions,
      isEmpty,
    );
  });
}
