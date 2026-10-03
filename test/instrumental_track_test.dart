import 'dart:async';
import 'dart:io';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/lyrics_translation_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _lyricsOnly = AppSettings(metadata: false, artwork: false);
const _lyric = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'Fixture original lyrics',
  source: 'Offline fixture',
);
const _album = FieldSuggestion(
  field: AudioField.album,
  value: 'Fixture album',
  source: 'Offline fixture',
);

AudioTrack _track({bool instrumental = false, String? lyrics}) => AudioTrack(
  id: 'instrumental',
  fileName: 'instrumental.mp3',
  localPath: '/test/instrumental.mp3',
  sizeBytes: 1024,
  importedAt: DateTime(2026),
  title: 'Offline instrumental',
  artist: 'Fixture artist',
  album: 'Fixture album',
  artworkPath: '/test/cover.png',
  lyrics: lyrics,
  isInstrumental: instrumental,
);

class _Source implements MetadataSource {
  _Source({this.results = const [], this.delay});
  final List<FieldSuggestion> results;
  final Completer<List<FieldSuggestion>>? delay;
  final started = Completer<void>();
  final requests = <Set<AudioField>>[];
  @override
  String get name => 'Offline fixture';
  @override
  Set<AudioField> get supportedFields => AudioField.values.toSet();
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    requests.add(requestedFields);
    if (!started.isCompleted) started.complete();
    return delay == null ? results : await delay!.future;
  }
}

class _Translator implements LyricsTranslator {
  int calls = 0;
  @override
  Future<TranslationModelStatus> inspect(String original) async {
    calls++;
    return const TranslationModelStatus(sourceLanguage: 'en', ready: true);
  }

  @override
  Future<void> downloadModels(String sourceLanguage) async => calls++;
  @override
  Future<LyricTranslation> translateIfReady(String original) async {
    calls++;
    return const LyricTranslation(chineseLyrics: '离线译文');
  }
}

class _Exporter implements AudioCopyExporter, AudioBatchExporter {
  final writes = <List<FieldSuggestion>>[];
  @override
  bool supports(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    writes.add(selected);
    return 'content://fixture/export';
  }

  @override
  Future<String?> chooseExportDirectory() async =>
      'content://fixture/directory';
  @override
  Future<String?> exportToDirectory(
    AudioTrack track,
    List<FieldSuggestion> selected,
    String directoryUri,
  ) => export(track, selected);
}

class _ReadingLibrary extends FakeDeviceLibrary {
  String? lyrics;
  @override
  Future<AudioTrack> readDetails(AudioTrack track) async {
    detailsCount++;
    // Deliberately construct a fresh object: the controller must preserve the
    // annotation even if a device adapter does not use AudioTrack.withDetails.
    return AudioTrack(
      id: track.id,
      fileName: track.fileName,
      contentUri: track.contentUri,
      dateModifiedMs: track.dateModifiedMs,
      sizeBytes: track.sizeBytes,
      importedAt: track.importedAt,
      title: track.title,
      artist: track.artist,
      album: 'Fixture album',
      lyrics: lyrics,
      artworkPath: '/test/cover.png',
    );
  }
}

void main() {
  test('old catalogs never infer instrumental from missing lyrics', () {
    final old = _track().toJson()..remove('isInstrumental');
    final track = AudioTrack.fromJson(old);
    expect(track.isInstrumental, isFalse);
    expect(track.missingFields, {AudioField.lyrics});
    expect(track.needsCompletion, isTrue);
  });

  test(
    'mark only removes missing lyrics, preserving actual tags and artwork',
    () {
      final original = _track(lyrics: 'Preserved existing lyrics');
      final marked = original.withInstrumental(true);
      expect(marked.lyrics, original.lyrics);
      expect(marked.artworkPath, original.artworkPath);
      expect(marked.toJson()['isInstrumental'], isTrue);
      expect(marked.withReadError('unreadable').isInstrumental, isTrue);
      expect(_track().withInstrumental(true).missingFields, isEmpty);
      expect(_track(instrumental: true).withInstrumental(false).missingFields, {
        AudioField.lyrics,
      });
    },
  );

  test(
    'instrumental bypasses lyric providers and all translation work',
    () async {
      final source = _Source(results: [_lyric]);
      final translator = _Translator();
      final result =
          await CompletionService(
            sources: [source],
            translator: translator,
          ).preview(
            _track(instrumental: true),
            const AppSettings(onDeviceTranslationEnabled: true),
          );
      expect(source.requests, isEmpty);
      expect(translator.calls, 0);
      expect(result.status, TaskStatus.skipped);
      expect(result.message, contains('纯音乐'));
    },
  );

  test('instrumental still queries metadata and artwork, rejects unsolicited lyrics', () async {
    final source = _Source(results: [_album, _lyric]);
    final translator = _Translator();
    final track = fixtureTrack().withInstrumental(true);
    final result = await CompletionService(
      sources: [source],
      translator: translator,
    ).preview(track, const AppSettings(onDeviceTranslationEnabled: true));
    expect(source.requests.single, {AudioField.album, AudioField.artwork});
    expect(result.suggestions.single, _album);
    expect(translator.calls, 0);
  });

  test(
    'no-match stays unmarked until explicit action, undo restores query',
    () async {
      final source = _Source();
      final controller = testController(
        store: MemoryStore(
          LibrarySnapshot(tracks: [_track()], settings: _lyricsOnly),
        ),
        completion: CompletionService(sources: [source]),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.complete();
      expect(controller.tasks.single.status, TaskStatus.noMatch);
      expect(controller.tracks.single.isInstrumental, isFalse);
      expect(
        await controller.setTrackInstrumental('instrumental', true),
        isTrue,
      );
      expect(controller.incompleteCount, 0);
      expect(controller.pendingCompletionCount, 0);
      expect(controller.tasks.single.status, TaskStatus.skipped);
      await controller.complete(track: controller.tracks.single);
      expect(source.requests, hasLength(1));
      expect(controller.tracks.single.lyrics, isNull);
      expect(
        await controller.setTrackInstrumental('instrumental', false),
        isTrue,
      );
      expect(controller.pendingCompletionCount, 1);
      await controller.complete();
      expect(source.requests, hasLength(2));
    },
  );

  test('mark survives real disk save and restart; undo persists too', () async {
    final root = await Directory.systemTemp.createTemp('instrumental_catalog_');
    addTearDown(() => root.delete(recursive: true));
    final store = JsonLibraryStore(() async => root);
    await store.save(LibrarySnapshot(tracks: [_track()]));
    LibraryController makeController() => LibraryController(
      store: store,
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
    );
    final first = makeController();
    await first.initialize();
    expect(await first.setTrackInstrumental('instrumental', true), isTrue);
    first.dispose();
    final second = makeController();
    await second.initialize();
    expect(second.tracks.single.isInstrumental, isTrue);
    expect(second.tracks.single.lyrics, isNull);
    expect(second.tracks.single.artworkPath, '/test/cover.png');
    await second.setTrackInstrumental('instrumental', false);
    second.dispose();
    expect((await store.load()).tracks.single.isInstrumental, isFalse);
  });

  test('mark survives unchanged/changed index and rereads without discarding lyrics', () async {
    final device = _ReadingLibrary()..songs = [fixtureDeviceTrack()];
    final controller = testController(deviceLibrary: device);
    addTearDown(controller.dispose);
    await controller.initialize();
    final id = controller.tracks.single.id;
    await controller.readDetails(id);
    await controller.setTrackInstrumental(id, true);
    await controller.refreshLibrary();
    expect(controller.tracks.single.isInstrumental, isTrue);
    device.songs = [fixtureDeviceTrack(modified: 2000)];
    await controller.refreshLibrary();
    expect(controller.tracks.single.detailsLoaded, isFalse);
    expect(controller.tracks.single.isInstrumental, isTrue);
    device.lyrics = 'Externally added existing lyrics';
    await controller.readDetails(id);
    expect(controller.tracks.single.isInstrumental, isTrue);
    expect(controller.tracks.single.lyrics, device.lyrics);
    await controller.readDetails(id, force: true);
    expect(controller.tracks.single.isInstrumental, isTrue);
    expect(controller.tracks.single.artworkPath, '/test/cover.png');
  });

  test(
    'failed persistence leaves annotation and task approvals unchanged',
    () async {
      final store = MemoryStore(LibrarySnapshot(tracks: [_track()]));
      final controller = testController(store: store);
      addTearDown(controller.dispose);
      await controller.initialize();
      store.failSave = true;
      expect(
        await controller.setTrackInstrumental('instrumental', true),
        isFalse,
      );
      expect(controller.tracks.single.isInstrumental, isFalse);
      expect(store.snapshot.tracks.single.isInstrumental, isFalse);
      expect(controller.canOperate, isTrue);
    },
  );

  test(
    'busy lookup cannot race an instrumental change or revive old lyrics',
    () async {
      final pending = Completer<List<FieldSuggestion>>();
      final source = _Source(delay: pending);
      final controller = testController(
        store: MemoryStore(
          LibrarySnapshot(tracks: [_track()], settings: _lyricsOnly),
        ),
        completion: CompletionService(sources: [source]),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final operation = controller.complete();
      await source.started.future;
      expect(
        await controller.setTrackInstrumental('instrumental', true),
        isFalse,
      );
      pending.complete([_lyric]);
      await operation;
      final old = controller.tasks.single;
      await controller.setTrackInstrumental('instrumental', true);
      expect(controller.isTaskCurrent(old), isFalse);
      expect(controller.tasks.single.suggestions, isEmpty);
      expect(await controller.approveCandidates(old, [_lyric]), isFalse);
      await controller.setTrackInstrumental('instrumental', false);
      expect(controller.isTaskCurrent(old), isFalse);
      expect(await controller.approveCandidates(old, [_lyric]), isFalse);
    },
  );

  test(
    'mark keeps other candidates and explicit approvals, never lyric approval',
    () async {
      final track = fixtureTrack();
      final task = CompletionTask(
        trackId: track.id,
        trackTitle: track.displayTitle,
        createdAt: DateTime(2026),
        status: TaskStatus.readyToSave,
        message: 'Approved offline fixture',
        suggestions: [_album, _lyric],
        approvedSuggestions: [_album, _lyric],
        queriedFields: AudioField.values.toSet(),
      );
      final controller = testController(
        store: MemoryStore(LibrarySnapshot(tracks: [track], tasks: [task])),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.setTrackInstrumental(track.id, true);
      final current = controller.tasks.single;
      expect(current.status, TaskStatus.readyToSave);
      expect(current.suggestions, [_album]);
      expect(controller.approvedSuggestionsFor(current), [_album]);
      expect(controller.pendingCompletionCount, 0);
      expect(await controller.approveCandidates(current, [_lyric]), isFalse);
      await controller.setTrackInstrumental(track.id, false);
      expect(controller.pendingCompletionCount, 1);
    },
  );

  test('stale lyric export and batch save cannot write an instrumental placeholder', () async {
    final track = fixtureTrack();
    final task = CompletionTask(
      trackId: track.id,
      trackTitle: track.displayTitle,
      createdAt: DateTime(2026),
      status: TaskStatus.readyToSave,
      message: 'Approved offline fixture',
      suggestions: [_album, _lyric],
      approvedSuggestions: [_album, _lyric],
      queriedFields: AudioField.values.toSet(),
    );
    final exporter = _Exporter();
    final controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [track], tasks: [task])),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
      exporter: exporter,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.setTrackInstrumental(track.id, true);
    expect(await controller.exportCandidates(task, [_lyric]), isFalse);
    expect(exporter.writes, isEmpty);
    controller.selectTracks([track.id]);
    await controller.saveSelectedCandidates(exportCopies: true);
    expect(exporter.writes.single, [_album]);
    expect(controller.tracks.single.isInstrumental, isTrue);
    expect(controller.tracks.single.lyrics, isNull);
  });

  for (final status in [TaskStatus.savedOriginal, TaskStatus.exported]) {
    test('instrumental toggles preserve ${status.name} history', () async {
      final track = _track();
      final task = CompletionTask(
        trackId: track.id,
        trackTitle: track.displayTitle,
        createdAt: DateTime(2026),
        status: status,
        message: 'Verified historical write',
        suggestions: [_lyric],
        exportedCopyUri: 'content://fixture/exported.mp3',
        queriedFields: {AudioField.lyrics},
      );
      final controller = testController(
        store: MemoryStore(LibrarySnapshot(tracks: [track], tasks: [task])),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.setTrackInstrumental(track.id, true);
      expect(controller.tasks.single.status, status);
      await controller.setTrackInstrumental(track.id, false);
      expect(controller.tasks.single.status, status);
      expect(controller.tasks.single.exportedCopyUri, task.exportedCopyUri);
      expect(controller.tracks.single.lyrics, isNull);
    });
  }

  test('unknown, excluded and unreadable tracks cannot be marked', () async {
    final track = fixtureDeviceTrack();
    final short = fixtureTrack(id: 'short').withDetails(
      title: 'Short fixture',
      artist: 'Fixture',
      album: null,
      year: null,
      durationMs: 30000,
      lyrics: null,
      artworkPath: null,
    );
    final controller = testController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [
            track,
            short,
            fixtureTrack(readError: 'bad tags'),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(await controller.setTrackInstrumental('gone', true), isFalse);
    expect(await controller.setTrackInstrumental(track.id, true), isFalse);
    expect(await controller.setTrackInstrumental('fixture', true), isFalse);
    await controller.updateSettings(const AppSettings(excludeShortAudio: true));
    expect(controller.trackById(short.id), isNull);
    expect(await controller.setTrackInstrumental(short.id, true), isFalse);
    expect(controller.tracks.every((item) => !item.isInstrumental), isTrue);
  });
}
