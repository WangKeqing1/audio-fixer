import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_importer.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// Integration cases deliberately use actual encoded media and an independent
// decoder. They stay offline and never include user media in the repository.
// Missing optional host tools skip only this suite, with the reason shown.
bool _available(String program) {
  try {
    return Process.runSync(program, ['-version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

String? _python() {
  for (final candidate in ['python3', 'python']) {
    try {
      if (Process.runSync(candidate, ['--version']).exitCode == 0) {
        return candidate;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<Map<String, dynamic>> _validate(
  String python,
  List<String> arguments, {
  Map<String, String> expectedTags = const {},
  String? expectedCoverSha256,
}) async {
  File? expectations;
  if (expectedTags.isNotEmpty) {
    expectations = File('${arguments[2]}.expected_tags.json');
    await expectations.writeAsString(jsonEncode(expectedTags));
  }
  late ProcessResult result;
  try {
    result = await Process.run(python, [
      'tool/validate_audio.py',
      ...arguments,
      if (expectations != null) ...['--expect-tags', expectations.path],
      if (expectedCoverSha256 != null) ...[
        '--expect-cover-sha256',
        expectedCoverSha256,
      ],
    ]);
  } finally {
    if (expectations != null) await expectations.delete();
  }
  final report = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
  expect(report['passed'], isTrue);
  return report;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final python = _python();
  final ready = python != null && _available('ffmpeg') && _available('ffprobe');
  final skip = ready
      ? false
      : 'Offline media integration needs Python 3, ffmpeg, and ffprobe';
  late Directory workspace;
  late Directory fixtures;
  late LocalAudioImporter importer;
  late Map<String, dynamic> manifest;

  group('offline encoded audio fixtures', () {
    setUpAll(() async {
      final root = Directory('build/test_samples/flutter_runs');
      await root.create(recursive: true);
      workspace = await root.createTemp('run_');
      fixtures = Directory(p.join(workspace.path, 'generated'));
      final result = await Process.run(python!, [
        'tool/generate_audio_fixtures.py',
        '--output',
        fixtures.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
      manifest = jsonDecode(
        await File(p.join(fixtures.path, 'manifest.json')).readAsString(),
      ) as Map<String, dynamic>;
      importer = LocalAudioImporter(
        () async => Directory(p.join(workspace.path, 'library')),
      );
    });

    Future<AudioTrack> import(String name) => importer.import(
      AudioSelection(
        name: name,
        openRead: File(p.join(fixtures.path, name)).openRead,
      ),
    );

    for (final extension in supportedAudioExtensions) {
      test(
        'reads $extension Unicode tags and preserves the complete input',
        () async {
          final name = 'unicode_$extension.$extension';
          final source = File(p.join(fixtures.path, name));
          final before = await _hash(source);
          final track = await import(name);
          expect(track.readError, isNull);
          expect(track.title, manifest['metadata']['title']);
          expect(track.artist, manifest['metadata']['artist']);
          expect(track.album, manifest['metadata']['album']);
          expect(track.durationMs, inInclusiveRange(1000, 1500));
          expect(await _hash(File(track.localPath)), before);
          expect(await _hash(source), before);
          await _validate(python!, ['compare', source.path, track.localPath]);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test('reads untagged $extension without inventing metadata', () async {
        final track = await import('plain_$extension.$extension');
        expect(track.readError, isNull);
        expect(hasText(track.title), isFalse);
        expect(hasText(track.artist), isFalse);
        expect(hasText(track.album), isFalse);
        expect(hasText(track.lyrics), isFalse);
        expect(track.artworkPath, isNull);
        expect(track.needsCompletion, isTrue);
      });
    }

    test('existing MP3 TXXX lyrics are recognized and never offered for completion', () async {
      final track = await import('unicode_mp3.mp3');
      expect(track.readError, isNull);
      expect(track.lyrics, manifest['metadata']['lyrics']);
      expect(track.missingFields, isNot(contains(AudioField.lyrics)));
      final blank = await import('blank_fields_mp3.mp3');
      expect(blank.readError, isNull);
      expect(hasText(blank.lyrics), isFalse);
      expect(blank.missingFields, contains(AudioField.lyrics));
    });

    test('legacy Latin-1 WAV INFO remains readable', () async {
      final track = await import('latin1_wav.wav');
      expect(track.readError, isNull);
      expect(track.title, 'Café');
      expect(track.artist, 'François');
      expect(track.album, 'Année');
    });

    test(
      'same bytes with uppercase/Unicode renamed filename deduplicate',
      () async {
        final first = await import('unicode_mp3.mp3');
        final second = await import('重命名 – duplicate.MP3');
        expect(second.id, first.id);
        expect(second.localPath, first.localPath);
      },
    );

    test('container bytes win over a misleading supported extension', () async {
      final wav = await import('unicode_wav.wav');
      final disguised = await import('wav_disguised_as_mp3.mp3');
      expect(disguised.readError, isNull);
      expect(disguised.title, wav.title);
      expect(disguised.id, wav.id);
    });

    for (final extension in ['mp3', 'flac', 'm4a']) {
      test('extracts the exact embedded $extension cover', () async {
        final track = await import('cover_$extension.$extension');
        expect(track.readError, isNull);
        expect(track.artworkPath, isNotNull);
        expect(
          await _hash(File(track.artworkPath!)),
          await _hash(File(p.join(fixtures.path, 'synthetic_cover.png'))),
        );
      });

      test(
        'fills $extension tags and cover in a fully decodable exact-audio copy',
        () async {
          final source = File(
            p.join(fixtures.path, 'plain_$extension.$extension'),
          );
          final before = await _hash(source);
          final output = File(
            p.join(workspace.path, 'exports', 'filled.$extension'),
          );
          final cover = await File(p.join(fixtures.path, 'synthetic_cover.png'))
              .readAsBytes();
          final tags = manifest['metadata'] as Map<String, dynamic>;
          final values = <AudioField, String>{
            AudioField.title: tags['title'] as String,
            AudioField.artist: tags['artist'] as String,
            AudioField.album: tags['album'] as String,
            AudioField.lyrics: tags['lyrics'] as String,
            AudioField.artwork: 'offline:synthetic-cover',
          };
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: output.path,
            extension: extension,
            values: values,
            artwork: cover,
          );
          expect(await _hash(source), before);
          final result = readMetadata(output, getImage: true);
          expect(result.title, tags['title']);
          expect(result.artist, tags['artist']);
          expect(result.album, tags['album']);
          expect(result.lyrics, tags['lyrics']);
          expect(
            sha256.convert(result.pictures.single.bytes),
            sha256.convert(cover),
          );
          await _validate(
            python!,
            ['compare', source.path, output.path],
            expectedCoverSha256: sha256.convert(cover).toString(),
            expectedTags: {
              for (final entry in values.entries)
                if (entry.key != AudioField.artwork)
                  entry.key.name: entry.value,
            },
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'fills missing $extension lyrics while preserving existing Unicode tags and cover',
        () async {
          final source = File(
            p.join(fixtures.path, 'cover_without_lyrics_$extension.$extension'),
          );
          final before = await _hash(source);
          final output = File(
            p.join(workspace.path, 'exports', 'lyrics.$extension'),
          );
          final original = readMetadata(source, getImage: true);
          const lyrics = '[00:00.00] Offline synthetic test\n[00:00.50]音声保持';
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: output.path,
            extension: extension,
            values: {AudioField.lyrics: lyrics},
          );
          final result = readMetadata(output, getImage: true);
          expect(result.title, original.title);
          expect(result.artist, original.artist);
          expect(result.album, original.album);
          expect(result.year, original.year);
          expect(result.lyrics, lyrics);
          expect(
            sha256.convert(result.pictures.single.bytes),
            sha256.convert(original.pictures.single.bytes),
          );
          expect(await _hash(source), before);
          await _validate(
            python!,
            ['compare', source.path, output.path],
            expectedTags: {'lyrics': lyrics},
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }

    for (final extension in ['mp3', 'flac', 'm4a']) {
      test(
        'fills blank $extension fields without losing unrelated metadata or cover',
        () async {
          final source = File(
            p.join(fixtures.path, 'blank_fields_$extension.$extension'),
          );
          final before = await _hash(source);
          final output = File(
            p.join(workspace.path, 'exports', 'blank_filled.$extension'),
          );
          final original = readMetadata(source, getImage: true);
          final values = <AudioField, String>{
            AudioField.title: 'Filled synthetic title',
            AudioField.artist: 'Filled synthetic artist',
            AudioField.album: 'Filled synthetic album',
            AudioField.lyrics: 'Filled synthetic lyrics',
          };
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: output.path,
            extension: extension,
            values: values,
          );
          final result = readMetadata(output, getImage: true);
          expect(result.title, values[AudioField.title]);
          expect(result.artist, values[AudioField.artist]);
          expect(result.album, values[AudioField.album]);
          expect(result.lyrics, values[AudioField.lyrics]);
          expect(
            sha256.convert(result.pictures.single.bytes),
            sha256.convert(original.pictures.single.bytes),
          );
          expect(await _hash(source), before);
          await _validate(
            python!,
            ['compare', source.path, output.path, '--allow-blank-tag-fill'],
            expectedTags: {
              for (final entry in values.entries) entry.key.name: entry.value,
            },
          );
        },
      );
    }

    test(
      'large MP3 tag growth preserves the encoded and decoded audio',
      () async {
        final source = File(p.join(fixtures.path, 'large_id3_mp3.mp3'));
        final output = File(p.join(workspace.path, 'exports', 'large_id3.mp3'));
        await prepareTaggedCopy(
          sourcePath: source.path,
          outputPath: output.path,
          extension: 'mp3',
          values: {AudioField.lyrics: '离线 synthetic line\n' * 2000},
        );
        await _validate(
          python!,
          ['compare', source.path, output.path],
          expectedTags: {'lyrics': '离线 synthetic line\n' * 2000},
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    for (final fixture in ['id3v24_mp3.mp3', 'id3v1_tail_mp3.mp3']) {
      test(
        '$fixture tags can be extended without changing decoded audio',
        () async {
          final source = File(p.join(fixtures.path, fixture));
          final output = File(p.join(workspace.path, 'exports', fixture));
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: output.path,
            extension: 'mp3',
            values: {AudioField.lyrics: 'Synthetic fixture only'},
          );
          await _validate(
            python!,
            ['compare', source.path, output.path],
            expectedTags: {'lyrics': 'Synthetic fixture only'},
          );
        },
      );
    }

    for (final fixture in ['raw_no_id3_mp3.mp3', 'id3v1_only_mp3.mp3']) {
      test(
        '$fixture gets modern lyrics without changing existing tags or audio',
        () async {
          final source = File(p.join(fixtures.path, fixture));
          final output = File(p.join(workspace.path, 'exports', fixture));
          final before = await _hash(source);
          final track = await import(fixture);
          expect(track.readError, isNull);
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: output.path,
            extension: 'mp3',
            values: {AudioField.lyrics: 'Synthetic fixture only'},
          );
          expect(await _hash(source), before);
          await _validate(
            python!,
            ['compare', source.path, output.path],
            expectedTags: {'lyrics': 'Synthetic fixture only'},
          );
        },
      );
    }

    test('Opus duration uses the codec granule clock, not the original input sample rate', () async {
      final track = await import('long_opus_44100.opus');
      expect(track.readError, isNull);
      expect(track.durationMs, inInclusiveRange(11500, 12500));
    });

    test(
      'front-loaded M4A movie atom stays decodable after tag growth',
      () async {
        final source = File(p.join(fixtures.path, 'front_moov_m4a.m4a'));
        final output = File(p.join(workspace.path, 'exports', 'faststart.m4a'));
        await prepareTaggedCopy(
          sourcePath: source.path,
          outputPath: output.path,
          extension: 'm4a',
          values: {AudioField.lyrics: 'Offline synthetic line\n' * 2000},
        );
        await _validate(
          python!,
          ['compare', source.path, output.path],
          expectedTags: {'lyrics': 'Offline synthetic line\n' * 2000},
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('malformed and truncated-header audio fails visibly without online requests', () async {
      for (final name in ['malformed.mp3', 'truncated_header.mp3']) {
        final track = await import(name);
        expect(track.readError, isNotNull, reason: name);
        expect(track.needsCompletion, isFalse, reason: name);
        final output = File(p.join(workspace.path, 'exports', name));
        await expectLater(
          prepareTaggedCopy(
            sourcePath: p.join(fixtures.path, name),
            outputPath: output.path,
            extension: 'mp3',
            values: {AudioField.title: 'Synthetic'},
          ),
          throwsA(anything),
        );
        expect(await output.exists(), isFalse);
      }
    });

    test('empty/unsupported inputs are rejected, including valid AIFF outside import scope', () async {
      for (final name in [
        'empty.mp3',
        'unsupported.txt',
        'unicode_aiff.aiff',
      ]) {
        await expectLater(import(name), throwsFormatException, reason: name);
      }
      await _validate(python!, [
        'audit',
        p.join(fixtures.path, 'unicode_aiff.aiff'),
      ]);
    });

    test('read-only formats cannot be exported', () async {
      for (final extension in ['wav', 'ogg', 'opus', 'aiff']) {
        final source = File(
          p.join(fixtures.path, 'plain_$extension.$extension'),
        );
        final before = await _hash(source);
        final output = File(
          p.join(workspace.path, 'exports', 'rejected.$extension'),
        );
        await expectLater(
          prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: output.path,
            extension: extension,
            values: {AudioField.title: 'Synthetic'},
          ),
          throwsA(isA<ExportException>()),
        );
        expect(await output.exists(), isFalse);
        expect(await _hash(source), before);
      }
    });

    test('a WAV disguised as MP3 is refused by the exporter', () async {
      final source = File(p.join(fixtures.path, 'wav_disguised_as_mp3.mp3'));
      final before = await _hash(source);
      final output = File(p.join(workspace.path, 'exports', 'disguised.mp3'));
      await expectLater(
        prepareTaggedCopy(
          sourcePath: source.path,
          outputPath: output.path,
          extension: 'mp3',
          values: {AudioField.lyrics: 'Synthetic only'},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await output.exists(), isFalse);
      expect(await _hash(source), before);
    });

    test('original path, existing destination and existing tags cannot be overwritten', () async {
      final source = File(p.join(fixtures.path, 'unicode_mp3.mp3'));
      final before = await _hash(source);
      await expectLater(
        prepareTaggedCopy(
          sourcePath: source.path,
          outputPath: source.path,
          extension: 'mp3',
          values: {AudioField.title: 'Do not overwrite'},
        ),
        throwsA(isA<ExportException>()),
      );
      final existing = File(p.join(workspace.path, 'already_exists.mp3'));
      await existing.writeAsString('Preserve this destination');
      final existingHash = await _hash(existing);
      await expectLater(
        prepareTaggedCopy(
          sourcePath: source.path,
          outputPath: existing.path,
          extension: 'mp3',
          values: {AudioField.title: 'Do not overwrite'},
        ),
        throwsA(isA<ExportException>()),
      );
      final output = File(p.join(workspace.path, 'must_not_be_created.mp3'));
      await expectLater(
        prepareTaggedCopy(
          sourcePath: source.path,
          outputPath: output.path,
          extension: 'mp3',
          values: {AudioField.title: 'Do not overwrite'},
        ),
        throwsA(isA<ExportException>()),
      );
      expect(await _hash(source), before);
      expect(await _hash(existing), existingHash);
      expect(await output.exists(), isFalse);
    });

    test(
      'source metadata changes after review refuse export without output',
      () async {
        final source = File(
          p.join(fixtures.path, 'cover_without_lyrics_mp3.mp3'),
        );
        final output = File(p.join(workspace.path, 'stale_refused.mp3'));
        final before = await _hash(source);
        await expectLater(
          prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: output.path,
            extension: 'mp3',
            values: {AudioField.lyrics: 'Synthetic only'},
            expectedTrack: AudioTrack(
              id: 'stale',
              fileName: 'stale.mp3',
              sizeBytes: await source.length(),
              importedAt: DateTime(2026),
              title: 'A different song from an old query',
              artist: 'Different artist',
            ),
          ),
          throwsA(isA<ExportException>()),
        );
        expect(await output.exists(), isFalse);
        expect(await _hash(source), before);
      },
    );

    test(
      'system save cancel and repeated save clean temporary exports',
      () async {
        const channel = MethodChannel('audio_fixer/fixture_export');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final source = File(
          p.join(fixtures.path, 'cover_without_lyrics_mp3.mp3'),
        );
        final before = await _hash(source);
        final cache = Directory(p.join(workspace.path, 'service_cache'));
        final exporter = SafeAudioCopyExporter(
          () async => cache,
          channel: channel,
        );
        final sourceMetadata = readMetadata(source, getImage: false);
        final track = AudioTrack(
          title: sourceMetadata.title,
          artist: sourceMetadata.artist,
          album: sourceMetadata.album,
          durationMs: sourceMetadata.duration?.inMilliseconds,
          id: 'fixture',
          fileName: 'synthetic.MP3',
          localPath: source.path,
          sizeBytes: await source.length(),
          importedAt: DateTime(2026),
        );
        const selected = [
          FieldSuggestion(
            field: AudioField.lyrics,
            value: 'Offline synthetic service fixture',
            source: 'Local test',
          ),
        ];
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'exportAudioCopy');
          final args = call.arguments as Map;
          expect(args['fileName'], 'synthetic-fixed.mp3');
          expect(args['mimeType'], 'audio/mpeg');
          final temporary = File(args['path'] as String);
          expect(await temporary.exists(), isTrue);
          expect(
            readMetadata(temporary, getImage: false).lyrics,
            selected.single.value,
          );
          calls++;
          if (calls == 1) return null; // The system save dialog was cancelled.
          final saved = File(p.join(workspace.path, 'saved_$calls.mp3'));
          await temporary.copy(saved.path);
          await _validate(
            python!,
            ['compare', source.path, saved.path],
            expectedTags: {'lyrics': selected.single.value},
          );
          return 'content://fixture/saved/$calls';
        });
        expect(await exporter.export(track, selected), isNull);
        expect(
          await Directory(p.join(cache.path, 'tagged_exports')).list().length,
          0,
        );
        expect(
          await exporter.export(track, selected),
          'content://fixture/saved/2',
        );
        expect(
          await Directory(p.join(cache.path, 'tagged_exports')).list().length,
          0,
        );
        expect(
          await exporter.export(track, selected),
          'content://fixture/saved/3',
        );
        expect(
          await Directory(p.join(cache.path, 'tagged_exports')).list().length,
          0,
        );
        expect(calls, 3);
        expect(await _hash(source), before);
      },
    );

    test(
      'device read copies are released after native export failure and retry',
      () async {
        const channel = MethodChannel('audio_fixer/fixture_device_export');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final source = File(
          p.join(fixtures.path, 'cover_without_lyrics_mp3.mp3'),
        );
        final before = await _hash(source);
        final cache = Directory(p.join(workspace.path, 'device_service_cache'));
        final exporter = SafeAudioCopyExporter(
          () async => cache,
          channel: channel,
        );
        final sourceMetadata = readMetadata(source, getImage: false);
        final track = AudioTrack(
          title: sourceMetadata.title,
          artist: sourceMetadata.artist,
          album: sourceMetadata.album,
          durationMs: sourceMetadata.duration?.inMilliseconds,
          id: 'media:1',
          fileName: 'device.mp3',
          contentUri: 'content://fixture/audio/1',
          sizeBytes: await source.length(),
          importedAt: DateTime(2026),
        );
        const selected = [
          FieldSuggestion(
            field: AudioField.lyrics,
            value: 'Offline synthetic device fixture',
            source: 'Local test',
          ),
        ];
        var readCount = 0;
        var releaseCount = 0;
        var failSave = true;
        final readPaths = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          switch (call.method) {
            case 'copyForRead':
              expect(args['uri'], track.contentUri);
              final copied = await source.copy(
                p.join(workspace.path, 'native_read_${readCount++}.mp3'),
              );
              readPaths.add(copied.path);
              return copied.path;
            case 'releaseReadCopy':
              final copied = File(args['path'] as String);
              expect(readPaths, contains(copied.path));
              expect(await _hash(copied), before);
              await copied.delete();
              releaseCount++;
              return null;
            case 'exportAudioCopy':
              expect(await File(args['path'] as String).exists(), isTrue);
              if (failSave) throw PlatformException(code: 'save_failed');
              return 'content://fixture/saved/device';
            default:
              fail('Unexpected method ${call.method}');
          }
        });
        await expectLater(
          exporter.export(track, selected),
          throwsA(isA<PlatformException>()),
        );
        expect(releaseCount, 1);
        expect(
          await Directory(p.join(cache.path, 'tagged_exports')).list().length,
          0,
        );
        failSave = false;
        expect(
          await exporter.export(track, selected),
          'content://fixture/saved/device',
        );
        expect(readCount, 2);
        expect(releaseCount, 2);
        for (final path in readPaths) {
          expect(await File(path).exists(), isFalse);
        }
        expect(
          await Directory(p.join(cache.path, 'tagged_exports')).list().length,
          0,
        );
        expect(await _hash(source), before);
      },
    );

    final realInput = Platform.environment['AUDIO_FIXER_REAL_INPUTS'];
    if (realInput != null) {
      test(
        'supplied MP3 copies retain every audio packet and decoded sample',
        () async {
          final files = await Directory(realInput)
              .list()
              .where(
                (entity) =>
                    entity is File &&
                    p.extension(entity.path).toLowerCase() == '.mp3',
              )
              .cast<File>()
              .toList();
          expect(files, isNotEmpty);
          final reports = <Map<String, dynamic>>[];
          for (final original in files) {
            final originalHash = await _hash(original);
            // Work only on an independent copy of a supplied user file.
            final source = await original.copy(
              p.join(workspace.path, p.basename(original.path)),
            );
            final output = File(
              p.join(workspace.path, 'real_exports', p.basename(original.path)),
            );
            final originalMetadata = readMetadata(source, getImage: true);
            expect(hasText(originalMetadata.lyrics), isFalse);
            await prepareTaggedCopy(
              sourcePath: source.path,
              outputPath: output.path,
              extension: 'mp3',
              values: {
                AudioField.lyrics:
                    '[00:00.00] Audio Fixer offline validation only',
              },
            );
            final result = readMetadata(output, getImage: true);
            expect(result.title, originalMetadata.title);
            expect(result.artist, originalMetadata.artist);
            expect(result.album, originalMetadata.album);
            expect(
              result.pictures.map(
                (image) => sha256.convert(image.bytes).toString(),
              ),
              originalMetadata.pictures.map(
                (image) => sha256.convert(image.bytes).toString(),
              ),
            );
            expect(await _hash(original), originalHash);
            expect(await _hash(source), originalHash);
            reports.add(
              await _validate(
                python!,
                ['compare', source.path, output.path],
                expectedTags: {
                  'lyrics': '[00:00.00] Audio Fixer offline validation only',
                },
              ),
            );
          }
          final report = File(
            p.join(workspace.path, 'supplied_export_validation.json'),
          );
          await report.writeAsString(
            const JsonEncoder.withIndent('  ').convert(reports),
          );
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );
    }
  }, skip: skip);
}
