import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_tag_reader.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/export/mp3_tag_overlay.dart';
import 'package:audio_fixer/core/services/standard_audio_tags.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

bool _has(String program) {
  try {
    return Process.runSync(program, ['-version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Uint8List _png(int red, int green, int blue, {bool corruptPixels = false}) {
  List<int> uint32(int value) =>
      (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
  List<int> chunk(String type, List<int> payload) {
    final data = [...ascii.encode(type), ...payload];
    var crc = 0xffffffff;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
      }
    }
    return [...uint32(payload.length), ...data, ...uint32(crc ^ 0xffffffff)];
  }

  return Uint8List.fromList([
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ...chunk('IHDR', [...uint32(1), ...uint32(1), 8, 2, 0, 0, 0]),
    ...chunk(
      'IDAT',
      corruptPixels
          ? [1, 2, 3, 4]
          : ZLibEncoder().convert([0, red, green, blue]),
    ),
    ...chunk('IEND', []),
  ]);
}

List<int> _frame(String type, List<int> payload, int version) => [
  ...ascii.encode(type),
  if (version == 4) ...[
    for (var i = 3; i >= 0; i--) (payload.length >> (i * 7)) & 127,
  ] else
    ...(ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(),
  0,
  0,
  ...payload,
];

Future<void> _addMp3Frames(File file, List<List<int>> frames) async {
  final bytes = await file.readAsBytes();
  final size = (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
  final additions = frames.expand((frame) => frame).toList();
  final length = size + additions.length;
  await file.writeAsBytes([
    ...bytes.take(6),
    for (var i = 3; i >= 0; i--) (length >> (i * 7)) & 127,
    ...additions,
    ...bytes.skip(10),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ready = _has('ffmpeg') && _has('ffprobe');
  late Directory workspace;
  late Directory fixtures;
  var serial = 0;
  final cover = _png(230, 45, 90);

  Future<AudioTrack> snapshot(File source) async {
    final track = await readTrackTags(
      AudioTrack(
        id: 'snapshot_${serial++}',
        fileName: p.basename(source.path),
        localPath: source.path,
        sizeBytes: await source.length(),
        importedAt: DateTime(2026),
      ),
      source.path,
      p.join(workspace.path, 'covers'),
    );
    expect(track.readError, isNull);
    return track;
  }

  Future<String> ffmpegHash(File file, bool decoded) async {
    final result = await Process.run('ffmpeg', [
      '-nostdin',
      '-v',
      'error',
      '-xerror',
      '-i',
      file.path,
      '-map',
      '0:a:0',
      '-c:a',
      decoded ? 'pcm_s32le' : 'copy',
      '-f',
      'hash',
      '-hash',
      'sha256',
      '-',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (result.stdout as String).trim();
  }

  Future<void> compareAudio(File source, File output) async {
    expect(await ffmpegHash(output, false), await ffmpegHash(source, false));
    expect(await ffmpegHash(output, true), await ffmpegHash(source, true));
  }

  File output(String extension) =>
      File(p.join(workspace.path, 'result_${serial++}.$extension'));

  group('explicit metadata repair roundtrips', () {
    setUpAll(() async {
      workspace = await Directory('build/test_samples').createTemp('repair_');
      fixtures = Directory(p.join(workspace.path, 'fixtures'));
      final generated = await Process.run('python3', [
        'tool/generate_audio_fixtures.py',
        '--output',
        fixtures.path,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
    });
    tearDownAll(() async {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    });

    for (final extension in ['mp3', 'flac', 'm4a']) {
      test(
        '$extension replaces every selected common tag and front cover',
        () async {
          final source = File(
            p.join(fixtures.path, 'cover_$extension.$extension'),
          );
          final before = sha256.convert(await source.readAsBytes());
          final expected = await snapshot(source);
          final destination = output(extension);
          final values = <AudioField, String>{
            AudioField.title: '修复后的歌名',
            AudioField.artist: 'Corrected artist',
            AudioField.album: 'Corrected album',
            AudioField.albumArtist: 'Album artist',
            AudioField.year: '2026',
            AudioField.genre: 'Jazz',
            AudioField.trackNumber: '4',
            AudioField.trackTotal: '14',
            AudioField.discNumber: '2',
            AudioField.discTotal: '3',
            AudioField.composer: 'Composer 姓名',
            AudioField.comment: 'Local repair note',
            AudioField.lyrics: '[00:00.00]Repaired lyrics',
            AudioField.artwork: 'offline:replacement',
          };
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: destination.path,
            extension: extension,
            values: values,
            replaceFields: values.keys.toSet(),
            artwork: cover,
            expectedTrack: expected,
          );
          final actual = readStandardAudioTags(destination);
          for (final entry in values.entries) {
            if (entry.key != AudioField.artwork) {
              expect(
                actual.valueOf(entry.key),
                entry.value,
                reason: entry.key.name,
              );
            }
          }
          final pictures = readMetadata(destination, getImage: true).pictures;
          expect(sha256.convert(pictures.single.bytes), sha256.convert(cover));
          expect(sha256.convert(await source.readAsBytes()), before);
          await compareAudio(source, destination);
        },
      );

      test(
        '$extension changing only artist preserves all other common fields',
        () async {
          final source = File(
            p.join(fixtures.path, 'cover_$extension.$extension'),
          );
          final before = readStandardAudioTags(source);
          final destination = output(extension);
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: destination.path,
            extension: extension,
            values: {AudioField.artist: 'One selected repair'},
            replaceFields: {AudioField.artist},
            expectedTrack: await snapshot(source),
          );
          final after = readStandardAudioTags(destination);
          for (final field in AudioField.values) {
            if (field != AudioField.artist && field != AudioField.artwork) {
              expect(
                after.valueOf(field),
                before.valueOf(field),
                reason: field.name,
              );
            }
          }
          expect(
            sha256.convert(
              readMetadata(destination, getImage: true).pictures.single.bytes,
            ),
            sha256.convert(
              readMetadata(source, getImage: true).pictures.single.bytes,
            ),
          );
        },
      );

      test(
        '$extension edits track and disc number while retaining totals',
        () async {
          final source = File(
            p.join(fixtures.path, 'unicode_$extension.$extension'),
          );
          final destination = output(extension);
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: destination.path,
            extension: extension,
            values: {AudioField.trackNumber: '2', AudioField.discNumber: '2'},
            replaceFields: {AudioField.trackNumber, AudioField.discNumber},
            expectedTrack: await snapshot(source),
          );
          final after = readStandardAudioTags(destination);
          expect(after.trackNumber, 2);
          expect(after.trackTotal, 12);
          expect(after.discNumber, 2);
          expect(after.discTotal, 2);
        },
      );

      test(
        '$extension edits only totals while preserving track and disc numbers',
        () async {
          final source = File(
            p.join(fixtures.path, 'unicode_$extension.$extension'),
          );
          final destination = output(extension);
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: destination.path,
            extension: extension,
            values: {AudioField.trackTotal: '15', AudioField.discTotal: '3'},
            replaceFields: {AudioField.trackTotal, AudioField.discTotal},
            expectedTrack: await snapshot(source),
          );
          final after = readStandardAudioTags(destination);
          expect(after.trackNumber, 3);
          expect(after.trackTotal, 15);
          expect(after.discNumber, 1);
          expect(after.discTotal, 3);
        },
      );

      test(
        '$extension fills absent totals beside existing track and disc numbers',
        () async {
          final source = File(
            p.join(fixtures.path, 'plain_$extension.$extension'),
          );
          final numbered = output(extension);
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: numbered.path,
            extension: extension,
            values: {AudioField.trackNumber: '3', AudioField.discNumber: '1'},
          );
          final destination = output(extension);
          await prepareTaggedCopy(
            sourcePath: numbered.path,
            outputPath: destination.path,
            extension: extension,
            values: {AudioField.trackTotal: '15', AudioField.discTotal: '3'},
          );
          final after = readStandardAudioTags(destination);
          expect(after.trackNumber, 3);
          expect(after.trackTotal, 15);
          expect(after.discNumber, 1);
          expect(after.discTotal, 3);
        },
      );

      test(
        '$extension adds missing optional tags with default fill semantics',
        () async {
          final source = File(
            p.join(fixtures.path, 'plain_$extension.$extension'),
          );
          final destination = output(extension);
          const values = {
            AudioField.albumArtist: 'Album artist',
            AudioField.year: '2026',
            AudioField.genre: 'Jazz',
            AudioField.trackNumber: '1',
            AudioField.trackTotal: '12',
            AudioField.discNumber: '1',
            AudioField.discTotal: '2',
            AudioField.composer: 'Composer',
            AudioField.comment: 'A note',
          };
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: destination.path,
            extension: extension,
            values: values,
          );
          final after = readStandardAudioTags(destination);
          for (final entry in values.entries) {
            expect(after.valueOf(entry.key), entry.value);
          }
          await compareAudio(source, destination);
        },
      );

      test(
        '$extension requires per-field replacement intent and reviewed snapshot',
        () async {
          final source = File(
            p.join(fixtures.path, 'cover_$extension.$extension'),
          );
          for (final replaces in <Set<AudioField>>[
            {},
            {AudioField.artist},
          ]) {
            final destination = output(extension);
            await expectLater(
              prepareTaggedCopy(
                sourcePath: source.path,
                outputPath: destination.path,
                extension: extension,
                values: {
                  AudioField.title: 'New title',
                  AudioField.artist: 'New artist',
                },
                replaceFields: replaces,
                expectedTrack: await snapshot(source),
              ),
              throwsA(isA<ExportException>()),
            );
            expect(await destination.exists(), isFalse);
          }
          await expectLater(
            prepareTaggedCopy(
              sourcePath: source.path,
              outputPath: output(extension).path,
              extension: extension,
              values: {AudioField.title: 'New title'},
              replaceFields: {AudioField.title},
            ),
            throwsA(isA<ExportException>()),
          );
        },
      );

      test(
        '$extension rejects stale edited metadata and stale cover hashes',
        () async {
          final source = File(
            p.join(fixtures.path, 'cover_$extension.$extension'),
          );
          final current = await snapshot(source);
          for (final (expected, values) in [
            (
              current.withDetails(
                title: current.title,
                artist: current.artist,
                album: current.album,
                year: 1999,
                durationMs: current.durationMs,
                lyrics: current.lyrics,
                artworkPath: current.artworkPath,
              ),
              {AudioField.year: '2026'},
            ),
            (
              current.withDetails(
                title: current.title,
                artist: current.artist,
                album: current.album,
                year: current.year,
                durationMs: current.durationMs,
                lyrics: 'Old lyrics',
                artworkPath: current.artworkPath,
              ),
              {AudioField.lyrics: 'New lyrics'},
            ),
            (
              current.withDetails(
                title: current.title,
                artist: current.artist,
                album: current.album,
                year: current.year,
                durationMs: current.durationMs,
                lyrics: current.lyrics,
                artworkPath: current.artworkPath,
                artworkSha256: 'stale',
              ),
              {AudioField.artwork: 'offline:new'},
            ),
          ]) {
            final destination = output(extension);
            await expectLater(
              prepareTaggedCopy(
                sourcePath: source.path,
                outputPath: destination.path,
                extension: extension,
                values: values,
                replaceFields: values.keys.toSet(),
                expectedTrack: expected,
                artwork: cover,
              ),
              throwsA(isA<ExportException>()),
            );
            expect(await destination.exists(), isFalse);
          }
        },
      );

      test(
        '$extension rejects missing or corrupt selected cover before writing',
        () async {
          final source = File(
            p.join(fixtures.path, 'plain_$extension.$extension'),
          );
          for (final bytes in <Uint8List?>[
            null,
            Uint8List.fromList([137, 80, 78, 71]),
            _png(1, 2, 3, corruptPixels: true),
            Uint8List.fromList([...cover.take(cover.length - 4), 0, 0, 0, 0]),
          ]) {
            final destination = output(extension);
            await expectLater(
              prepareTaggedCopy(
                sourcePath: source.path,
                outputPath: destination.path,
                extension: extension,
                values: {AudioField.artwork: 'offline:bad'},
                artwork: bytes,
              ),
              throwsA(isA<ExportException>()),
            );
            expect(await destination.exists(), isFalse);
          }
        },
      );
    }

    for (final fixture in [
      'id3v24_mp3.mp3',
      'id3v1_tail_mp3.mp3',
      'id3v1_only_mp3.mp3',
    ]) {
      test(
        '$fixture permits reviewed replacements and preserves its legacy tail',
        () async {
          final source = File(p.join(fixtures.path, fixture));
          final bytes = await source.readAsBytes();
          final destination = output('mp3');
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: destination.path,
            extension: 'mp3',
            values: {
              AudioField.title: 'Repaired legacy title',
              AudioField.comment: 'Repaired comment',
            },
            replaceFields: {AudioField.title, AudioField.comment},
            expectedTrack: await snapshot(source),
          );
          final after = await destination.readAsBytes();
          if (ascii.decode(
                bytes.sublist(bytes.length - 128, bytes.length - 125),
                allowInvalid: true,
              ) ==
              'TAG') {
            expect(
              after.sublist(after.length - 128),
              bytes.sublist(bytes.length - 128),
            );
          }
          await compareAudio(source, destination);
        },
      );
    }

    test('MP3 repair retains unknown/private frames, described comments, and back cover', () async {
      final source = await File(p.join(fixtures.path, 'cover_mp3.mp3'))
          .copy(p.join(workspace.path, 'private.mp3'));
      final unknown = _frame('TXXX', [
        0,
        ...ascii.encode('PRIVATE_SETTING'),
        0,
        ...ascii.encode('exact private value'),
      ], 3);
      final private = _frame('PRIV', [
        ...ascii.encode('example.test'),
        0,
        1,
        2,
        3,
        254,
      ], 3);
      final described = _frame('COMM', [
        0,
        ...ascii.encode('eng'),
        ...ascii.encode('iTunNORM'),
        0,
        ...ascii.encode('keep normalization'),
      ], 3);
      final back = _frame('APIC', [
        0,
        ...ascii.encode('image/png'),
        0,
        4,
        0,
        ..._png(10, 200, 30),
      ], 3);
      await _addMp3Frames(source, [unknown, private, described, back]);
      final destination = output('mp3');
      await prepareTaggedCopy(
        sourcePath: source.path,
        outputPath: destination.path,
        extension: 'mp3',
        values: {
          AudioField.artwork: 'offline:front',
          AudioField.comment: 'New standard comment',
        },
        replaceFields: {AudioField.artwork, AudioField.comment},
        artwork: cover,
        expectedTrack: await snapshot(source),
      );
      final bytes = await destination.readAsBytes();
      for (final frame in [unknown, private, described, back]) {
        expect(_containsBytes(bytes, frame), isTrue);
      }
      final pictures = readMetadata(destination, getImage: true).pictures;
      expect(pictures.length, 2);
      expect(
        sha256.convert(
          pictures
              .singleWhere((p) => p.pictureType == PictureType.coverFront)
              .bytes,
        ),
        sha256.convert(cover),
      );
      await compareAudio(source, destination);
    });

    test('MP3 comment replacement removes the legacy TXXX alias', () async {
      final source = await File(p.join(fixtures.path, 'unicode_mp3.mp3'))
          .copy(p.join(workspace.path, 'comment_alias.mp3'));
      final alias = _frame('TXXX', [
        0,
        ...ascii.encode('COMMENT'),
        0,
        ...ascii.encode('Old note'),
      ], 3);
      await _addMp3Frames(source, [alias]);
      expect(readStandardAudioTags(source).comment, 'Old note');
      final destination = output('mp3');
      await prepareTaggedCopy(
        sourcePath: source.path,
        outputPath: destination.path,
        extension: 'mp3',
        values: {AudioField.comment: 'New note'},
        replaceFields: {AudioField.comment},
        expectedTrack: await snapshot(source),
      );
      expect(readStandardAudioTags(destination).comment, 'New note');
      expect(_containsBytes(await destination.readAsBytes(), alias), isFalse);
    });

    test(
      'MP3 overlay also requires explicit replacement for legacy ID3v1 values',
      () async {
        final source = await File(p.join(fixtures.path, 'id3v1_only_mp3.mp3'))
            .copy(p.join(workspace.path, 'legacy_default.mp3'));
        final before = await source.readAsBytes();
        await expectLater(
          addMissingMp3Tags(
            source,
            {AudioField.title: 'Must not overwrite'},
            null,
            null,
          ),
          throwsFormatException,
        );
        expect(await source.readAsBytes(), before);
      },
    );

    for (final field in [AudioField.lyrics, AudioField.comment]) {
      test(
        'MP3 refuses ambiguous multilingual ${field.name} without removing variants',
        () async {
          final source = await File(p.join(fixtures.path, 'plain_mp3.mp3'))
              .copy(p.join(workspace.path, 'multiple_${field.name}.mp3'));
          final id = field == AudioField.lyrics ? 'USLT' : 'COMM';
          await _addMp3Frames(source, [
            _frame(id, [
              0,
              ...ascii.encode('jpn'),
              0,
              ...ascii.encode('Other language'),
            ], 3),
            _frame(id, [
              0,
              ...ascii.encode('eng'),
              0,
              ...ascii.encode('Displayed value'),
            ], 3),
          ]);
          final before = await source.readAsBytes();
          final destination = output('mp3');
          await expectLater(
            prepareTaggedCopy(
              sourcePath: source.path,
              outputPath: destination.path,
              extension: 'mp3',
              values: {field: 'Replacement'},
              replaceFields: {field},
              expectedTrack: await snapshot(source),
            ),
            throwsFormatException,
          );
          expect(await destination.exists(), isFalse);
          expect(await source.readAsBytes(), before);
        },
      );
    }

    test('MP3 refuses a separately described lyric translation', () async {
      final source = await File(p.join(fixtures.path, 'plain_mp3.mp3'))
          .copy(p.join(workspace.path, 'described_lyrics.mp3'));
      await _addMp3Frames(source, [
        _frame('USLT', [
          0,
          ...ascii.encode('jpn'),
          ...ascii.encode('Translation'),
          0,
          ...ascii.encode('Translated lyrics'),
        ], 3),
      ]);
      final destination = output('mp3');
      await expectLater(
        prepareTaggedCopy(
          sourcePath: source.path,
          outputPath: destination.path,
          extension: 'mp3',
          values: {AudioField.lyrics: 'Replacement'},
          replaceFields: {AudioField.lyrics},
          expectedTrack: await snapshot(source),
        ),
        throwsFormatException,
      );
      expect(await destination.exists(), isFalse);
    });

    test(
      'export service calls only the injected scoped local-cover loader',
      () async {
        const channel = MethodChannel('audio_fixer/replacement_fixture');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final source = File(p.join(fixtures.path, 'cover_mp3.mp3'));
        final track = await snapshot(source);
        var loads = 0;
        final exporter = SafeAudioCopyExporter(
          () async => workspace,
          channel: channel,
          localArtworkLoader: (uri) async {
            expect(uri, 'file:///scoped/cover.png');
            loads++;
            return cover;
          },
        );
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'exportAudioCopy');
          final file = File((call.arguments as Map)['path'] as String);
          expect(
            sha256.convert(
              readMetadata(file, getImage: true).pictures.single.bytes,
            ),
            sha256.convert(cover),
          );
          return 'content://test/exported';
        });
        const choice = FieldSuggestion(
          field: AudioField.artwork,
          value: 'file:///scoped/cover.png',
          source: 'Manual',
          replaceExisting: true,
        );
        expect(
          await exporter.export(track, [choice]),
          'content://test/exported',
        );
        expect(loads, 1);
        final noLoader = SafeAudioCopyExporter(
          () async => workspace,
          channel: channel,
        );
        await expectLater(
          noLoader.export(track, [choice]),
          throwsA(isA<ExportException>()),
        );
      },
    );
  }, skip: ready ? false : 'Requires offline ffmpeg/ffprobe fixtures');
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
