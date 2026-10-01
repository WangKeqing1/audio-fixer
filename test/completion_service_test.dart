import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Source implements MetadataSource {
  Set<AudioField>? requested;
  @override
  String get name => 'Test source';
  @override
  Set<AudioField> get supportedFields => AudioField.values.toSet();
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    requested = requestedFields;
    return const [
      FieldSuggestion(
        field: AudioField.title,
        value: 'Must not replace existing title',
        source: 'Test source',
      ),
      FieldSuggestion(
        field: AudioField.lyrics,
        value: 'Test lyrics',
        source: 'Test source',
      ),
      FieldSuggestion(
        field: AudioField.artwork,
        value: ' ',
        source: 'Test source',
      ),
      FieldSuggestion(
        field: AudioField.album,
        value: 'Unattributed album',
        source: '',
      ),
    ];
  }
}

class _FailingSource implements MetadataSource {
  @override
  String get name => 'Unavailable source';
  @override
  Set<AudioField> get supportedFields => AudioField.values.toSet();
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    throw Exception('offline');
  }
}

class _LyricsOnlySource implements MetadataSource {
  _LyricsOnlySource({this.withResult = true});
  final bool withResult;
  bool called = false;
  @override
  String get name => 'Lyrics only';
  @override
  Set<AudioField> get supportedFields => const {AudioField.lyrics};
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    called = true;
    expect(requestedFields, {AudioField.lyrics});
    return withResult
        ? const [
            FieldSuggestion(
              field: AudioField.lyrics,
              value: 'Available lyrics',
              source: 'Lyrics only',
            ),
          ]
        : const [];
  }
}

void main() {
  test(
    'queries supported fields even when another source is missing',
    () async {
      final source = _LyricsOnlySource();
      final result = await CompletionService(sources: [source])
          .preview(fixtureTrack(), const AppSettings());
      expect(source.called, isTrue);
      expect(result.status, TaskStatus.needsReview);
      expect(result.suggestions.single.field, AudioField.lyrics);
      expect(result.message, contains('专辑、封面的数据源尚未接入'));
    },
  );

  test('partial source no-match still explains unavailable fields', () async {
    final source = _LyricsOnlySource(withResult: false);
    final result = await CompletionService(sources: [source])
        .preview(fixtureTrack(), const AppSettings());
    expect(source.called, isTrue);
    expect(result.status, TaskStatus.noMatch);
    expect(result.message, contains('数据源尚未接入'));
  });

  test(
    'unconfigured sources produce a blocked task without changing metadata',
    () async {
      final track = fixtureTrack();
      final result = await CompletionService().preview(
        track,
        const AppSettings(),
      );
      expect(result.status, TaskStatus.waitingForSource);
      expect(result.suggestions, isEmpty);
      expect(track.title, '测试歌曲');
      expect(track.lyrics, isNull);
    },
  );

  test(
    'only missing enabled fields are queried and usable candidates retained',
    () async {
      final source = _Source();
      final track = fixtureTrack();
      final result = await CompletionService(sources: [source])
          .preview(track, const AppSettings(artwork: false));
      expect(source.requested, {AudioField.album, AudioField.lyrics});
      expect(result.status, TaskStatus.needsReview);
      expect(result.suggestions.single.field, AudioField.lyrics);
      expect(track.lyrics, isNull, reason: 'A preview must not write tags.');
    },
  );

  test('disabled fields do not create misleading blocked tasks', () async {
    final result = await CompletionService().preview(
      fixtureTrack(),
      const AppSettings(metadata: false, lyrics: false, artwork: false),
    );
    expect(result.status, TaskStatus.skipped);
  });

  test('failed reads are unknown rather than missing', () async {
    final track = fixtureTrack(readError: 'invalid tag');
    expect(track.missingFields, isEmpty);
    expect(track.needsCompletion, isFalse);
    final result = await CompletionService().preview(
      track,
      const AppSettings(),
    );
    expect(result.status, TaskStatus.failed);
  });

  test('one failing source does not discard other usable candidates', () async {
    final result = await CompletionService(
      sources: [_FailingSource(), _Source()],
    ).preview(fixtureTrack(), const AppSettings());
    expect(result.status, TaskStatus.needsReview);
    expect(result.suggestions.single.field, AudioField.lyrics);
    expect(result.message, contains('Unavailable source'));
  });

  test(
    'all sources failing remains a failure, not a no-match result',
    () async {
      final result = await CompletionService(sources: [_FailingSource()])
          .preview(fixtureTrack(), const AppSettings());
      expect(result.status, TaskStatus.failed);
      expect(result.suggestions, isEmpty);
    },
  );
}
