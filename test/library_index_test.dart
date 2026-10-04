import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/large_library_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'selection and lookups reuse immutable catalog views without rescans',
    () async {
      final fixture = LargeLibraryFixture();
      final controller = fixture.controller;
      await controller.initialize();
      addTearDown(controller.dispose);
      final tracks = controller.tracks;
      final tasks = controller.tasks;
      fixture.settings.exclusionChecks = 0;
      controller.selectTracks(tracks.map((track) => track.id));
      final selected = controller.selectedTrackIds;
      for (var i = 0; i < 4096; i++) {
        expect(controller.trackById('large-$i'), same(tracks[i]));
        controller.taskForTrack('large-$i');
        expect(controller.selectedCount, 4096);
      }
      expect(fixture.settings.exclusionChecks, 0);
      expect(controller.tracks, same(tracks));
      expect(controller.tasks, same(tasks));
      expect(() => tracks.clear(), throwsUnsupportedError);
      expect(() => tasks.clear(), throwsUnsupportedError);
      expect(() => selected.clear(), throwsUnsupportedError);
      controller.clearSelection();
      expect(
        selected.length,
        4096,
        reason: 'Previously returned selection stays immutable',
      );
      expect(controller.selectedCount, 0);
    },
  );

  test(
    'permission and exclusion changes invalidate indexes and prune selection',
    () async {
      final fixture = LargeLibraryFixture(trackCount: 8, taskCount: 4);
      final controller = fixture.controller;
      await controller.initialize();
      addTearDown(controller.dispose);
      controller.selectTracks(['large-0', 'large-1']);
      final before = controller.tracks;
      controller.libraryPermission = AudioLibraryPermission.blocked;
      expect(controller.tracks, isEmpty);
      expect(controller.trackById('large-0'), isNull);
      expect(controller.selectedTrackIds, isEmpty);
      controller.libraryPermission = AudioLibraryPermission.granted;
      expect(controller.tracks, hasLength(8));
      expect(controller.tracks, isNot(same(before)));
      expect(controller.selectedTrackIds, isEmpty);
    },
  );

  test('reloaded snapshots replace track/task indexes and preserve first-match order', () async {
    final first = fixtureTrack(id: 'a');
    final task = CompletionTask(
      trackId: 'a',
      trackTitle: first.displayTitle,
      createdAt: DateTime.utc(2026),
      status: TaskStatus.noMatch,
      message: 'First',
    );
    final duplicate = CompletionTask(
      trackId: 'a',
      trackTitle: 'Duplicate',
      createdAt: DateTime.utc(2026),
      status: TaskStatus.failed,
      message: 'Second',
    );
    final store = MemoryStore(
      LibrarySnapshot(
        tracks: [
          first,
          fixtureTrack(id: 'a', title: 'Duplicate track'),
        ],
        tasks: [task, duplicate],
      ),
    );
    final controller = testController(store: store);
    await controller.initialize();
    addTearDown(controller.dispose);
    expect(controller.trackById('a'), same(first));
    expect(controller.taskForTrack('a'), same(task));
    controller.selectTracks(['a']);
    final oldTasks = controller.tasks;
    final second = fixtureTrack(id: 'b');
    store.snapshot = LibrarySnapshot(tracks: [second], tasks: [duplicate]);
    await controller.initialize();
    expect(controller.trackById('a'), isNull);
    expect(controller.trackById('b'), same(second));
    expect(controller.taskForTrack('a'), same(duplicate));
    expect(controller.selectedTrackIds, isEmpty);
    expect(oldTasks, [task, duplicate]);
  });

  test(
    'settings edits and artwork reports invalidate only current snapshot data',
    () async {
      final track = AudioTrack.fromJson({
        ...fixtureTrack().toJson(),
        'durationMs': 30000,
        'artworkPath': '/fixture/cover.png',
      });
      final controller = testController(
        store: MemoryStore(LibrarySnapshot(tracks: [track])),
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      final unvalidated = controller.tracks;
      controller.reportArtworkLoaded(track.id, track.artworkPath);
      expect(controller.trackById(track.id)!.hasArtwork, isTrue);
      expect(unvalidated.single.hasArtwork, isFalse);
      final validated = controller.tracks;
      controller.reportArtworkFailure(
        track.id,
        '/stale/cover.png',
        'late failure',
      );
      expect(controller.tracks, same(validated));
      controller.selectTracks([track.id]);
      await controller.updateSettings(
        const AppSettings(excludeShortAudio: true),
      );
      expect(controller.allTracks, hasLength(1));
      expect(controller.tracks, isEmpty);
      expect(controller.trackById(track.id), isNull);
      expect(controller.selectedCount, 0);
    },
  );
}
