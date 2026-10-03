import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/recording_candidate.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _recording = RecordingCandidate(
  sourceName: 'Selected provider',
  sourceId: 'selected:1',
  sourceUrl: 'https://example.com/song/1',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  durationMs: 180000,
  matchDescription: 'User must choose',
);
final _track = AudioTrack(
  id: '1',
  fileName: 'Song.mp3',
  sizeBytes: 1,
  importedAt: DateTime(2026),
  durationMs: 180000,
);

class _Source implements RecordingDiscoverySource {
  _Source({
    this.name = 'Selected provider',
    this.error,
    this.results = const [],
    this.discovered = const [_recording],
  });
  @override
  final String name;
  final Object? error;
  final List<FieldSuggestion> results;
  final List<RecordingCandidate> discovered;
  int ordinaryCalls = 0;
  int discoveryCalls = 0;
  int confirmedCalls = 0;
  Set<AudioField>? fields;
  @override
  Set<AudioField> get supportedFields => {AudioField.title, AudioField.lyrics};
  @override
  Future<DiscoveryResult> discover(AudioTrack track) async {
    discoveryCalls++;
    if (error != null) throw error!;
    return DiscoveryResult(
      candidates: discovered,
      diagnostics: ['2 hits need selection'],
    );
  }

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    ordinaryCalls++;
    return results;
  }

  @override
  Future<List<FieldSuggestion>> lookupConfirmed(
    AudioTrack track,
    RecordingCandidate candidate,
    Set<AudioField> requestedFields,
  ) async {
    confirmedCalls++;
    fields = requestedFields;
    expect(candidate.sameAs(_recording), isTrue);
    if (error != null) throw error!;
    return results;
  }
}

class _Ordinary implements MetadataSource {
  int calls = 0;
  @override
  String get name => 'Needs artist';
  @override
  Set<AudioField> get supportedFields => AudioField.values.toSet();
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    calls++;
    return [];
  }
}

void main() {
  test(
    'foreign provider discovery candidates cannot be surfaced for approval',
    () async {
      final result = await CompletionService(
        sources: [
          _Source(name: 'Different provider', discovered: const [_recording]),
        ],
      ).discoverRecordings(_track);
      expect(result.candidates, isEmpty);
      expect(result.hasFailures, isTrue);
      expect(result.diagnostics.join(), contains('来源或格式无效'));
    },
  );
  test(
    'discovery invokes only supported sources and explains intentional skips',
    () async {
      final discovery = _Source();
      final ordinary = _Ordinary();
      final result = await CompletionService(sources: [discovery, ordinary])
          .discoverRecordings(_track);
      expect(result.candidates.single.sameAs(_recording), isTrue);
      expect(result.diagnostics.join(), contains('需要先确认歌手及录音版本'));
      expect(result.hasFailures, isFalse);
      expect(discovery.discoveryCalls, 1);
      expect(
        discovery.confirmedCalls + discovery.ordinaryCalls + ordinary.calls,
        0,
      );
    },
  );

  test(
    'per-source failure remains visible while independent choices survive',
    () async {
      final service = CompletionService(
        sources: [
          _Source(
            name: 'Failed',
            error: const ApiException('限流', statusCode: 429),
          ),
          _Source(name: 'No match', error: const SourceNoMatch('歌名不同')),
          _Source(),
        ],
      );
      final result = await service.discoverRecordings(_track);
      expect(result.candidates, hasLength(1));
      expect(result.hasFailures, isTrue);
      expect(result.diagnostics.join(), contains('Failed：限流'));
      expect(result.diagnostics.join(), contains('No match：歌名不同'));
      final noMatch = await CompletionService(
        sources: [_Source(error: const SourceNoMatch('歌名不同'))],
      ).discoverRecordings(_track);
      expect(noMatch.hasFailures, isFalse);
    },
  );

  test('confirmed preview routes solely chosen provider and enforces field provenance', () async {
    final chosen = _Source(
      results: const [
        FieldSuggestion(
          field: AudioField.title,
          value: 'Song',
          source: 'Selected provider',
          sourceUrl: 'https://example.com/song/1',
        ),
        FieldSuggestion(
          field: AudioField.lyrics,
          value: 'Wrong identity lyric',
          source: 'Selected provider',
          sourceUrl: 'https://example.com/song/2',
        ),
        FieldSuggestion(
          field: AudioField.artist,
          value: 'Outside scope',
          source: 'Selected provider',
          sourceUrl: 'https://example.com/song/1',
        ),
      ],
    );
    final other = _Ordinary();
    final result = await CompletionService(sources: [other, chosen]).preview(
      _track,
      const AppSettings(),
      confirmedRecording: _recording,
      requestedFields: {AudioField.title, AudioField.lyrics, AudioField.genre},
    );
    expect(result.status, TaskStatus.needsReview);
    expect(result.suggestions.single.field, AudioField.title);
    expect(chosen.fields, {AudioField.title, AudioField.lyrics});
    expect(chosen.confirmedCalls, 1);
    expect(chosen.ordinaryCalls + chosen.discoveryCalls + other.calls, 0);
    expect(result.message, contains('所选版本的来源不提供流派，保留原资料'));
    expect(result.message, isNot(contains('数据源尚未接入')));
  });

  test(
    'partial failure cannot inject suggestions from another recording',
    () async {
      final source = _Source(
        error: const PartialSourceException([
          FieldSuggestion(
            field: AudioField.title,
            value: 'Song',
            source: 'Selected provider',
            sourceUrl: 'https://example.com/song/1',
          ),
          FieldSuggestion(
            field: AudioField.lyrics,
            value: 'Wrong lyric',
            source: 'Selected provider',
            sourceUrl: 'https://example.com/song/2',
          ),
        ], '歌词失败'),
      );
      final result = await CompletionService(sources: [source]).preview(
        _track,
        const AppSettings(),
        confirmedRecording: _recording,
        requestedFields: {AudioField.title, AudioField.lyrics},
      );
      expect(result.suggestions.single.field, AudioField.title);
      expect(result.message, contains('歌词失败'));
    },
  );

  test('chosen source failure or missing provider does not fall back to another source', () async {
    for (final selected in [
      <MetadataSource>[],
      [_Source(error: const ApiException('offline'))],
      [_Source(), _Source()],
    ]) {
      final other = _Ordinary();
      final result = await CompletionService(sources: [...selected, other])
          .preview(
            _track,
            const AppSettings(),
            confirmedRecording: _recording,
            requestedFields: {AudioField.lyrics},
          );
      expect(result.status, TaskStatus.failed);
      expect(result.suggestions, isEmpty);
      expect(other.calls, 0);
    }
  });
}
