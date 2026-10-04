import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_preview_service.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/device_artwork_cache.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';

import 'fakes.dart';

/// Authored, offline catalog. No user inventory, audio files or network access.
class LargeLibraryFixture {
  LargeLibraryFixture({int trackCount = 4096, int taskCount = 512}) {
    tracks = List.generate(
      trackCount,
      (index) => AudioTrack(
        id: 'large-$index',
        fileName: '${index.toString().padLeft(4, '0')}-夜空 Café-$index.flac',
        contentUri: 'content://offline-fixture/music/$index',
        sizeBytes: 24000000 + index * 1000,
        importedAt: DateTime.utc(2026, 1, 1),
        dateModifiedMs: 1700000000000 + index,
        title: '夜空 Café 第 $index 首',
        artist: '合成歌手 ${index % 32}',
        album: '合成专辑 ${index ~/ 12}',
        albumArtist: '合成歌手 ${index % 32}',
        year: 2000 + index % 26,
        genre: index.isEven ? 'Pop' : 'Jazz',
        trackNumber: index % 12 + 1,
        trackTotal: 12,
        durationMs: 180000 + index % 180000,
        indexedDurationMs: 180000 + index % 180000,
        lyrics: index % 3 == 0 ? null : '[00:00.00]合成歌词，完全离线\n[00:12.00]第二句',
        detailsLoaded: index % 5 != 0,
        volumeName: 'fixture',
        relativePath: 'Music/Album ${index ~/ 12}/',
      ),
    );
    tasks = List.generate(
      taskCount,
      (index) => CompletionTask(
        trackId: tracks[index * trackCount ~/ taskCount].id,
        trackTitle: tracks[index * trackCount ~/ taskCount].displayTitle,
        createdAt: DateTime.utc(2026, 1, 2),
        status: index % 4 == 0 ? TaskStatus.noMatch : TaskStatus.needsReview,
        message: '离线合成任务，只供交互性能回归',
        queriedFields: const {AudioField.lyrics},
        suggestions: index % 4 == 0
            ? const []
            : const [
                FieldSuggestion(
                  field: AudioField.lyrics,
                  value: '[00:00.00]离线候选歌词\n[00:12.00]第二句',
                  source: 'Offline test source',
                ),
              ],
      ),
    );
    device = LargeLibraryDevice(tracks);
    controller = MeasuredLibraryController(
      store: MemoryStore(
        LibrarySnapshot(tracks: tracks, tasks: tasks, settings: settings),
      ),
      device: device,
      backend: backend,
    );
  }

  final settings = MeasuredSettings();
  final backend = LargeLibraryPreviewBackend();
  late final List<AudioTrack> tracks;
  late final List<CompletionTask> tasks;
  late final LargeLibraryDevice device;
  late final MeasuredLibraryController controller;
}

class MeasuredSettings extends AppSettings {
  int exclusionChecks = 0;
  @override
  bool excludes(AudioTrack track) {
    exclusionChecks++;
    return super.excludes(track);
  }
}

class MeasuredLibraryController extends LibraryController {
  MeasuredLibraryController({
    required super.store,
    required LargeLibraryDevice device,
    required LargeLibraryPreviewBackend backend,
  }) : super(
         picker: FakePicker(),
         importer: FakeImporter(),
         completion: CompletionService(sources: [NoResultMetadataSource()]),
         deviceLibrary: device,
         preview: AudioPreviewController(backend: backend),
       );

  int trackListReads = 0;
  int trackLookups = 0;
  int taskLookups = 0;
  @override
  List<AudioTrack> get tracks {
    trackListReads++;
    return super.tracks;
  }

  @override
  AudioTrack? trackById(String id) {
    trackLookups++;
    return super.trackById(id);
  }

  @override
  CompletionTask? taskForTrack(String id) {
    taskLookups++;
    return super.taskForTrack(id);
  }

  void resetMeasurements() {
    trackListReads = trackLookups = taskLookups = 0;
  }
}

class LargeLibraryDevice implements DeviceMusicLibrary, DeviceArtworkSource {
  LargeLibraryDevice(this.tracks);
  final List<AudioTrack> tracks;
  final Set<String> artworkReads = {};
  int artworkReadCount = 0;
  @override
  int artworkRevision = 1;
  @override
  Future<AudioLibraryPermission> permissionStatus() async =>
      AudioLibraryPermission.granted;
  @override
  Future<AudioLibraryPermission> requestPermission() async =>
      AudioLibraryPermission.granted;
  @override
  Future<void> openSettings() async {}
  @override
  Future<List<AudioTrack>> querySongs() async => tracks;
  @override
  Future<AudioTrack> readDetails(AudioTrack track) async => track;
  @override
  Future<Uint8List?> readArtworkThumbnail(AudioTrack track) async {
    artworkReadCount++;
    artworkReads.add(track.id);
    return _cover;
  }
}

// An authored 96×96 PNG thumbnail, shared bytes as an album cover would be.
final _cover = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAAvElEQVR4nO3QMRHAMAwEsHApElMogeyeSsAUiqQgS+KnnO6EQOu6O6JCdsiELEGCBAkSJEiQIEGCBAkSJEiQIEGCBAkSJEiQIEFnBD0dUSE7ZEIECRIkSJAgQYIECRIkSJAgQYIECRIkSJAgQYIEHRL0dkSF7JAJESRIkCBBggQJEiRIkCBBggQJEiRIkCBBggQJEnRI0NcRFbJDJkSQIEGCBAkSJEiQIEGCBAkSJEiQIEGCBAkSJEjQEUE/luQGlT/p1SEAAAAASUVORK5CYII=',
);

class LargeLibraryPreviewBackend implements AudioPreviewBackend {
  final _events = StreamController<AudioPreviewEvent>.broadcast(sync: true);
  AudioPreviewEvent? current;
  @override
  Stream<AudioPreviewEvent> get events => _events.stream;
  void progress(int positionMs) {
    final event = current!;
    current = AudioPreviewEvent(
      requestId: event.requestId,
      trackId: event.trackId,
      status: AudioPreviewStatus.playing,
      positionMs: positionMs,
      durationMs: 240000,
    );
    _events.add(current!);
  }

  @override
  Future<void> play({
    required int requestId,
    required String trackId,
    required String uri,
  }) async {
    current = AudioPreviewEvent(
      requestId: requestId,
      trackId: trackId,
      status: AudioPreviewStatus.playing,
      durationMs: 240000,
    );
    _events.add(current!);
  }

  @override
  Future<void> pause({required int requestId}) async {}
  @override
  Future<void> seek({required int requestId, required int positionMs}) async =>
      progress(positionMs);
  @override
  Future<void> stop() async {
    current = null;
  }

  @override
  Future<AudioPreviewEvent?> getState() async => current;
}
