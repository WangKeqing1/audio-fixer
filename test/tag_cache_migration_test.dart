import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_importer.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

AudioTrack _old(AudioTrack track) {
  final json = track.toJson()..remove('tagReadVersion');
  return AudioTrack.fromJson({...json, 'detailsLoaded': true});
}

AudioTrack _fresh(AudioTrack track) => track.withDetails(
  title: track.title,
  artist: track.artist,
  album: '真实专辑',
  year: 2021,
  albumArtist: '真实专辑歌手',
  genre: 'Pop',
  composer: '真实作曲',
  durationMs: 60000,
  lyrics: '真实歌词',
  artworkPath: null,
  tagReadVersion: AudioTrack.currentTagReadVersion,
);

class _Device extends FakeDeviceLibrary {
  @override
  Future<AudioTrack> readDetails(AudioTrack track) async {
    detailsCount++;
    return _fresh(track);
  }
}

class _Importer extends FakeImporter implements AudioDetailsImporter {
  int reads = 0;
  @override
  Future<AudioTrack> readDetails(AudioTrack track) async {
    reads++;
    return _fresh(track);
  }
}

class _FailedImporter extends FakeImporter implements AudioDetailsImporter {
  @override
  Future<AudioTrack> readDetails(AudioTrack track) async =>
      track.withReadError('应用内音频副本无法读取，请检查文件。');
}

class _Writer implements AudioCopyExporter {
  int calls = 0;
  @override
  bool supports(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    calls++;
    return null;
  }
}

class _Source implements MetadataSource {
  AudioTrack? received;
  @override
  String get name => 'Offline fixture';
  @override
  Set<AudioField> get supportedFields => {AudioField.genre};
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async {
    received = track;
    return const [
      FieldSuggestion(
        field: AudioField.genre,
        value: 'Rock',
        source: 'Offline fixture',
      ),
    ];
  }
}

void main() {
  testWidgets(
    'opening an upgraded cached device track rereads all tags before editing',
    (tester) async {
      final indexed = fixtureDeviceTrack();
      final old = _old(indexed);
      final library = _Device()
        ..permission = AudioLibraryPermission.granted
        ..songs = [indexed];
      final writer = _Writer();
      final controller = LibraryController(
        store: MemoryStore(LibrarySnapshot(tracks: [old])),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(),
        deviceLibrary: library,
        exporter: writer,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.tracks.single.requiresTagRefresh, isTrue);
      expect(
        await controller.createManualRepair(old.id, {AudioField.genre: 'Rock'}),
        isNull,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TrackDetailPage(
            track: controller.tracks.single,
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(library.detailsCount, 1);
      final fresh = controller.tracks.single;
      expect(fresh.requiresTagRefresh, isFalse);
      expect(fresh.albumArtist, '真实专辑歌手');
      final task = (await controller.createManualRepair(fresh.id, {
        AudioField.genre: 'Rock',
      }))!;
      expect(task.suggestions.single.replaceExisting, isTrue);
      expect(writer.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'repair query refreshes old catalog even when detailsLoaded was true',
    () async {
      final indexed = fixtureDeviceTrack();
      final source = _Source();
      final library = _Device()
        ..permission = AudioLibraryPermission.granted
        ..songs = [indexed];
      final controller = LibraryController(
        store: MemoryStore(LibrarySnapshot(tracks: [_old(indexed)])),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: [source]),
        deviceLibrary: library,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.queryRepair(indexed.id, fields: {AudioField.genre});
      expect(library.detailsCount, 1);
      expect(source.received!.genre, 'Pop');
      expect(
        controller.taskForTrack(indexed.id)!.suggestions.single.replaceExisting,
        isTrue,
      );
      expect(
        controller.tracks.single.tagReadVersion,
        AudioTrack.currentTagReadVersion,
      );
    },
  );
  test('owned imported copies have an automatic upgrade reread path', () async {
    final importer = _Importer();
    final old = _old(fixtureTrack()).withInstrumental(true);
    final controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [old])),
      picker: FakePicker(),
      importer: importer,
      completion: CompletionService(),
      exporter: _Writer(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.canRereadTrack(old), isTrue);
    await controller.readDetails(old.id);
    expect(importer.reads, 1);
    expect(controller.tracks.single.requiresTagRefresh, isFalse);
    expect(controller.tracks.single.isInstrumental, isTrue);
    expect(controller.tracks.single.composer, '真实作曲');
    await controller.readDetails(old.id);
    expect(importer.reads, 1);
  });
  test(
    'old approved candidates remain unavailable until fresh tag inspection',
    () async {
      final old = _old(fixtureTrack());
      const candidate = FieldSuggestion(
        field: AudioField.lyrics,
        value: 'Approved',
        source: 'Offline fixture',
      );
      final task = CompletionTask(
        trackId: old.id,
        trackTitle: old.displayTitle,
        createdAt: DateTime(2026),
        status: TaskStatus.readyToSave,
        message: '',
        suggestions: const [candidate],
        approvedSuggestions: const [candidate],
      );
      final controller = LibraryController(
        store: MemoryStore(LibrarySnapshot(tracks: [old], tasks: [task])),
        picker: FakePicker(),
        importer: _Importer(),
        completion: CompletionService(),
        exporter: _Writer(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.isTaskCurrent(task), isFalse);
      expect(controller.approvedSuggestionsFor(task), isEmpty);
      await controller.readDetails(old.id);
      expect(controller.taskForTrack(old.id)!.status, TaskStatus.outdated);
    },
  );
  testWidgets('failed legacy cache refresh exposes the real read error', (
    tester,
  ) async {
    final track = _old(fixtureTrack());
    final controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [track])),
      picker: FakePicker(),
      importer: _FailedImporter(),
      completion: CompletionService(),
      exporter: _Writer(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: TrackDetailPage(track: track, controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.tracks.single.requiresTagRefresh, isTrue);
    await tester.scrollUntilVisible(
      find.text('应用内音频副本无法读取，请检查文件。'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('应用内音频副本无法读取，请检查文件。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('edit-metadata')),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
