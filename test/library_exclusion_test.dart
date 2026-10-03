import 'dart:io';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_folder.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _music = AudioFolder(
  volumeName: 'external_primary',
  relativePath: 'Music',
);
const _lyrics = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'Test lyrics',
  source: 'Offline fixture',
);

AudioTrack _track(
  String id, {
  int? duration = 60000,
  String? path = 'Music/Album/',
  String? volume = 'external_primary',
  bool device = false,
  bool loaded = true,
}) => AudioTrack(
  id: id,
  fileName: '$id.mp3',
  localPath: device ? '' : '/private/$id.mp3',
  contentUri: device
      ? 'content://media/external_primary/audio/media/$id'
      : null,
  volumeName: volume,
  relativePath: path,
  durationMs: duration,
  indexedDurationMs: device ? duration : null,
  detailsLoaded: loaded,
  title: 'Title $id',
  artist: 'Artist',
  sizeBytes: 1234,
  importedAt: DateTime(2026),
  dateModifiedMs: 1000,
);

CompletionTask _task(String id) => CompletionTask(
  trackId: id,
  trackTitle: 'Title $id',
  createdAt: DateTime(2026),
  status: TaskStatus.readyToSave,
  message: 'Approved test candidate',
  suggestions: const [_lyrics],
  approvedSuggestions: const [_lyrics],
  queriedFields: const {AudioField.lyrics},
);

class _Source implements MetadataSource {
  final calls = <String>[];
  bool fail = false;
  void Function(AudioTrack)? afterLookup;
  @override
  String get name => 'Offline fixture';
  @override
  Set<AudioField> get supportedFields => {AudioField.lyrics};
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    calls.add(track.id);
    afterLookup?.call(track);
    if (fail) throw StateError('offline');
    return const [_lyrics];
  }
}

class _Library extends FakeDeviceLibrary {
  int? parsedDuration;
  @override
  Future<AudioTrack> readDetails(AudioTrack track) async {
    detailsCount++;
    return track.withDetails(
      title: track.title,
      artist: track.artist,
      album: track.album,
      year: track.year,
      durationMs: parsedDuration ?? track.durationMs,
      lyrics: track.lyrics,
      artworkPath: track.artworkPath,
    );
  }
}

class _Writer
    implements AudioCopyExporter, AudioOriginalSaver, AudioBatchExporter {
  final writes = <String>[];
  bool fail = false;
  int directories = 0;
  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    writes.add(track.id);
    if (fail) throw const ExportException('Test failure');
    return 'content://test/export/${track.id}';
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) => export(track, selected);
  @override
  Future<String?> chooseExportDirectory() async {
    directories++;
    return 'content://test/directory';
  }

  @override
  Future<String?> exportToDirectory(
    AudioTrack track,
    List<FieldSuggestion> selected,
    String directoryUri,
  ) => export(track, selected);
}

Future<LibraryController> _controller({
  required MemoryStore store,
  _Library? library,
  _Source? source,
  _Writer? writer,
  FakePicker? picker,
}) async {
  final controller = LibraryController(
    store: store,
    picker: picker ?? FakePicker(),
    importer: FakeImporter(),
    deviceLibrary: library,
    completion: CompletionService(sources: [?source]),
    exporter: writer,
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

void main() {
  test(
    'hidden selection can be pruned during an in-flight operation',
    () async {
      final store = MemoryStore(
        LibrarySnapshot(tracks: [_track('shown'), _track('hidden')]),
      );
      final controller = await _controller(store: store);
      controller.selectTracks({'shown', 'hidden'});
      controller.isBusy = true;
      controller.retainSelection({'shown'});
      expect(controller.selectedTrackIds, {'shown'});
      controller.isBusy = false;
      expect(store.snapshot.tracks.length, 2);
    },
  );

  test('duration boundary is strictly positive and below 60000 ms', () {
    const settings = AppSettings(excludeShortAudio: true);
    for (final duration in <int?>[null, -1, 0, 60000, 60001]) {
      expect(
        settings.excludes(_track('a', duration: duration)),
        isFalse,
        reason: '$duration',
      );
    }
    for (final duration in [1, 59999]) {
      expect(settings.excludes(_track('a', duration: duration)), isTrue);
    }
    expect(const AppSettings().excludes(_track('a', duration: 1)), isFalse);
  });

  test('folder matching uses exact volume and path-segment hierarchy', () {
    expect(
      _music.contains(
        const AudioFolder(
          volumeName: 'external_primary',
          relativePath: '/Music/Album/',
        ),
      ),
      isTrue,
    );
    expect(
      _music.contains(
        const AudioFolder(
          volumeName: 'external_primary',
          relativePath: 'Music2/',
        ),
      ),
      isFalse,
    );
    expect(
      _music.contains(
        const AudioFolder(
          volumeName: 'external_primary',
          relativePath: 'music/',
        ),
      ),
      isFalse,
    );
    expect(
      _music.contains(
        const AudioFolder(volumeName: 'ABCD-1234', relativePath: 'Music/'),
      ),
      isFalse,
    );
    const root = AudioFolder(volumeName: 'external_primary', relativePath: '');
    expect(root.contains(_music), isTrue);
    expect(
      root.contains(
        const AudioFolder(volumeName: 'ABCD-1234', relativePath: ''),
      ),
      isFalse,
    );
    expect(
      _music,
      const AudioFolder(
        volumeName: 'external_primary',
        relativePath: '/Music/',
      ),
    );
    expect(
      _music.id,
      const AudioFolder(
        volumeName: 'external_primary',
        relativePath: '/Music/',
      ).id,
    );
    expect(
      const AudioFolder(
        volumeName: 'external_primary',
        relativePath: 'Music/../Secret',
      ).isValid,
      isFalse,
    );
    expect(
      const AudioFolder(
        volumeName: 'external_primary',
        relativePath: 'Music/中文/现场',
      ).ancestors.map((f) => f.normalizedPath),
      ['', 'Music', 'Music/中文', 'Music/中文/现场'],
    );
  });

  test('legacy JSON stays visible and content URI is never a folder', () {
    final oldSettings = const AppSettings().toJson()
      ..remove('excludedFolders')
      ..remove('excludeShortAudio');
    final restored = AppSettings.fromJson(oldSettings);
    expect(restored.excludeShortAudio, isFalse);
    expect(restored.excludedFolders, isEmpty);
    final json = _track('1', device: true).toJson()
      ..remove('volumeName')
      ..remove('relativePath');
    final track = AudioTrack.fromJson(json);
    expect(track.folder, isNull);
    expect(
      const AppSettings(excludedFolders: [_music]).excludes(track),
      isFalse,
    );
  });

  test('folder and exclusion settings persist without dropping source rows or tasks', () async {
    final directory = await Directory.systemTemp.createTemp(
      'exclusion-persistence',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = JsonLibraryStore(() async => directory);
    final track = _track('short', duration: 59999);
    await store.save(
      LibrarySnapshot(
        tracks: [track],
        tasks: [_task(track.id)],
        settings: const AppSettings(
          excludeShortAudio: true,
          excludedFolders: [_music],
        ),
      ),
    );
    final loaded = await store.load();
    expect(loaded.settings.excludeShortAudio, isTrue);
    expect(loaded.settings.excludedFolders, [_music]);
    expect(loaded.tracks.single.folder, track.folder);
    expect(loaded.tasks.single.trackId, track.id);
    expect(loaded.tracks.single.withReadError('test').folder, track.folder);
  });

  test('filters retain snapshot, prune selection permanently, and explain unknowns', () async {
    final store = MemoryStore(
      LibrarySnapshot(
        tracks: [
          _track('short', duration: 59999),
          _track('exact', path: 'Music2'),
          _track('unknown', duration: null, volume: null, path: null),
          _track('zero', duration: 0, path: 'Music2'),
          _track('negative', duration: -10, path: 'Music2'),
        ],
      ),
    );
    final controller = await _controller(store: store);
    controller.selectTracks(controller.tracks.map((track) => track.id));
    await controller.updateSettings(
      controller.settings.copyWith(excludeShortAudio: true),
    );
    expect(controller.tracks.map((t) => t.id), [
      'exact',
      'unknown',
      'zero',
      'negative',
    ]);
    expect(controller.allTracks, hasLength(5));
    expect(controller.excludedTrackCount, 1);
    expect(controller.unknownDurationCount, 3);
    expect(controller.unknownFolderCount, 1);
    expect(controller.selectedTrackIds, {
      'exact',
      'unknown',
      'zero',
      'negative',
    });
    controller.retainSelection({'exact'});
    await controller.updateSettings(
      controller.settings.copyWith(excludeShortAudio: false),
    );
    expect(controller.selectedTrackIds, {'exact'});
    expect(store.snapshot.tracks, hasLength(5));
  });

  test(
    'available ancestors and saved empty folders remain selectable',
    () async {
      const empty = AudioFolder(
        volumeName: 'ABCD-1234',
        relativePath: 'Archived/Music',
      );
      final controller = await _controller(
        store: MemoryStore(
          LibrarySnapshot(
            tracks: [_track('a', path: 'Music/Live/Set')],
            settings: const AppSettings(excludedFolders: [empty]),
          ),
        ),
      );
      expect(
        controller.folderChoices.map((f) => f.id),
        containsAll([
          empty.id,
          _music.id,
          const AudioFolder(
            volumeName: 'external_primary',
            relativePath: '',
          ).id,
          const AudioFolder(
            volumeName: 'external_primary',
            relativePath: 'Music/Live',
          ).id,
          const AudioFolder(
            volumeName: 'ABCD-1234',
            relativePath: 'Archived',
          ).id,
        ]),
      );
    },
  );

  test('imports do not delete or duplicate excluded records', () async {
    final picker = FakePicker()..names = ['new.mp3'];
    final store = MemoryStore(
      LibrarySnapshot(
        tracks: [_track('short', duration: 1)],
        settings: const AppSettings(excludeShortAudio: true),
      ),
    );
    final controller = await _controller(store: store, picker: picker);
    await controller.importAudio();
    expect(
      store.snapshot.tracks.map((t) => t.id),
      containsAll(['short', 'new.mp3']),
    );
    expect(controller.tracks.single.id, 'new.mp3');
  });

  test('refresh prunes moved folders and new short duration without modified timestamp', () async {
    final library = _Library()
      ..songs = [
        _track('1', device: true, path: 'Keep'),
        _track('2', device: true, path: 'Keep'),
      ];
    final controller = await _controller(
      store: MemoryStore(),
      library: library,
    );
    await controller.updateSettings(
      controller.settings.copyWith(
        excludeShortAudio: true,
        excludedFolders: [_music],
      ),
    );
    controller.selectTracks(['1', '2']);
    library.songs = [
      _track('1', device: true),
      _track('2', device: true, path: 'Keep', duration: 59999),
    ];
    await controller.refreshLibrary();
    expect(controller.tracks, isEmpty);
    expect(controller.selectedTrackIds, isEmpty);
    expect(controller.allTracks, hasLength(2));
    await controller.updateSettings(
      controller.settings.copyWith(
        excludeShortAudio: false,
        excludedFolders: [],
      ),
    );
    expect(controller.tracks, hasLength(2));
    expect(controller.selectedTrackIds, isEmpty);
  });

  test(
    'permission loss cannot revive hidden selection after reauthorization',
    () async {
      final library = _Library()..songs = [_track('1', device: true)];
      final controller = await _controller(
        store: MemoryStore(),
        library: library,
      );
      controller.selectTracks(['1']);
      library.permission = AudioLibraryPermission.denied;
      await controller.refreshLibrary();
      expect(controller.selectedTrackIds, isEmpty);
      await controller.authorizeLibrary();
      expect(controller.tracks, hasLength(1));
      expect(controller.selectedTrackIds, isEmpty);
    },
  );

  test(
    'duration discovered by reading details is skipped before online query',
    () async {
      final source = _Source();
      final library = _Library()
        ..parsedDuration = 59999
        ..songs = [_track('1', device: true, duration: null, loaded: false)];
      final store = MemoryStore(
        const LibrarySnapshot(settings: AppSettings(excludeShortAudio: true)),
      );
      final controller = await _controller(
        store: store,
        library: library,
        source: source,
      );
      controller.selectTracks(['1']);
      await controller.complete(trackIds: {'1'});
      expect(source.calls, isEmpty);
      expect(controller.batchOperation!.items.single.status.name, 'skipped');
      expect(controller.tracks, isEmpty);
      expect(controller.selectedTrackIds, isEmpty);
      expect(store.snapshot.tracks.single.durationMs, 59999);
    },
  );

  test(
    'filtered identify failure retry never queries an excluded track',
    () async {
      final source = _Source()..fail = true;
      final controller = await _controller(
        store: MemoryStore(
          LibrarySnapshot(tracks: [_track('a', duration: 59999)]),
        ),
        source: source,
      );
      await controller.complete(trackIds: {'a'});
      expect(controller.hasRetryableBatchFailures, isTrue);
      await controller.updateSettings(
        controller.settings.copyWith(excludeShortAudio: true),
      );
      expect(controller.hasRetryableBatchFailures, isFalse);
      source.fail = false;
      await controller.retryFailedBatch();
      await controller.complete(track: _track('a'));
      expect(source.calls, ['a']);
      expect(controller.allTracks, hasLength(1));
    },
  );

  test('filtered failed save retry and direct save are blocked with records retained', () async {
    final writer = _Writer()..fail = true;
    final store = MemoryStore(
      LibrarySnapshot(tracks: [_track('a')], tasks: [_task('a')]),
    );
    final controller = await _controller(store: store, writer: writer);
    controller.selectTracks(['a']);
    await controller.saveSelectedCandidates();
    expect(writer.writes, ['a']);
    await controller.updateSettings(
      controller.settings.copyWith(excludedFolders: [_music]),
    );
    writer.fail = false;
    await controller.retryFailedBatch();
    expect(
      await controller.saveCandidates(controller.tasks.single, const [_lyrics]),
      isFalse,
    );
    expect(writer.writes, ['a']);
    expect(store.snapshot.tracks, hasLength(1));
    expect(store.snapshot.tasks, hasLength(1));
  });

  test('freshly read short duration prevents original and copy save', () async {
    for (final copy in [false, true]) {
      final writer = _Writer();
      final library = _Library()
        ..parsedDuration = 59999
        ..songs = [_track('1', device: true, duration: null)];
      final store = MemoryStore(
        LibrarySnapshot(
          tracks: [_track('1', device: true, duration: null)],
          tasks: [_task('1')],
          settings: const AppSettings(excludeShortAudio: true),
        ),
      );
      final controller = await _controller(
        store: store,
        library: library,
        writer: writer,
      );
      controller.selectTracks(['1']);
      await controller.saveSelectedCandidates(exportCopies: copy);
      expect(writer.writes, isEmpty);
      expect(controller.batchOperation!.items.single.status.name, 'skipped');
      expect(controller.tracks, isEmpty);
      expect(controller.allTracks.single.durationMs, 59999);
    }
  });

  test('scoped batch save intersects current selection', () async {
    final writer = _Writer();
    final controller = await _controller(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [_track('a'), _track('b'), _track('c')],
          tasks: [_task('a'), _task('b'), _task('c')],
        ),
      ),
      writer: writer,
    );
    controller.selectTracks(['a', 'b']);
    await controller.saveSelectedCandidates(trackIds: {'b', 'c'});
    expect(writer.writes, ['b']);
  });

  test(
    'each identify item rechecks folder metadata after the previous query',
    () async {
      final library = _Library()
        ..songs = [
          _track('1', device: true, path: 'Keep'),
          _track('2', device: true, path: 'Keep'),
        ];
      final source = _Source()
        ..afterLookup = (track) {
          if (track.id == '1') {
            library.songs = [
              _track('1', device: true, path: 'Keep'),
              _track('2', device: true),
            ];
          }
        };
      final controller = await _controller(
        store: MemoryStore(
          const LibrarySnapshot(
            settings: AppSettings(excludedFolders: [_music]),
          ),
        ),
        library: library,
        source: source,
      );
      await controller.complete(trackIds: {'1', '2'});
      expect(source.calls, ['1']);
      expect(controller.batchOperation!.items.last.status.name, 'skipped');
      expect(controller.allTracks, hasLength(2));
    },
  );

  test('failed refresh blocks filtered query and save rather than using cached paths', () async {
    final library = _Library()
      ..songs = [_track('1', device: true, path: 'Keep')];
    final source = _Source();
    final writer = _Writer();
    final store = MemoryStore(
      LibrarySnapshot(
        tracks: library.songs,
        tasks: [_task('1')],
        settings: const AppSettings(excludedFolders: [_music]),
      ),
    );
    final controller = await _controller(
      store: store,
      library: library,
      source: source,
      writer: writer,
    );
    library.failQuery = true;
    await controller.complete(trackIds: {'1'});
    expect(
      await controller.saveCandidates(controller.tasks.single, const [_lyrics]),
      isFalse,
    );
    expect(source.calls, isEmpty);
    expect(writer.writes, isEmpty);
    expect(controller.allTracks, hasLength(1));
    expect(controller.libraryError, isNotNull);
  });

  test(
    'settings persistence failure does not silently prune eligible selection',
    () async {
      final store = MemoryStore(
        LibrarySnapshot(tracks: [_track('a', duration: 1)]),
      );
      final controller = await _controller(store: store);
      controller.selectTracks(['a']);
      store.failSave = true;
      await controller.updateSettings(
        controller.settings.copyWith(excludeShortAudio: true),
      );
      expect(controller.settings.excludeShortAudio, isFalse);
      expect(controller.selectedTrackIds, {'a'});
      expect(controller.tracks, hasLength(1));
    },
  );

  test('index rounding does not invalidate parsed duration and confirmed candidates', () async {
    final indexed = _track('1', device: true, duration: 60000);
    final parsed = indexed.withDetails(
      title: indexed.title,
      artist: indexed.artist,
      album: indexed.album,
      year: null,
      durationMs: 60001,
      lyrics: null,
      artworkPath: null,
    );
    final library = _Library()
      ..songs = [indexed]
      ..parsedDuration = 60001;
    final writer = _Writer();
    final controller = await _controller(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [parsed],
          tasks: [_task('1')],
          settings: const AppSettings(excludeShortAudio: true),
        ),
      ),
      library: library,
      writer: writer,
    );
    await controller.refreshLibrary();
    expect(controller.tracks.single.durationMs, 60001);
    expect(controller.tracks.single.indexedDurationMs, 60000);
    expect(controller.tasks.single.status, TaskStatus.readyToSave);
    expect(
      await controller.exportCandidates(controller.tasks.single, const [
        _lyrics,
      ]),
      isTrue,
    );
    expect(writer.writes, ['1']);
    library.songs = [_track('1', device: true, duration: 59999)];
    await controller.refreshLibrary();
    expect(controller.tracks, isEmpty);
    expect(controller.tasks.single.status, TaskStatus.outdated);
  });
}
