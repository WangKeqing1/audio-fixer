import 'dart:async';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Source implements MetadataSource {
  AudioTrack? query;
  Set<AudioField>? fields;
  bool fail = false;
  bool partial = false;
  List<FieldSuggestion> candidates = const [];
  @override
  String get name => 'Offline fixture';
  @override
  Set<AudioField> get supportedFields => AudioField.values.toSet();
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    query = track;
    fields = requestedFields;
    if (fail) throw StateError('offline failure');
    if (partial) throw PartialSourceException(candidates, '封面暂不可用');
    return candidates;
  }
}

class _Writer implements AudioCopyExporter, AudioOriginalSaver {
  final saved = <List<FieldSuggestion>>[];
  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => null;
  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    saved.add(List.of(selected));
    return 'content://fixture/saved';
  }
}

void main() {
  late AudioTrack track;
  late MemoryStore store;
  late _Source source;
  late _Writer writer;
  late LibraryController controller;
  setUp(() async {
    track = AudioTrack.fromJson({
      ...fixtureTrack().toJson(),
      'album': '原专辑',
      'lyrics': '原歌词',
      'artworkPath': '/fixture/existing.cover',
      'year': 1999,
      'trackNumber': 2,
      'trackTotal': 10,
    });
    store = MemoryStore(LibrarySnapshot(tracks: [track]));
    source = _Source();
    writer = _Writer();
    controller = LibraryController(
      store: store,
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(sources: [source]),
      exporter: writer,
    );
    await controller.initialize();
  });
  tearDown(() => controller.dispose());

  test(
    'manual nonempty changed fields become unapproved replacement drafts only',
    () async {
      final task = await controller.createManualRepair(track.id, {
        AudioField.title: '修正歌名',
        AudioField.album: track.album!,
        AudioField.year: '02000',
        AudioField.composer: '作曲者',
        AudioField.comment: '',
      });
      expect(task, isNotNull);
      expect(task!.isRepair, isTrue);
      expect(task.queriedFields, {
        AudioField.title,
        AudioField.year,
        AudioField.composer,
      });
      expect(task.approvedSuggestions, isEmpty);
      expect(
        task.suggestions
            .where((v) => v.replaceExisting)
            .map((v) => v.field)
            .toSet(),
        {AudioField.title, AudioField.year},
      );
      expect(
        task.suggestions.singleWhere((v) => v.field == AudioField.year).value,
        '2000',
      );
      expect(writer.saved, isEmpty);
      expect(controller.trackById(track.id)!.title, track.title);
      expect(controller.trackById(track.id)!.lyrics, '原歌词');
      expect(source.query, isNull);
    },
  );
  test('invalid paired counters never create or replace a review', () async {
    expect(
      await controller.createManualRepair(track.id, {
        AudioField.trackNumber: '12',
      }),
      isNull,
    );
    expect(controller.tasks, isEmpty);
    expect(controller.notice, contains('不能大于'));
  });
  test('failed draft persistence returns null and retains old task', () async {
    final before = await controller.createManualRepair(track.id, {
      AudioField.title: '修正歌名',
    });
    store.failSave = true;
    expect(
      await controller.createManualRepair(track.id, {AudioField.artist: '新歌手'}),
      isNull,
    );
    expect(controller.taskForTrack(track.id)!.createdAt, before!.createdAt);
  });
  test('explicit repair ignores missing-only settings and preserves corrected query clues', () async {
    await controller.updateSettings(
      const AppSettings(metadata: false, lyrics: false, artwork: false),
    );
    source.candidates = const [
      FieldSuggestion(
        field: AudioField.title,
        value: '修正歌名',
        source: 'Offline fixture',
      ),
    ];
    await controller.queryRepair(
      track.id,
      fields: {AudioField.title},
      searchTitle: '修正歌名',
      searchArtist: '修正歌手',
    );
    final task = controller.taskForTrack(track.id)!;
    expect(source.query!.title, '修正歌名');
    expect(source.query!.artist, '修正歌手');
    expect(source.fields, {AudioField.title});
    expect(controller.trackById(track.id)!.title, track.title);
    expect(task.suggestions.single.replaceExisting, isTrue);
    final restored = LibrarySnapshot.fromJson(store.snapshot.toJson())
        .tasks
        .single;
    expect(restored.isRepair, isTrue);
    expect(restored.searchMetadata, {'title': '修正歌名', 'artist': '修正歌手'});
    expect(restored.suggestions.single.replaceExisting, isTrue);
  });
  test(
    'identical repair results are skipped and do not claim candidates found',
    () async {
      source.candidates = [
        FieldSuggestion(
          field: AudioField.title,
          value: track.title!,
          source: source.name,
        ),
      ];
      await controller.queryRepair(track.id, fields: {AudioField.title});
      final task = controller.taskForTrack(track.id)!;
      expect(task.suggestions, isEmpty);
      expect(task.status, TaskStatus.skipped);
      expect(task.message, contains('无需替换'));
      expect(task.message, isNot(contains('已找到候选')));
    },
  );
  test(
    'partial results keep verified fields and visible source warning',
    () async {
      source.partial = true;
      source.candidates = const [
        FieldSuggestion(
          field: AudioField.title,
          value: '修正歌名',
          source: 'Offline fixture',
          replaceExisting: true,
        ),
        FieldSuggestion(
          field: AudioField.album,
          value: '越界字段',
          source: 'Offline fixture',
        ),
      ];
      await controller.queryRepair(
        track.id,
        fields: {AudioField.title, AudioField.artwork},
      );
      final task = controller.taskForTrack(track.id)!;
      expect(task.suggestions, hasLength(1));
      expect(task.message, contains('封面暂不可用'));
      expect(task.suggestions.single.replaceExisting, isTrue);
    },
  );
  test('changed replacement intent cannot be approved and batch saves only approved fields', () async {
    final task = (await controller.createManualRepair(track.id, {
      AudioField.title: '修正歌名',
      AudioField.composer: '作曲者',
    }))!;
    final chosen = task.suggestions.first;
    expect(
      await controller.approveCandidates(task, [chosen.withReplacement(false)]),
      isFalse,
    );
    expect(await controller.approveCandidates(task, [chosen]), isTrue);
    controller.selectTracks([track.id]);
    await controller.saveSelectedCandidates();
    expect(writer.saved, hasLength(1));
    expect(writer.saved.single.map((v) => v.field), [AudioField.title]);
    expect(writer.saved.single.single.replaceExisting, isTrue);
  });
  test(
    'repair retry keeps field and corrected identity after failure',
    () async {
      source.fail = true;
      await controller.queryRepair(
        track.id,
        fields: {AudioField.album},
        searchTitle: '修正歌名',
        searchArtist: '修正歌手',
      );
      expect(controller.hasRetryableBatchFailures, isTrue);
      source.fail = false;
      source.candidates = const [
        FieldSuggestion(
          field: AudioField.album,
          value: '新专辑',
          source: 'Offline fixture',
        ),
      ];
      await controller.retryFailedBatch();
      expect(source.fields, {AudioField.album});
      expect(source.query!.title, '修正歌名');
      expect(controller.taskForTrack(track.id)!.isRepair, isTrue);
    },
  );
  test('inventory operation holds app and playback locks and releases after failure', () async {
    final barrier = Completer<void>();
    final operation = controller.runInventoryOperation(() async {
      await barrier.future;
      return 7;
    });
    expect(controller.canOperate, isFalse);
    expect(controller.preview.isBlocked, isTrue);
    barrier.complete();
    expect(await operation, 7);
    expect(controller.canOperate, isTrue);
    expect(controller.preview.isBlocked, isFalse);
    expect(
      await controller.runInventoryOperation<int>(
        () async => throw StateError('failed report'),
      ),
      isNull,
    );
    expect(controller.canOperate, isTrue);
    expect(controller.preview.isBlocked, isFalse);
  });
}
