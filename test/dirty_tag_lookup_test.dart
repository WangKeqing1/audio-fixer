import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/recording_candidate.dart';
import 'package:audio_fixer/core/models/source_query_report.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:audio_fixer/core/services/sources/track_search.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

AudioTrack _track({String? artist, String? title, String? album}) => AudioTrack(
  id: 'bracket-artist',
  fileName: '(02) [Al Jarreau] Great Circle Song.flac',
  sizeBytes: 100,
  importedAt: DateTime(2026),
  title: title,
  artist: artist,
  album: album,
  durationMs: 220000,
);

class _Source implements RecordingDiscoverySource {
  final lookups = <TrackSearch>[];
  final discoveries = <TrackSearch>[];
  bool unavailable = false;
  bool primaryMatch = false;
  @override
  String get name => 'Offline search fixture';
  @override
  Set<AudioField> get supportedFields => {AudioField.album};
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async {
    lookups.add(TrackSearch.fromTrack(track));
    if (unavailable) {
      throw const ApiException('Fixture unavailable', statusCode: 503);
    }
    return primaryMatch
        ? [
            FieldSuggestion(
              field: AudioField.album,
              value: 'Existing identity album',
              source: name,
            ),
          ]
        : [];
  }

  @override
  Future<DiscoveryResult> discover(AudioTrack track) async {
    final search = TrackSearch.fromTrack(track);
    discoveries.add(search);
    return DiscoveryResult(
      candidates: search.artist != 'Al Jarreau'
          ? []
          : [
              RecordingCandidate(
                sourceName: name,
                sourceId: 'fixture:jarreau',
                sourceUrl: 'https://example.com/recordings/jarreau',
                title: 'Great Circle Song',
                artist: 'Al Jarreau',
                album: 'Fixture album',
                durationMs: 220000,
                matchDescription:
                    'Search title, artist and duration agree; review required',
              ),
            ],
    );
  }

  @override
  Future<List<FieldSuggestion>> lookupConfirmed(
    AudioTrack track,
    RecordingCandidate candidate,
    Set<AudioField> fields,
  ) async => [
    FieldSuggestion(
      field: AudioField.album,
      value: candidate.album,
      source: name,
      sourceUrl: candidate.sourceUrl,
    ),
  ];
}

void main() {
  test(
    'numbered bracket artist filename is explicitly an unconfirmed hint',
    () {
      final track = _track();
      final original = track.toJson();
      final search = TrackSearch.fromTrack(track);
      expect(search.title, 'Great Circle Song');
      expect(search.artist, 'Al Jarreau');
      expect(search.artistIsInferred, isTrue);
      expect(search.normalizationNotes.join(), contains('推测'));
      expect(search.matchesDuration(226), isFalse);
      expect(track.toJson(), original);
    },
  );

  test('website pollution is removed only from queries and clean tags win', () {
    final track = _track(
      title: 'Great Circle Song [wusunk.com]',
      artist: 'Al Jarreau [www.wusunk.com]',
      album: 'Album [wusunk.com]',
    );
    final original = track.toJson();
    final search = TrackSearch.fromTrack(track);
    expect(search.title, 'Great Circle Song');
    expect(search.artist, 'Al Jarreau');
    expect(search.album, 'Album');
    expect(search.artistIsInferred, isFalse);
    expect(track.toJson(), original);
    final clean = _track(title: 'Legitimate Song', artist: 'Legitimate Artist');
    expect(TrackSearch.fromTrack(clean).title, 'Legitimate Song');
    expect(TrackSearch.fromTrack(clean).artist, 'Legitimate Artist');
    final alternative = TrackSearch.filenameFallback(clean)!;
    expect(alternative.artist, 'Al Jarreau');
    expect(alternative.normalizationNotes.join(), contains('尚未确认'));
    expect(alternative.album, isNull);
  });

  test('bracket versions, sources and ambiguous credits are never guessed as artists', () {
    for (final fileName in [
      '(02) [Live] Song.flac',
      '(02) [wusunk.com] Song.flac',
      '(02) [Artist] Guest - Song.flac',
      '[Artist] Song.flac',
    ]) {
      final track = AudioTrack.fromJson({
        ..._track().toJson(),
        'fileName': fileName,
      });
      final query = TrackSearch.fromTrack(track);
      if (fileName != '(02) [Artist] Guest - Song.flac') {
        expect(query.artistIsInferred, isFalse, reason: fileName);
      } else {
        expect(query.artist, '[Artist] Guest');
      }
    }
  });

  test(
    'one-click recovers conflicting dirty artist via bounded version choice',
    () async {
      final track = _track(
        title: 'Great Circle Song',
        artist: 'Unrelated Artist [wusunk.com]',
      );
      final source = _Source();
      final controller = LibraryController(
        store: MemoryStore(LibrarySnapshot(tracks: [track])),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: [source]),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.queryAutomaticRepair(track: controller.tracks.single);
      expect(source.lookups.single.artist, 'Unrelated Artist');
      expect(source.discoveries.map((q) => q.artist), [
        'Unrelated Artist',
        'Al Jarreau',
      ]);
      final task = controller.tasks.single;
      expect(task.needsRecordingChoice, isTrue);
      expect(task.message, contains('按文件名推测'));
      expect(task.message, contains('不是已确认'));
      expect(task.suggestions, isEmpty);
      expect(task.approvedSuggestions, isEmpty);
      expect(controller.tracks.single.toJson(), track.toJson());
      final reviewed = await controller.confirmRecordingChoice(
        task,
        task.recordingCandidates.single,
      );
      expect(reviewed!.suggestions.single.value, 'Fixture album');
      expect(reviewed.approvedSuggestions, isEmpty);
      expect(controller.tracks.single.artist, track.artist);
    },
  );

  test('missing title plus a polluted conflicting artist also recovers from the file', () async {
    final source = _Source();
    final track = _track(artist: 'Unrelated [wusunk.com]');
    final controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [track])),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(sources: [source]),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.queryAutomaticRepair(track: controller.tracks.single);
    expect(source.discoveries.last.title, 'Great Circle Song');
    expect(source.discoveries.last.artist, 'Al Jarreau');
    expect(controller.tasks.single.needsRecordingChoice, isTrue);
    expect(controller.tracks.single.title, isNull);
    expect(controller.tracks.single.artist, track.artist);
  });

  test(
    'manual search overrides are not replaced by a filename guess',
    () async {
      final source = _Source();
      final track = _track(artist: 'Unrelated [wusunk.com]');
      final controller = LibraryController(
        store: MemoryStore(LibrarySnapshot(tracks: [track])),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: [source]),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.queryRepair(
        track.id,
        fields: {AudioField.album},
        searchTitle: 'Manual title',
        searchArtist: 'Manual artist',
      );
      expect(source.discoveries.single.title, 'Manual title');
      expect(source.discoveries.single.artist, 'Manual artist');
      expect(controller.tasks.single.needsRecordingChoice, isFalse);
    },
  );

  test('filename-derived artist requires a version choice even without conflicting tags', () async {
    final source = _Source();
    final track = _track();
    final controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [track])),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(sources: [source]),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.queryAutomaticRepair(track: controller.tracks.single);
    expect(source.lookups, isEmpty);
    expect(source.discoveries.single.artist, 'Al Jarreau');
    expect(controller.tasks.single.needsRecordingChoice, isTrue);
    expect(controller.tasks.single.suggestions, isEmpty);
    expect(controller.tasks.single.message, contains('文件名推测'));
    expect(controller.tracks.single.toJson(), track.toJson());
  });

  test(
    'service failure is not reclassified as no-match or retried with filename',
    () async {
      final source = _Source()..unavailable = true;
      final controller = LibraryController(
        store: MemoryStore(
          LibrarySnapshot(tracks: [_track(artist: 'Wrong [wusunk.com]')]),
        ),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: [source]),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.queryAutomaticRepair(track: controller.tracks.single);
      expect(source.lookups, hasLength(1));
      expect(source.discoveries, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.failed);
      expect(
        controller.tasks.single.sourceReports.single.outcome,
        SourceQueryOutcome.failed,
      );
    },
  );

  test(
    'usable primary match never triggers filename identity replacement',
    () async {
      final source = _Source()..primaryMatch = true;
      final controller = LibraryController(
        store: MemoryStore(
          LibrarySnapshot(
            tracks: [_track(title: 'Clean Song', artist: 'Clean Artist')],
          ),
        ),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: [source]),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.queryAutomaticRepair(track: controller.tracks.single);
      expect(source.lookups.single.artist, 'Clean Artist');
      expect(source.discoveries, isEmpty);
      expect(controller.tasks.single.recordingCandidates, isEmpty);
    },
  );
}
