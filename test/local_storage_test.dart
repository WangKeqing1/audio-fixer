import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/audio_importer.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/fakes.dart';

List<int> _uint32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
List<int> _chunk(String id, List<int> data) => [
  ...ascii.encode(id),
  ..._uint32(data.length),
  ...data,
  if (data.length.isOdd) 0,
];

List<int> _wavFixture() {
  final format = ByteData(16)
    ..setUint16(0, 1, Endian.little)
    ..setUint16(2, 1, Endian.little)
    ..setUint32(4, 8000, Endian.little)
    ..setUint32(8, 16000, Endian.little)
    ..setUint16(12, 2, Endian.little)
    ..setUint16(14, 16, Endian.little);
  final body = [
    ...ascii.encode('WAVE'),
    ..._chunk('fmt ', format.buffer.asUint8List()),
    ..._chunk('LIST', [
      ...ascii.encode('INFO'),
      ..._chunk('INAM', [...ascii.encode('Fixture song'), 0]),
      ..._chunk('IART', [...ascii.encode('Fixture artist'), 0]),
    ]),
    ..._chunk('data', List.filled(16000, 0)),
  ];
  return [...ascii.encode('RIFF'), ..._uint32(body.length), ...body];
}

class _FixturePicker implements AudioPicker {
  @override
  Future<List<AudioSelection>> pick() async => [
    AudioSelection(
      name: 'fixture.wav',
      openRead: () => Stream.value(_wavFixture()),
    ),
  ];
}

void main() {
  late Directory temporary;
  setUp(
    () async =>
        temporary = await Directory.systemTemp.createTemp('audio-fixer-test-'),
  );
  tearDown(() async => temporary.delete(recursive: true));

  test('real WAV import reads tags, persists private copy and deduplicates by content', () async {
    final original = File(p.join(temporary.path, 'original.wav'));
    final bytes = _wavFixture();
    await original.writeAsBytes(bytes);
    final root = Directory(p.join(temporary.path, 'app'));
    final importer = LocalAudioImporter(() async => root);
    final first = await importer.import(
      AudioSelection(name: 'original.WAV', openRead: original.openRead),
    );
    final second = await importer.import(
      AudioSelection(name: 'renamed.mp3', openRead: original.openRead),
    );
    expect(first.readError, isNull);
    expect(first.title, 'Fixture song');
    expect(first.artist, 'Fixture artist');
    expect(first.durationMs, 1000);
    expect(first.missingFields, {
      AudioField.album,
      AudioField.lyrics,
      AudioField.artwork,
    });
    expect(first.id, second.id);
    expect(first.localPath, second.localPath);
    expect(await File(first.localPath).readAsBytes(), bytes);
    expect(await original.readAsBytes(), bytes);
    expect(await Directory(p.join(root.path, 'audio')).list().length, 1);
  });

  test('malformed audio is retained with explicit read error; empty files are rejected', () async {
    final importer = LocalAudioImporter(() async => temporary);
    final track = await importer.import(
      AudioSelection(
        name: 'broken.mp3',
        openRead: () => Stream.value([1, 2, 3]),
      ),
    );
    expect(track.readError, isNotNull);
    expect(track.needsCompletion, isFalse);
    await expectLater(
      importer.import(
        AudioSelection(name: 'empty.mp3', openRead: () => const Stream.empty()),
      ),
      throwsFormatException,
    );
  });

  test('Android picker Uint8List stream can be saved and read', () async {
    final bytes = Uint8List.fromList(_wavFixture());
    final track = await LocalAudioImporter(() async => temporary).import(
      AudioSelection(
        name: 'android-picker.wav',
        openRead: () => Stream<Uint8List>.value(bytes),
      ),
    );
    expect(track.readError, isNull);
    expect(track.title, 'Fixture song');
    expect(await File(track.localPath).readAsBytes(), bytes);
  });

  test(
    'catalog supports repeated atomic saves and restores settings and tracks',
    () async {
      final store = JsonLibraryStore(() async => temporary);
      await store.save(const LibrarySnapshot());
      await store.save(
        LibrarySnapshot(
          tracks: [fixtureTrack()],
          settings: const AppSettings(theme: AppTheme.dark),
        ),
      );
      final loaded = await JsonLibraryStore(() async => temporary).load();
      expect(loaded.tracks.single.title, '测试歌曲');
      expect(loaded.settings.theme, AppTheme.dark);
      expect(
        await File(p.join(temporary.path, 'library.json.tmp')).exists(),
        isFalse,
      );
    },
  );

  test('corrupt catalog fails visibly and remains intact', () async {
    final file = File(p.join(temporary.path, 'library.json'));
    await file.writeAsString('broken');
    await expectLater(
      JsonLibraryStore(() async => temporary).load(),
      throwsFormatException,
    );
    expect(await file.readAsString(), 'broken');
  });

  test('catalog save failure rolls back newly copied private audio', () async {
    final store = MemoryStore()..failSave = true;
    final controller = LibraryController(
      store: store,
      picker: _FixturePicker(),
      importer: LocalAudioImporter(() async => temporary),
      completion: CompletionService(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.importAudio();
    expect(controller.tracks, isEmpty);
    expect(await Directory(p.join(temporary.path, 'audio')).list().length, 0);
  });

  test('startup removes interrupted and orphaned copies while preserving referenced and unknown files', () async {
    final importer = LocalAudioImporter(() async => temporary);
    final kept = await importer.import(
      AudioSelection(
        name: 'kept.wav',
        openRead: () => Stream.value(_wavFixture()),
      ),
    );
    final orphan = await importer.import(
      AudioSelection(
        name: 'orphan.mp3',
        openRead: () => Stream.value([1, 2, 3]),
      ),
    );
    final audioDirectory = Directory(p.join(temporary.path, 'audio'));
    final unrelated = File(p.join(audioDirectory.path, 'keep.txt'));
    await unrelated.writeAsString('preserve');
    final artworkDirectory = Directory(p.join(temporary.path, 'artwork'));
    await artworkDirectory.create();
    final retainedCovers = [
      File(p.join(artworkDirectory.path, '${kept.id}.cover')),
      File(p.join(artworkDirectory.path, '${kept.id}.${'a' * 64}.cover')),
      File(p.join(artworkDirectory.path, '${kept.id}.${'b' * 64}.cover')),
      File(p.join(artworkDirectory.path, '${orphan.id}.unknown.cover')),
    ];
    final orphanedCovers = [
      File(p.join(artworkDirectory.path, '${orphan.id}.cover')),
      File(p.join(artworkDirectory.path, '${orphan.id}.${'c' * 64}.cover')),
    ];
    for (final file in [...retainedCovers, ...orphanedCovers]) {
      await file.writeAsBytes([1, 2, 3]);
    }
    final interrupted = await audioDirectory.createTemp('import-');
    await File(p.join(interrupted.path, 'source.mp3')).writeAsBytes([4, 5, 6]);
    final controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [kept])),
      picker: _FixturePicker(),
      importer: importer,
      completion: CompletionService(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(await File(kept.localPath).exists(), isTrue);
    expect(await File(orphan.localPath).exists(), isFalse);
    expect(await unrelated.readAsString(), 'preserve');
    expect(await interrupted.exists(), isFalse);
    for (final file in retainedCovers) {
      expect(await file.exists(), isTrue);
    }
    for (final file in orphanedCovers) {
      expect(await file.exists(), isFalse);
    }
  });
}
