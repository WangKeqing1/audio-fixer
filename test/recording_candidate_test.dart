import 'package:audio_fixer/core/models/recording_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

const candidate = RecordingCandidate(
  sourceName: 'Provider',
  sourceId: 'provider:123',
  sourceUrl: 'https://example.com/song/123',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  durationMs: 218800,
  matchDescription: 'Choose this recording',
);

void main() {
  test(
    'candidate roundtrip preserves full provenance with immutable fields',
    () {
      final restored = RecordingCandidate.fromJson(candidate.toJson());
      expect(restored.sameAs(candidate), isTrue);
      for (final change in [
        {'title': 'Other title'},
        {'artist': 'Other artist'},
        {'album': ''},
        {'durationMs': 218801},
        {'matchDescription': 'Altered explanation'},
      ]) {
        final altered = RecordingCandidate.fromJson({
          ...candidate.toJson(),
          ...change,
        });
        expect(altered.sameIdentity(candidate), isTrue);
        expect(altered.sameAs(candidate), isFalse);
      }
      for (final change in [
        {'sourceId': 'provider:124'},
        {'sourceName': 'Other provider'},
        {'sourceUrl': 'https://example.com/song/124'},
      ]) {
        final altered = RecordingCandidate.fromJson({
          ...candidate.toJson(),
          ...change,
        });
        expect(altered.sameIdentity(candidate), isFalse);
      }
    },
  );

  test(
    'stored candidates reject malformed types, unsafe URLs and oversized data',
    () {
      for (final change in [
        {'title': ''},
        {'title': ' '},
        {'artist': null},
        {'album': 1},
        {'title': 'Song\x00'},
        {'title': List.filled(4097, 'a').join()},
        {'durationMs': 0},
        {'durationMs': -1},
        {'durationMs': 1.1},
        {'durationMs': '218800'},
        {'durationMs': 86400001},
        {'sourceId': '123'},
        {'sourceId': 'provider:123?redirect=true'},
        {'sourceUrl': 'http://example.com/song/123'},
        {'sourceUrl': 'https://user:pass@example.com/song/123'},
        {'sourceUrl': 'https://example.com:8443/song/123'},
        {'sourceUrl': 'https://example.com/song/123#fragment'},
        {'unknown': true},
      ]) {
        expect(
          () => RecordingCandidate.fromJson({...candidate.toJson(), ...change}),
          throwsFormatException,
          reason: change.toString(),
        );
      }
      final missing = candidate.toJson()..remove('matchDescription');
      expect(() => RecordingCandidate.fromJson(missing), throwsFormatException);
    },
  );

  test('discovery results cannot be mutated through their source lists', () {
    final candidates = [candidate];
    final diagnostics = ['Needs choice'];
    final result = DiscoveryResult(
      candidates: candidates,
      diagnostics: diagnostics,
    );
    candidates.clear();
    diagnostics.clear();
    expect(result.candidates, hasLength(1));
    expect(result.diagnostics, ['Needs choice']);
    expect(() => result.candidates.clear(), throwsUnsupportedError);
  });
}
