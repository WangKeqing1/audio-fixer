import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('startup requests audio permission once and loads MediaStore without importing files', () async {
    final library = FakeDeviceLibrary()..songs = [fixtureDeviceTrack()];
    final controller = testController(deviceLibrary: library);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(library.requestCount, 1);
    expect(controller.tracks.single.contentUri, startsWith('content://media/'));
    expect(controller.tracks.single.localPath, isEmpty);
    expect(
      controller.tracks.single.missingFields,
      isEmpty,
      reason: 'Uninspected tags are unknown.',
    );
    await controller.refreshLibrary();
    expect(library.requestCount, 1);
    expect(
      library.detailsCount,
      0,
      reason: 'Listing must not copy every song.',
    );
  });

  test('denied permission never auto-prompts again and revoked access hides cached songs', () async {
    final library = FakeDeviceLibrary()..songs = [fixtureDeviceTrack()];
    final store = MemoryStore();
    final controller = testController(deviceLibrary: library, store: store);
    addTearDown(controller.dispose);
    await controller.initialize();
    library.permission = AudioLibraryPermission.denied;
    await controller.refreshLibrary();
    expect(controller.tracks, isEmpty);
    expect(store.snapshot.tracks, hasLength(1));
    expect(library.requestCount, 1);
    await controller.authorizeLibrary();
    expect(controller.tracks, hasLength(1));
    expect(library.requestCount, 2);
  });

  test(
    'blocked permission opens app settings only on explicit action',
    () async {
      final library = FakeDeviceLibrary()
        ..permission = AudioLibraryPermission.blocked;
      final controller = testController(deviceLibrary: library);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(library.queryCount, 0);
      expect(library.requestCount, 0);
      expect(library.settingsCount, 0);
      await controller.authorizeLibrary();
      expect(library.settingsCount, 1);
    },
  );

  test(
    'unchanged songs keep inspected tags; changed songs are invalidated',
    () async {
      final song = fixtureDeviceTrack();
      final library = FakeDeviceLibrary()..songs = [song];
      final controller = testController(deviceLibrary: library);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.readDetails(song.id);
      expect(controller.tracks.single.lyrics, '文件内嵌歌词');
      await controller.refreshLibrary();
      expect(controller.tracks.single.detailsLoaded, isTrue);
      expect(controller.tracks.single.lyrics, '文件内嵌歌词');
      library.songs = [fixtureDeviceTrack(modified: 2000)];
      await controller.refreshLibrary();
      expect(controller.tracks.single.detailsLoaded, isFalse);
      expect(controller.tracks.single.lyrics, isNull);
    },
  );

  test('query failure preserves catalog; successful refresh adds/removes system entries and keeps old imports', () async {
    final library = FakeDeviceLibrary()..songs = [fixtureDeviceTrack()];
    final store = MemoryStore(LibrarySnapshot(tracks: [fixtureTrack()]));
    final controller = testController(deviceLibrary: library, store: store);
    addTearDown(controller.dispose);
    await controller.initialize();
    library.failQuery = true;
    await controller.refreshLibrary();
    expect(controller.libraryError, isNotNull);
    expect(store.snapshot.tracks, hasLength(2));
    library.failQuery = false;
    library.songs = [fixtureDeviceTrack(id: '2')];
    await controller.refreshLibrary();
    expect(controller.libraryError, isNull);
    expect(controller.tracks.map((track) => track.id).toSet(), {
      'fixture',
      'media:external_primary:2',
    });
    library.songs = [];
    await controller.refreshLibrary();
    expect(controller.tracks.single.id, 'fixture');
  });
}
