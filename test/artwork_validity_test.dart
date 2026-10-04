import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/artwork_validation.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/shared/widgets/track_artwork.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAD0lEQVR4nGNgaGgAIQgFABoOBAH77Fo+AAAAAElFTkSuQmCC',
);
AudioTrack _track(String? path, {String? digest}) => AudioTrack(
  id: 'cover-validity',
  fileName: 'cover.mp3',
  sizeBytes: 100,
  importedAt: DateTime(2026),
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  lyrics: 'Lyrics',
  artworkPath: path,
  artworkSha256: digest,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('cover-validity-'),
  );
  tearDown(() async => root.delete(recursive: true));

  test('nonempty cache path is never proof of visible cover', () async {
    final track = _track('${root.path}/missing.cover', digest: 'original-hash');
    expect(track.hasArtwork, isFalse);
    expect(track.artworkNeedsCheck, isTrue);
    final checked = await validateTrackArtwork(track);
    expect(checked.hasArtwork, isFalse);
    expect(checked.artworkError, contains('无法读取'));
    expect(checked.readError, isNull);
    expect(checked.missingFields, isNot(contains(AudioField.artwork)));
    expect(checked.artworkPath, track.artworkPath);
    expect(checked.artworkSha256, 'original-hash');
  });

  test('decode failures remain separate from truly absent tags', () async {
    final file = await File('${root.path}/bad.cover').writeAsBytes([1, 2, 3]);
    final checked = await validateTrackArtwork(_track(file.path));
    expect(checked.artworkError, contains('无法解码'));
    expect(checked.hasArtwork, isFalse);
    expect(checked.missingFields, isEmpty);
    expect(checked.readError, isNull);
    final absent = await validateTrackArtwork(_track(null));
    expect(absent.artworkError, isNull);
    expect(absent.artworkNeedsCheck, isFalse);
    expect(absent.missingFields, contains(AudioField.artwork));
    final empty = _track(
      null,
      digest: sha256.convert([]).toString(),
    ).withArtworkValidation(valid: false, error: 'Embedded picture is empty');
    expect((await validateTrackArtwork(empty)).missingFields, isEmpty);
    expect(empty.artworkNeedsCheck, isTrue);
  });

  test(
    'valid image decode and byte fingerprint agree, and reread recovers',
    () async {
      final file = await File('${root.path}/good.cover').writeAsBytes(_png);
      final original = _track(
        file.path,
        digest: sha256.convert(_png).toString(),
      );
      final checked = await validateTrackArtwork(original);
      expect(checked.hasArtwork, isTrue);
      expect(checked.artworkError, isNull);
      expect(checked.withInstrumental(true).hasArtwork, isTrue);
      expect(AudioTrack.fromJson(checked.toJson()).hasArtwork, isTrue);
      await file.writeAsBytes([1, 2, 3]);
      final changed = await validateTrackArtwork(checked);
      expect(changed.artworkError, contains('不一致'));
      expect(changed.hasArtwork, isFalse);
      await file.writeAsBytes(_png);
      expect((await validateTrackArtwork(changed)).hasArtwork, isTrue);
    },
  );

  test(
    'startup and refresh invalidate presentation without reading whole library',
    () async {
      final file = await File('${root.path}/good.cover').writeAsBytes(_png);
      final cached = await validateTrackArtwork(_track(file.path));
      await file.delete();
      final controller = testController(
        store: MemoryStore(LibrarySnapshot(tracks: [cached])),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.tracks.single.hasArtwork, isFalse);
      expect(controller.tracks.single.artworkNeedsCheck, isTrue);
      expect(controller.tracks.single.artworkError, isNull);
      expect(controller.tracks.single.readError, isNull);
      controller.reportArtworkFailure(
        cached.id,
        file.path,
        'late image failure',
      );
      expect(controller.tracks.single.artworkError, 'late image failure');
      expect(controller.tracks.single.missingFields, isEmpty);
      await controller.refreshLibrary();
      expect(controller.tracks.single.artworkError, isNull);
      controller.reportArtworkLoaded(cached.id, '/old/cover');
      expect(controller.tracks.single.hasArtwork, isFalse);
      // The mounted image sends this only after a real decoded image frame.
      controller.reportArtworkLoaded(cached.id, file.path);
      expect(controller.tracks.single.hasArtwork, isTrue);
    },
  );

  testWidgets(
    'image error displays failure instead of claiming absence and notifies once',
    (tester) async {
      final errors = <String>[];
      var loaded = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TrackArtwork(
            bytes: Uint8List.fromList([1, 2, 3]),
            onError: errors.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('封面无法显示'), findsOneWidget);
      expect(find.bySemanticsLabel('暂无封面'), findsNothing);
      expect(errors, hasLength(1));
      await tester.pump();
      expect(errors, hasLength(1));
      await tester.runAsync(
        () => precacheImage(
          ResizeImage(
            MemoryImage(_png),
            width:
                (56 *
                        MediaQuery.devicePixelRatioOf(
                          tester.element(find.byType(TrackArtwork)),
                        ))
                    .round(),
          ),
          tester.element(find.byType(TrackArtwork)),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TrackArtwork(
            bytes: _png,
            onError: errors.add,
            onLoaded: () => loaded++,
            validationPending: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('封面无法显示'), findsNothing);
      expect(loaded, 1);
      for (final pending in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: TrackArtwork(
              bytes: _png,
              onLoaded: () => loaded++,
              validationPending: pending,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }
      expect(
        loaded,
        2,
        reason: 'A refreshed visible image can confirm its cached frame again',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
