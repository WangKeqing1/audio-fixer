import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_importer.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';

/// Available offline provider for tests of query controls, without network I/O.
class NoResultMetadataSource implements MetadataSource {
  @override
  String get name => 'Offline test source';
  @override
  Set<AudioField> get supportedFields => AudioField.coreFields;
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async => [];
}

AudioTrack fixtureTrack({
  String id = 'fixture',
  String? title = '测试歌曲',
  String? readError,
}) => AudioTrack(
  id: id,
  fileName: '$id.mp3',
  localPath: '/test/$id.mp3',
  sizeBytes: 1024,
  importedAt: DateTime(2026, 1, 1),
  title: title,
  artist: '测试歌手',
  readError: readError,
);

class MemoryStore implements LibraryStore {
  MemoryStore([this.snapshot = const LibrarySnapshot()]);
  LibrarySnapshot snapshot;
  bool failSave = false;
  bool failLoad = false;

  @override
  Future<LibrarySnapshot> load() async {
    if (failLoad) throw const FormatException('broken catalog');
    return snapshot;
  }

  @override
  Future<void> save(LibrarySnapshot value) async {
    if (failSave) throw StateError('disk full');
    snapshot = value;
  }
}

class FakePicker implements AudioPicker {
  List<String> names = [];
  @override
  Future<List<AudioSelection>> pick() async => names
      .map(
        (name) =>
            AudioSelection(name: name, openRead: () => const Stream.empty()),
      )
      .toList();
}

class FakeImporter implements AudioImporter {
  @override
  Future<void> prune(Set<String> retainedIds) async {}

  @override
  Future<AudioTrack> import(AudioSelection selection) async {
    if (selection.name == 'unreadable.mp3') throw StateError('file gone');
    return fixtureTrack(id: selection.name);
  }
}

LibraryController testController({
  MemoryStore? store,
  FakePicker? picker,
  CompletionService? completion,
  DeviceMusicLibrary? deviceLibrary,
}) => LibraryController(
  store: store ?? MemoryStore(),
  picker: picker ?? FakePicker(),
  importer: FakeImporter(),
  completion: completion ?? CompletionService(),
  deviceLibrary: deviceLibrary,
);

AudioTrack fixtureDeviceTrack({String id = '1', int modified = 1000}) =>
    AudioTrack(
      id: 'media:external_primary:$id',
      fileName: 'device-$id.mp3',
      contentUri: 'content://media/external_primary/audio/media/$id',
      sizeBytes: 4096,
      importedAt: DateTime(2026, 1, 1),
      dateModifiedMs: modified,
      title: '系统歌曲$id',
      artist: '系统歌手',
      detailsLoaded: false,
    );

class FakeDeviceLibrary implements DeviceMusicLibrary {
  AudioLibraryPermission permission = AudioLibraryPermission.notRequested;
  AudioLibraryPermission requestResult = AudioLibraryPermission.granted;
  List<AudioTrack> songs = [];
  int queryCount = 0;
  int requestCount = 0;
  int detailsCount = 0;
  int settingsCount = 0;
  bool failQuery = false;

  @override
  Future<AudioLibraryPermission> permissionStatus() async => permission;
  @override
  Future<AudioLibraryPermission> requestPermission() async {
    requestCount++;
    return permission = requestResult;
  }

  @override
  Future<void> openSettings() async {
    settingsCount++;
  }

  @override
  Future<List<AudioTrack>> querySongs() async {
    queryCount++;
    if (failQuery) throw StateError('query failed');
    return songs;
  }

  @override
  Future<AudioTrack> readDetails(AudioTrack track) async {
    detailsCount++;
    return track.withDetails(
      title: track.title,
      artist: track.artist,
      album: '文件专辑',
      year: null,
      durationMs: 60000,
      lyrics: '文件内嵌歌词',
      artworkPath: null,
    );
  }
}
