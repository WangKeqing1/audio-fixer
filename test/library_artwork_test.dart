import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/device_artwork_cache.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/shared/widgets/library_track_artwork.dart';
import 'package:audio_fixer/shared/widgets/track_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

final _cover = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF9sAAAAASUVORK5CYII=',
);

class ArtworkDeviceLibrary extends FakeDeviceLibrary
    implements DeviceArtworkSource {
  @override
  int artworkRevision = 0;
  final calls = <String>[];
  final artwork = <String, Uint8List?>{};
  Future<Uint8List?> Function(AudioTrack)? load;

  @override
  Future<List<AudioTrack>> querySongs() async {
    final tracks = await super.querySongs();
    artworkRevision++;
    return tracks;
  }

  @override
  Future<Uint8List?> readArtworkThumbnail(AudioTrack track) async {
    calls.add(track.id);
    return load != null ? load!(track) : artwork[track.id];
  }
}

Finder _artworkFor(AudioTrack track) => find.descendant(
  of: find.byKey(ValueKey('library-artwork-${track.id}')),
  matching: find.byType(TrackArtwork),
);

void main() {
  testWidgets(
    'initial library shows embedded art and missing-art placeholder without tag reads',
    (tester) async {
      // This case checks two mounted cover rows, independent of header height.
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final present = fixtureDeviceTrack(id: '1');
      final absent = fixtureDeviceTrack(id: '2');
      final device = ArtworkDeviceLibrary()
        ..songs = [present, absent]
        ..artwork[present.id] = _cover;
      final controller = testController(deviceLibrary: device);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      expect(tester.widget<TrackArtwork>(_artworkFor(present)).bytes, _cover);
      expect(tester.widget<TrackArtwork>(_artworkFor(absent)).bytes, isNull);
      expect(device.detailsCount, 0);
      expect(controller.tracks.every((track) => !track.detailsLoaded), isTrue);
      expect(
        controller.tracks.every((track) => track.artworkPath == null),
        isTrue,
      );

      // A successful refresh retries missing art even when MediaStore's index
      // timestamp has not yet changed.
      device.artwork[absent.id] = _cover;
      await controller.refreshLibrary();
      await tester.pumpAndSettle();
      expect(tester.widget<TrackArtwork>(_artworkFor(absent)).bytes, _cover);
      expect(device.calls.where((id) => id == absent.id), hasLength(2));
      expect(device.detailsCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scrolling reads only mounted rows and reuses cached art on return',
    (tester) async {
      final tracks = List.generate(
        80,
        (index) => fixtureDeviceTrack(id: '${index + 1}'),
      );
      final device = ArtworkDeviceLibrary()
        ..songs = tracks
        ..artwork.addEntries(tracks.map((track) => MapEntry(track.id, _cover)));
      final controller = testController(deviceLibrary: device);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      final firstCount = device.calls
          .where((id) => id == tracks.first.id)
          .length;
      expect(device.calls.length, lessThan(20));
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      scroll.jumpTo(2200);
      await tester.pumpAndSettle();
      expect(device.calls.length, lessThan(tracks.length));
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TrackArtwork>(_artworkFor(tracks.first)).bytes,
        _cover,
      );
      expect(
        device.calls.where((id) => id == tracks.first.id),
        hasLength(firstCount),
      );
      expect(device.detailsCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('row reuse ignores an old request and disposal is safe', (
    tester,
  ) async {
    final first = fixtureDeviceTrack(id: '1');
    final second = fixtureDeviceTrack(id: '2');
    final oldResult = Completer<Uint8List?>();
    final newResult = Completer<Uint8List?>();
    final device = ArtworkDeviceLibrary()
      ..load = (track) =>
          track.id == first.id ? oldResult.future : newResult.future;
    final cache = DeviceArtworkCache(device);
    Widget view(AudioTrack track) => MaterialApp(
      home: LibraryTrackArtwork(track: track, cache: cache),
    );
    await tester.pumpWidget(view(first));
    await tester.pumpWidget(view(second));
    oldResult.complete(_cover);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TrackArtwork>(find.byType(TrackArtwork)).bytes,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    newResult.complete(_cover);
    await tester.pumpAndSettle();
    cache.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'permission revocation hides covers and reauthorization retries',
    (tester) async {
      final track = fixtureDeviceTrack();
      final device = ArtworkDeviceLibrary()
        ..songs = [track]
        ..artwork[track.id] = _cover;
      final controller = testController(deviceLibrary: device);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      expect(_artworkFor(track), findsOneWidget);
      device.permission = AudioLibraryPermission.denied;
      await controller.refreshLibrary();
      await tester.pumpAndSettle();
      expect(_artworkFor(track), findsNothing);
      await controller.authorizeLibrary();
      await tester.pumpAndSettle();
      expect(tester.widget<TrackArtwork>(_artworkFor(track)).bytes, _cover);
      expect(device.calls, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
}
