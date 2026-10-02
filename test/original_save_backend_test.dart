import 'dart:io';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/original-save-backend');
  const lyric = FieldSuggestion(
    field: AudioField.lyrics,
    value: 'Reviewed offline lyrics',
    source: 'Fixture',
  );
  late Directory work;
  late SafeAudioCopyExporter exporter;
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall)? handler;

  AudioTrack track(String path, {String? uri, String name = 'fixture.mp3'}) =>
      AudioTrack(
        id: 'test',
        fileName: name,
        localPath: path,
        contentUri: uri,
        sizeBytes: 1,
        importedAt: DateTime(2026),
        detailsLoaded: false,
      );

  setUp(() async {
    work = await Directory.systemTemp.createTemp('original-save-tests-');
    calls.clear();
    handler = null;
    exporter = SafeAudioCopyExporter(() async => work, channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler?.call(call);
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await work.delete(recursive: true);
  });

  test(
    'original save is optional and restricted to supported located tracks',
    () {
      expect(exporter, isA<AudioOriginalSaver>());
      expect(exporter, isA<AudioBatchExporter>());
      expect(exporter, isA<AudioOriginalRecovery>());
      expect(exporter, isA<AudioBatchOriginalSaver>());
      expect(exporter.supportsOriginal(track('/owned/source')), isFalse);
      expect(exporter.supportsOriginal(track('')), isFalse);
      expect(
        exporter.supportsOriginal(
          track('', uri: 'content://media/external/audio/media/1'),
        ),
        isTrue,
      );
      expect(
        exporter.supportsOriginal(track('/owned/source', name: 'file.wav')),
        isFalse,
      );
    },
  );

  test(
    'batch directory picker returns cancellation or exact tree URI',
    () async {
      expect(await exporter.chooseExportDirectory(), isNull);
      handler = (call) async => 'content://documents/tree/primary%3AMusic';
      expect(
        await exporter.chooseExportDirectory(),
        'content://documents/tree/primary%3AMusic',
      );
      expect(calls.map((call) => call.method), [
        'chooseExportDirectory',
        'chooseExportDirectory',
      ]);
    },
  );

  test(
    'retry recovery only uses permission-check channel, not restore',
    () async {
      handler = (call) async => 'Current bytes remain unchanged';
      expect(
        await exporter.retryOriginalRecovery(),
        'Current bytes remain unchanged',
      );
      expect(calls.single.method, 'retryOriginalRecovery');
      expect(calls.single.arguments, isNull);
    },
  );

  test('grouped authorization sends only unique supplied device URIs and cancellation', () async {
    final requested = [
      track('', uri: 'content://media/external/audio/media/10'),
      track('/owned/private'),
      track('', uri: 'content://media/external/audio/media/10'),
      track('', uri: 'content://media/external/audio/media/20'),
    ];
    handler = (call) async {
      expect(call.method, 'authorizeOriginalWrites');
      expect(call.arguments, {
        'uris': [
          'content://media/external/audio/media/10',
          'content://media/external/audio/media/20',
        ],
      });
      return false;
    };
    expect(await exporter.authorizeOriginalWrites(requested), isFalse);
    handler = (call) async => true;
    expect(await exporter.authorizeOriginalWrites(requested), isTrue);
    expect(
      calls.every((call) => call.method == 'authorizeOriginalWrites'),
      isTrue,
    );
  });

  test('legacy private copies reject original save before reading or native writes', () async {
    await expectLater(
      exporter.saveOriginal(track('/owned/content-addressed.audio'), [lyric]),
      throwsA(isA<ExportException>()),
    );
    expect(calls, isEmpty);
    expect(exporter.supports(track('/owned/content-addressed.audio')), isTrue);
  });

  test('structured recovery separates recheck, explicit restore, version export and finish', () async {
    handler = (call) async {
      if (call.method == 'getOriginalRecoveryState') {
        return {
          'status': 'conflict',
          'targetUri': 'content://media/external/audio/media/1',
          'canRestore': true,
          'canFinish': false,
          'versions': [
            {
              'id': 'original',
              'label': 'Original backup',
              'sha256': 'a' * 64,
              'sizeBytes': 100,
            },
            {
              'id': 'opaque-snapshot',
              'label': 'Preserved version',
              'sha256': 'b' * 64,
              'sizeBytes': 130,
              'exportedUri': 'content://docs/exported',
            },
          ],
        };
      }
      if (call.method == 'restoreOriginalBackup') {
        return 'Both versions retained';
      }
      if (call.method == 'exportOriginalRecoveryVersion') {
        expect(call.arguments, {'versionId': 'opaque-snapshot'});
        return 'content://docs/new-copy';
      }
      if (call.method == 'finishOriginalRecovery') return null;
      fail('Unexpected recovery call: ${call.method}');
    };
    final state = (await exporter.getOriginalRecoveryState())!;
    expect(state.status, 'conflict');
    expect(state.canRestore, isTrue);
    expect(state.canFinish, isFalse);
    expect(state.versions.last.exportedUri, 'content://docs/exported');
    expect(state.versions.last.sizeBytes, 130);
    expect(await exporter.restoreOriginalBackup(), 'Both versions retained');
    expect(
      await exporter.exportOriginalRecoveryVersion('opaque-snapshot'),
      'content://docs/new-copy',
    );
    await exporter.finishOriginalRecovery();
    expect(calls.map((call) => call.method), [
      'getOriginalRecoveryState',
      'restoreOriginalBackup',
      'exportOriginalRecoveryVersion',
      'finishOriginalRecovery',
    ]);
  });

  test('missing state and cancelled recovery export remain null', () async {
    expect(await exporter.getOriginalRecoveryState(), isNull);
    expect(await exporter.exportOriginalRecoveryVersion('original'), isNull);
  });

  bool ffmpegReady;
  try {
    ffmpegReady = Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } on ProcessException {
    ffmpegReady = false;
  }

  Future<File> fixture() async {
    final source = File(p.join(work.path, 'original.mp3'));
    final result = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=0.2',
      '-map_metadata',
      '-1',
      '-c:a',
      'libmp3lame',
      '-id3v2_version',
      '0',
      source.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return source;
  }

  for (final cancelled in [false, true]) {
    test(
      'device original save sends snapshot hash and cleans staging, cancelled=$cancelled',
      () async {
        final source = await fixture();
        final before = await source.readAsBytes();
        String? staged;
        handler = (call) async {
          if (call.method == 'copyForRead') return source.path;
          if (call.method == 'releaseReadCopy') return null;
          expect(call.method, 'saveAudioOriginal');
          final args = call.arguments as Map;
          expect(args['sourcePath'], isNull);
          expect(args['sourceUri'], 'content://media/external/audio/media/1');
          expect(args['sourceSha256'], sha256.convert(before).toString());
          staged = args['path'] as String;
          expect(
            readMetadata(File(staged!), getImage: true).lyrics,
            lyric.value,
          );
          expect(await source.readAsBytes(), before);
          return cancelled ? null : 'content://media/external/audio/media/1';
        };
        expect(
          await exporter.saveOriginal(
            track('', uri: 'content://media/external/audio/media/1'),
            [lyric],
          ),
          cancelled ? null : 'content://media/external/audio/media/1',
        );
        expect(await File(staged!).exists(), isFalse);
        expect(await source.readAsBytes(), before);
      },
      skip: ffmpegReady
          ? false
          : 'ffmpeg is required for encoded audio fixture',
    );
  }

  test(
    'device original save uses read snapshot and releases it after native failure',
    () async {
      final source = await fixture();
      final before = await source.readAsBytes();
      String? staged;
      handler = (call) async {
        if (call.method == 'copyForRead') return source.path;
        if (call.method == 'saveAudioOriginal') {
          final args = call.arguments as Map;
          expect(args['sourceUri'], 'content://media/external/audio/media/10');
          expect(args['sourcePath'], isNull);
          expect(args['sourceSha256'], sha256.convert(before).toString());
          staged = args['path'] as String;
          throw PlatformException(
            code: 'original_save_failed',
            message: 'Source changed',
          );
        }
        expect(call.method, 'releaseReadCopy');
        expect(call.arguments, {'path': source.path});
        return null;
      };
      await expectLater(
        exporter.saveOriginal(
          track('', uri: 'content://media/external/audio/media/10'),
          [lyric],
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.map((call) => call.method), [
        'copyForRead',
        'saveAudioOriginal',
        'releaseReadCopy',
      ]);
      expect(await File(staged!).exists(), isFalse);
      expect(await source.readAsBytes(), before);
    },
    skip: ffmpegReady ? false : 'ffmpeg is required for encoded audio fixture',
  );

  test(
    'batch export reuses chosen directory and never requests original write',
    () async {
      final source = await fixture();
      final before = await source.readAsBytes();
      var created = 0;
      handler = (call) async {
        expect(call.method, 'exportAudioToDirectory');
        final args = call.arguments as Map;
        expect(args['directoryUri'], 'content://documents/tree/chosen');
        expect(args.containsKey('sourceSha256'), isFalse);
        expect(args['fileName'], 'fixture-fixed.mp3');
        expect(readMetadata(File(args['path'] as String)).lyrics, lyric.value);
        return 'content://documents/new-${++created}';
      };
      for (var i = 1; i <= 2; i++) {
        expect(
          await exporter.exportToDirectory(track(source.path), [
            lyric,
          ], 'content://documents/tree/chosen'),
          'content://documents/new-$i',
        );
      }
      expect(await source.readAsBytes(), before);
      expect(
        await Directory(p.join(work.path, 'tagged_exports')).list().isEmpty,
        isTrue,
      );
    },
    skip: ffmpegReady ? false : 'ffmpeg is required for encoded audio fixture',
  );
}
