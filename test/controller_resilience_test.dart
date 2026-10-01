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
  int calls = 0;
  @override
  String get name => 'Offline fixture';
  @override
  Set<AudioField> get supportedFields => AudioField.values.toSet();
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    calls++;
    return requestedFields
        .map(
          (field) => FieldSuggestion(
            field: field,
            value: field == AudioField.artwork
                ? 'https://coverartarchive.org/release/fixture/front'
                : 'Offline ${field.name}',
            source: name,
          ),
        )
        .toList();
  }
}

class _Exporter implements AudioCopyExporter {
  int calls = 0;
  @override
  bool supports(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    calls++;
    return 'content://fixture/export';
  }
}

class _Importer extends FakeImporter {
  int cleanups = 0;
  @override
  Future<void> prune(Set<String> retainedIds) async {
    cleanups++;
  }
}

void main() {
  test(
    'changed media invalidates old review even after details are read again',
    () async {
      final library = FakeDeviceLibrary()..songs = [fixtureDeviceTrack()];
      final source = _Source();
      final exporter = _Exporter();
      final controller = LibraryController(
        store: MemoryStore(),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: [source]),
        deviceLibrary: library,
        exporter: exporter,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.complete();
      final old = controller.tasks.single;
      expect(old.status, TaskStatus.needsReview);
      expect(controller.isTaskCurrent(old), isTrue);
      library.songs = [fixtureDeviceTrack(modified: 2000)];
      await controller.refreshLibrary();
      expect(controller.tasks.single.status, TaskStatus.outdated);
      expect(controller.isTaskCurrent(old), isFalse);
      expect(await controller.exportCandidates(old, old.suggestions), isFalse);
      await controller.readDetails(library.songs.single.id);
      expect(controller.isTaskCurrent(old), isFalse);
      expect(exporter.calls, 0);
      await controller.complete(track: controller.tracks.single);
      final current = controller.tasks.single;
      expect(controller.isTaskCurrent(current), isTrue);
      expect(
        await controller.exportCandidates(current, current.suggestions),
        isTrue,
      );
      expect(exporter.calls, 1);
    },
  );

  test(
    'batch continues unreviewed songs but new enabled fields query again',
    () async {
      final source = _Source();
      final controller = testController(
        store: MemoryStore(
          LibrarySnapshot(
            tracks: [fixtureTrack()],
            settings: const AppSettings(metadata: false, artwork: false),
          ),
        ),
        completion: CompletionService(sources: [source]),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.complete();
      expect(source.calls, 1);
      expect(controller.pendingCompletionCount, 0);
      await controller.complete();
      expect(source.calls, 1);
      await controller.updateSettings(
        controller.settings.copyWith(artwork: true),
      );
      expect(controller.pendingCompletionCount, 1);
      await controller.complete();
      expect(source.calls, 2);
      expect(controller.pendingCompletionCount, 0);
      await controller.complete(track: controller.tracks.single);
      expect(
        source.calls,
        3,
        reason: 'Explicit per-song retry is always available.',
      );
    },
  );

  test('batch count excludes gaps in disabled fields', () async {
    final track = fixtureTrack().withDetails(
      title: 'Known',
      artist: 'Known',
      album: null,
      year: null,
      durationMs: 60000,
      lyrics: 'Existing lyrics',
      artworkPath: null,
    );
    final source = _Source();
    final controller = testController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [track],
          settings: const AppSettings(metadata: false, artwork: false),
        ),
      ),
      completion: CompletionService(sources: [source]),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.incompleteCount, 1);
    expect(controller.pendingCompletionCount, 0);
    expect(controller.canQueryTrack(track), isFalse);
    await controller.complete();
    expect(source.calls, 0);
    expect(controller.tasks, isEmpty);
  });

  test('recovered catalog skips prune on load and all later commits', () async {
    final store = MemoryStore(
      LibrarySnapshot(tracks: [fixtureTrack()], recoveredFromBackup: true),
    );
    final importer = _Importer();
    final picker = FakePicker()..names = ['new.mp3'];
    final controller = LibraryController(
      store: store,
      picker: picker,
      importer: importer,
      completion: CompletionService(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.recoveryNotice, isNotNull);
    expect(importer.cleanups, 0);
    await controller.importAudio();
    await controller.updateSettings(const AppSettings(theme: AppTheme.dark));
    expect(importer.cleanups, 0);
    expect(store.snapshot.recoveredFromBackup, isTrue);
    expect(store.snapshot.tracks, hasLength(2));
  });

  test(
    'unknown/deleted track cannot be queried from an old detail object',
    () async {
      final source = _Source();
      final controller = testController(
        completion: CompletionService(sources: [source]),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.complete(track: fixtureTrack());
      expect(source.calls, 0);
      expect(controller.tasks, isEmpty);
    },
  );
}
