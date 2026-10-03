import 'dart:async';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/recording_candidate.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

RecordingCandidate _candidate(String id) => RecordingCandidate(
  sourceName: 'Offline discovery',
  sourceId: 'fixture:$id',
  sourceUrl: 'https://example.com/recording/$id',
  title: 'Candidate Song',
  artist: 'Candidate Artist',
  album: 'Edition $id',
  durationMs: 218800,
  matchDescription: 'Title and duration match; artist needs confirmation',
);

class _Source implements RecordingDiscoverySource {
  int discoveries = 0;
  int normalLookups = 0;
  final confirmedIds = <String>[];
  final requested = <Set<AudioField>>[];
  Completer<void>? hold;
  bool fail = false;
  bool noResults = false;
  bool discoveryFails = false;
  @override
  String get name => 'Offline discovery';
  @override
  Set<AudioField> get supportedFields => AudioField.coreFields;
  @override
  Future<DiscoveryResult> discover(AudioTrack track) async {
    discoveries++;
    if (discoveryFails) {
      throw const ApiException('Offline test network failure');
    }
    return DiscoveryResult(
      candidates: noResults ? [] : [_candidate('1'), _candidate('2')],
      diagnostics: ['Offline discovery: two title matches'],
    );
  }

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async {
    normalLookups++;
    return [];
  }

  @override
  Future<List<FieldSuggestion>> lookupConfirmed(
    AudioTrack track,
    RecordingCandidate candidate,
    Set<AudioField> fields,
  ) async {
    confirmedIds.add(candidate.sourceId);
    requested.add(fields);
    await hold?.future;
    if (fail) {
      throw const ApiException(
        'Selected recording endpoint temporarily failed',
      );
    }
    final values = {
      AudioField.title: candidate.title,
      AudioField.artist: candidate.artist,
      AudioField.album: candidate.album,
      AudioField.lyrics: 'Authored fixture lyrics',
      AudioField.artwork: 'https://example.com/cover/${candidate.sourceId}',
    };
    return [
      for (final field in fields)
        FieldSuggestion(
          field: field,
          value: values[field]!,
          source: name,
          sourceUrl: candidate.sourceUrl,
        ),
    ];
  }
}

AudioTrack _track({
  String id = 'song',
  String? artist,
  bool instrumental = false,
}) => AudioTrack(
  id: id,
  fileName: 'Candidate Song.mp3',
  localPath: '/fixture/$id.mp3',
  sizeBytes: 100,
  importedAt: DateTime(2026),
  durationMs: 218828,
  artist: artist,
  isInstrumental: instrumental,
);
LibraryController _controller(
  _Source source, {
  List<AudioTrack>? tracks,
  MemoryStore? store,
}) => LibraryController(
  store: store ?? MemoryStore(LibrarySnapshot(tracks: tracks ?? [_track()])),
  picker: FakePicker(),
  importer: FakeImporter(),
  completion: CompletionService(sources: [source]),
);

void main() {
  for (final status in [TaskStatus.outdated, TaskStatus.savedOriginal]) {
    test(
      'explicit retry discards $status recording choice and discovers afresh',
      () async {
        final source = _Source();
        final controller = _controller(source);
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.queryAutomaticRepair(track: controller.tracks.single);
        final discovered = controller.tasks.single;
        final reviewed = (await controller.confirmRecordingChoice(
          discovered,
          discovered.recordingCandidates.first,
        ))!;
        final stale = CompletionTask.fromJson({
          ...reviewed.toJson(),
          'status': status.name,
        });
        final store = controller.store as MemoryStore;
        store.snapshot = LibrarySnapshot(
          tracks: controller.tracks,
          tasks: [stale],
        );
        await controller.initialize();
        await controller.retryTaskQuery(controller.tasks.single);
        expect(source.discoveries, 2);
        expect(source.confirmedIds, ['fixture:1']);
        expect(controller.tasks.single.confirmedRecording, isNull);
        expect(controller.tasks.single.needsRecordingChoice, isTrue);
        expect(controller.tasks.single.approvedSuggestions, isEmpty);
      },
    );
  }
  test('title-only automatic query persists review-only versions without field approvals', () async {
    final source = _Source();
    final controller = _controller(source);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.queryAutomaticRepair(track: controller.tracks.single);
    final task = controller.tasks.single;
    expect(source.discoveries, 1);
    expect(source.normalLookups, 0);
    expect(source.confirmedIds, isEmpty);
    expect(task.needsRecordingChoice, isTrue);
    expect(task.recordingCandidates, hasLength(2));
    expect(task.suggestions, isEmpty);
    expect(task.approvedSuggestions, isEmpty);
    expect(controller.tracks.single.artist, isNull);
    expect(controller.pendingCompletionCount, 0);
    final restored = LibrarySnapshot.fromJson(
      (controller.store as MemoryStore).snapshot.toJson(),
    );
    expect(
      restored.tasks.single.recordingCandidates.last.sameAs(_candidate('2')),
      isTrue,
    );
    expect(restored.tasks.single.confirmedRecording, isNull);
  });

  test('explicit edition choice pins all fields and retry to one recording without writing', () async {
    final source = _Source();
    final controller = _controller(source);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.queryAutomaticRepair(track: controller.tracks.single);
    final discovery = controller.tasks.single;
    final review = (await controller.confirmRecordingChoice(
      discovery,
      discovery.recordingCandidates.last,
    ))!;
    expect(source.confirmedIds, ['fixture:2']);
    expect(review.confirmedRecording!.sameAs(_candidate('2')), isTrue);
    expect(
      review.suggestions.every(
        (field) => field.sourceUrl == _candidate('2').sourceUrl,
      ),
      isTrue,
    );
    expect(review.approvedSuggestions, isEmpty);
    expect(controller.tracks.single.album, isNull);
    expect(
      CompletionTask.fromJson(review.toJson()).confirmedRecording!
          .sameAs(_candidate('2')),
      isTrue,
    );
    await controller.approveCandidates(review, [review.suggestions.first]);
    expect(controller.tasks.single.confirmedRecording!.sourceId, 'fixture:2');
    await controller.revokeCandidateApproval(controller.tasks.single);
    await controller.retryTaskQuery(controller.tasks.single);
    expect(source.confirmedIds, ['fixture:2', 'fixture:2']);
    expect(source.discoveries, 1);
    expect(controller.tasks.single.approvedSuggestions, isEmpty);
  });

  test(
    'forged, stale, and excluded version choices cannot initiate detail reads',
    () async {
      final source = _Source();
      final controller = _controller(source);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.queryAutomaticRepair(track: controller.tracks.single);
      final old = controller.tasks.single;
      final forged = RecordingCandidate.fromJson({
        ...old.recordingCandidates.first.toJson(),
        'album': 'Altered album',
      });
      expect(await controller.confirmRecordingChoice(old, forged), isNull);
      expect(source.confirmedIds, isEmpty);
      await controller.queryAutomaticRepair(track: controller.tracks.single);
      expect(
        await controller.confirmRecordingChoice(
          old,
          old.recordingCandidates.first,
        ),
        isNull,
      );
      expect(source.confirmedIds, isEmpty);
      final store = controller.store as MemoryStore;
      store.snapshot = LibrarySnapshot(
        tracks: [
          _track().withDetails(
            title: null,
            artist: null,
            album: null,
            year: null,
            durationMs: 30000,
            lyrics: null,
            artworkPath: null,
          ),
        ],
        tasks: controller.tasks,
        settings: const AppSettings(excludeShortAudio: true),
      );
      await controller.initialize();
      expect(
        await controller.confirmRecordingChoice(
          controller.tasks.single,
          controller.tasks.single.recordingCandidates.first,
        ),
        isNull,
      );
      expect(source.confirmedIds, isEmpty);
    },
  );

  test('double choice while details pending is ignored and failed retry preserves ID', () async {
    final source = _Source()
      ..hold = Completer<void>()
      ..fail = true;
    final controller = _controller(source);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.queryAutomaticRepair(track: controller.tracks.single);
    final task = controller.tasks.single;
    final choosing = controller.confirmRecordingChoice(
      task,
      task.recordingCandidates.first,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.canOperate, isFalse);
    expect(
      await controller.confirmRecordingChoice(
        task,
        task.recordingCandidates.last,
      ),
      isNull,
    );
    source.hold!.complete();
    await choosing;
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(controller.tasks.single.confirmedRecording!.sourceId, 'fixture:1');
    source.fail = false;
    await controller.retryFailedBatch();
    expect(source.confirmedIds, ['fixture:1', 'fixture:1']);
    expect(controller.tasks.single.status, TaskStatus.needsReview);
    expect(controller.tasks.single.approvedSuggestions, isEmpty);
  });

  test('batch discoveries never pick an edition and instrumental choice still suppresses lyrics', () async {
    final source = _Source();
    final controller = _controller(
      source,
      tracks: [
        _track(id: 'a'),
        _track(id: 'b', instrumental: true),
      ],
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.queryAutomaticRepair(trackIds: {'a', 'b'});
    expect(source.discoveries, 2);
    expect(source.confirmedIds, isEmpty);
    expect(controller.tasks.every((task) => task.needsRecordingChoice), isTrue);
    final instrumental = controller.taskForTrack('b')!;
    await controller.confirmRecordingChoice(
      instrumental,
      instrumental.recordingCandidates.first,
    );
    expect(source.requested.single, isNot(contains(AudioField.lyrics)));
    expect(controller.trackById('b')!.isInstrumental, isTrue);
  });

  test(
    'source failure and successful discovery no-match retain distinct statuses',
    () async {
      final source = _Source()..noResults = true;
      final controller = _controller(source);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.queryAutomaticRepair(track: controller.tracks.single);
      expect(controller.tasks.single.status, TaskStatus.noMatch);
      source.discoveryFails = true;
      await controller.queryAutomaticRepair(track: controller.tracks.single);
      expect(controller.tasks.single.status, TaskStatus.failed);
      expect(
        controller.tasks.single.message,
        contains('Offline test network failure'),
      );
    },
  );
}
