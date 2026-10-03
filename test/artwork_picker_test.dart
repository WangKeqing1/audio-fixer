import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_fixer/core/services/artwork_picker.dart';
import 'package:flutter_test/flutter_test.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAD0lEQVR4nGNgaGgAIQgFABoOBAH77Fo+AAAAAElFTkSuQmCC',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalArtworkStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('audio-cover-test-');
    store = LocalArtworkStore(() async => root);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'chosen cover is immutable, scoped, content-addressed and deduplicated',
    () async {
      final first = await store.importArtwork(Stream.value(_png));
      final again = await store.importArtwork(
        Stream.fromIterable([_png.sublist(0, 10), _png.sublist(10)]),
      );
      expect(again, first);
      expect(await store.read(first), orderedEquals(_png));
      expect(Uri.parse(first).path, contains('/manual_artwork/'));
      expect(await Directory('${root.path}/manual_artwork').list().length, 1);
    },
  );
  test('cancel does not create a review asset', () async {
    final picker = SystemArtworkPicker(store, chooseFile: () async => null);
    expect(await picker.pickArtwork(), isNull);
    expect(await Directory('${root.path}/manual_artwork').exists(), isFalse);
  });
  test('invalid, empty and oversized images are rejected', () async {
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([1, 2, 3]),
      Uint8List.fromList([0xff, 0xd8, 0xff, 0]),
      Uint8List(maximumArtworkBytes + 1),
    ]) {
      await expectLater(
        store.importArtwork(Stream.value(bytes)),
        throwsA(isA<ArtworkException>()),
      );
    }
    expect(await Directory('${root.path}/manual_artwork').exists(), isFalse);
  });
  test(
    'read rejects arbitrary file, remote URI, traversal and symlink',
    () async {
      final selected = await store.importArtwork(Stream.value(_png));
      final outside = File('${root.path}/outside.png');
      await outside.writeAsBytes(_png);
      for (final value in [
        outside.uri.toString(),
        'https://example.com/cover.png',
        'file://${Uri.parse(selected).path}?x=1',
        Uri.file('${root.path}/manual_artwork/../outside.png').toString(),
      ]) {
        await expectLater(store.read(value), throwsA(isA<ArtworkException>()));
      }
      final file = File.fromUri(Uri.parse(selected));
      await file.delete();
      await Link(file.path).create(outside.path);
      await expectLater(store.read(selected), throwsA(isA<ArtworkException>()));
      expect(await outside.readAsBytes(), orderedEquals(_png));
    },
  );
  test('changed asset and preexisting hash collision never overwrite accepted cover', () async {
    final selected = await store.importArtwork(Stream.value(_png));
    final file = File.fromUri(Uri.parse(selected));
    await file.writeAsBytes([0, 1, 2]);
    await expectLater(store.read(selected), throwsA(isA<ArtworkException>()));
    await expectLater(
      store.importArtwork(Stream.value(_png)),
      throwsA(isA<ArtworkException>()),
    );
    expect(await file.readAsBytes(), [0, 1, 2]);
  });
  test(
    'manual artwork directory symlink outside app support fails closed',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'outside-cover-test-',
      );
      try {
        await Link('${root.path}/manual_artwork').create(outside.path);
        await expectLater(
          store.importArtwork(Stream.value(_png)),
          throwsA(isA<ArtworkException>()),
        );
        expect(await outside.list().length, 0);
      } finally {
        await outside.delete(recursive: true);
      }
    },
  );
}
