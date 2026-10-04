import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_inventory_service.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/export/audio_payload.dart';
import 'package:audio_fixer/core/services/standard_audio_tags.dart';
import 'package:audio_fixer/core/services/windows_audio_inventory_backend.dart';
import 'package:audio_fixer/core/services/windows_file_access.dart';
import 'package:audio_fixer/core/services/windows_file_method_channel.dart';
import 'package:audio_fixer/core/services/windows_music_library.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _lyric = FieldSuggestion(
  field: AudioField.lyrics,
  value: 'Offline synthetic test lyrics',
  source: 'Test fixture',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory support;
  late Directory music;
  late Directory exports;
  late WindowsFileAccess access;
  late WindowsMusicLibrary library;
  late WindowsFileMethodChannel channel;
  String? selection;

  WindowsFileAccess newAccess({Map<String, String> environment = const {}}) =>
      WindowsFileAccess(
        () async => support,
        pickDirectory: (_) async => selection,
        environment: environment,
      );

  Future<File> source({String name = '夜空 Café #100% 🎵.mp3'}) async =>
      File(p.join(music.path, name)).writeAsBytes(_mp3());

  Future<File> staged(List<int> bytes) async {
    final directory = await Directory(
      p.join(support.path, 'tagged_exports', 'export_test'),
    ).create(recursive: true);
    return File(p.join(directory.path, 'tagged.mp3')).writeAsBytes(bytes);
  }

  Future<String?> rawSave(File original, File prepared, {String? expected}) =>
      channel.invokeMethod<String>('saveAudioOriginal', {
        'sourceUri': original.uri.toString(),
        'sourceSha256':
            expected ?? sha256.convert(original.readAsBytesSync()).toString(),
        'path': prepared.path,
      });

  setUp(() async {
    final created = await Directory.systemTemp.createTemp(
      'windows-services-test-',
    );
    // Windows TEMP can use an 8.3 alias (RUNNER~1); all fixtures must use
    // the same canonical root as the production filesystem authority.
    root = Directory(await created.resolveSymbolicLinks());
    support = await Directory(p.join(root.path, 'support')).create();
    music = await Directory(p.join(root.path, '音乐 #100% 🎵')).create();
    exports = await Directory(p.join(root.path, 'exports')).create();
    selection = music.path;
    access = newAccess();
    library = WindowsMusicLibrary(access);
    channel = WindowsFileMethodChannel(access);
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'picked roots persist, scope library, and preserve Unicode URI identity',
    () async {
      final file = await source();
      await File(p.join(root.path, 'outside.mp3')).writeAsBytes(_mp3());
      await File(p.join(music.path, 'ignored.txt')).writeAsString('not audio');
      expect(
        await library.permissionStatus(),
        AudioLibraryPermission.notRequested,
      );
      expect(await library.chooseFolder(), isTrue);
      final rows = await library.querySongs();
      expect(rows, hasLength(1));
      expect(rows.single.contentUri, file.uri.toString());
      expect(rows.single.localPath, file.path);
      expect(rows.single.detailsLoaded, isFalse);
      expect(rows.single.folder, isNotNull);
      final details = await library.readDetails(rows.single);
      expect(details.readError, isNull);
      expect(details.durationMs, greaterThan(0));
      expect(await library.readArtworkThumbnail(rows.single), isNull);
      final restarted = WindowsMusicLibrary(newAccess());
      final next = await restarted.querySongs();
      expect(next.single.id, rows.single.id);
      expect(
        await restarted.permissionStatus(),
        AudioLibraryPermission.granted,
      );
    },
  );

  test(
    'default Music is readable but original writes need an explicit pick',
    () async {
      final profile = await Directory(p.join(root.path, 'profile')).create();
      final defaultMusic = await Directory(p.join(profile.path, 'Music'))
          .create();
      final file = await File(p.join(defaultMusic.path, 'default.mp3'))
          .writeAsBytes(_mp3());
      final defaults = newAccess(environment: {'USERPROFILE': profile.path});
      final defaultLibrary = WindowsMusicLibrary(defaults);
      expect(
        await defaultLibrary.permissionStatus(),
        AudioLibraryPermission.granted,
      );
      expect((await defaultLibrary.querySongs()).single.localPath, file.path);
      await expectLater(
        defaults.sourceFile(file.uri.toString(), forWrite: true),
        throwsA(isA<PlatformException>()),
      );
      selection = defaultMusic.path;
      await defaultLibrary.chooseFolder();
      expect(
        await defaults.sourceFile(file.uri.toString(), forWrite: true),
        isA<File>(),
      );
    },
  );

  test(
    'cancellation grants nothing, outside/UNC/query URIs and paths rejected',
    () async {
      selection = null;
      expect(
        await library.requestPermission(),
        AudioLibraryPermission.notRequested,
      );
      expect(access.roots, isEmpty);
      selection = music.path;
      await library.chooseFolder();
      final outside = await File(p.join(root.path, 'outside.mp3'))
          .writeAsBytes(_mp3());
      await expectLater(
        access.sourceFile(outside.uri.toString()),
        throwsA(isA<PlatformException>()),
      );
      for (final uri in [
        'content://media/1',
        'file://server/share/a.mp3',
        '${outside.uri}?x=1',
      ]) {
        expect(() => access.filePath(uri), throwsA(isA<PlatformException>()));
      }
      await expectLater(
        access.preparedFile(outside.path),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        access.exportDirectory(exports.uri.toString()),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'symlinks cannot expand selected folder read or write authority',
    () async {
      if (Platform.isWindows) {
        return; // Creating a Windows symlink can require elevated privileges.
      }
      final outside = await File(p.join(root.path, 'outside.mp3'))
          .writeAsBytes(_mp3());
      final linked = await Link(p.join(music.path, 'linked.mp3'))
          .create(outside.path);
      await library.chooseFolder();
      expect(await library.querySongs(), isEmpty);
      await expectLater(
        access.sourceFile(Uri.file(linked.path).toString()),
        throwsA(isA<PlatformException>()),
      );
      final nested = await Directory(p.join(root.path, 'outside-directory'))
          .create();
      await File(p.join(nested.path, 'hidden.mp3')).writeAsBytes(_mp3());
      await Link(p.join(music.path, 'linked-directory')).create(nested.path);
      expect(await library.querySongs(), isEmpty);
    },
  );

  test('partial selected-root failure is an error rather than missing-song evidence', () async {
    await source();
    await library.chooseFolder();
    final other = await Directory(p.join(root.path, 'other')).create();
    selection = other.path;
    await library.chooseFolder();
    await other.delete();
    await expectLater(library.querySongs(), throwsA(isA<PlatformException>()));
    expect(library.lastScanErrors, greaterThan(0));
  });

  test(
    'read snapshots are immutable and only own paths can be released',
    () async {
      final file = await source();
      await library.chooseFolder();
      final copied = await channel.invokeMethod<String>('copyForRead', {
        'uri': file.uri.toString(),
      });
      expect(copied, isNot(file.path));
      expect(await File(copied!).readAsBytes(), _mp3());
      await channel.invokeMethod<void>('releaseReadCopy', {'path': file.path});
      expect(await file.exists(), isTrue);
      await channel.invokeMethod<void>('releaseReadCopy', {'path': copied});
      expect(await File(copied).exists(), isFalse);
    },
  );

  test('raw original commit uses source hash, durable backup, and exact acknowledgement', () async {
    final file = await source();
    await library.chooseFolder();
    final original = await file.readAsBytes();
    final output = await staged([...original, 1, 2, 3]);
    final outputBytes = await output.readAsBytes();
    expect(await rawSave(file, output), file.uri.toString());
    expect(await file.readAsBytes(), outputBytes);
    final restarted = WindowsFileMethodChannel(newAccess());
    final state = await restarted.invokeMapMethod<String, dynamic>(
      'getOriginalRecoveryState',
    );
    expect(state!['status'], 'saved');
    expect(state['canRestore'], isTrue);
    expect(state['canFinish'], isFalse);
    expect((state['versions'] as List).length, 2);
    await expectLater(
      restarted.invokeMethod<void>('confirmExportRecorded', {
        'uri': 'file:///wrong',
      }),
      throwsA(isA<PlatformException>()),
    );
    await restarted.invokeMethod<void>('confirmExportRecorded', {
      'uri': file.uri.toString(),
    });
    expect(
      await restarted.invokeMethod<Object>('getOriginalRecoveryState'),
      isNull,
    );
    expect(await file.readAsBytes(), outputBytes);
  });

  test('stale source hashes reject before original mutation', () async {
    final file = await source();
    await library.chooseFolder();
    final bytes = await file.readAsBytes();
    final output = await staged([...bytes, 3]);
    await expectLater(
      rawSave(file, output, expected: '0' * 64),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'source_changed',
        ),
      ),
    );
    expect(await file.readAsBytes(), bytes);
    expect(
      await channel.invokeMethod<Object>('getOriginalRecoveryState'),
      isNull,
    );
  });

  test('conflict restart is read-only, explicit restore preserves all different versions', () async {
    final file = await source();
    await library.chooseFolder();
    final original = await file.readAsBytes();
    final tagged = [...original, 8, 7];
    await rawSave(file, await staged(tagged));
    final external = [...original, 42, 43, 44];
    await file.writeAsBytes(external);
    final restarted = WindowsFileMethodChannel(newAccess());
    expect(await restarted.invokeMethod<String>('recoverExport'), isNotNull);
    await restarted.invokeMethod<String>('retryOriginalRecovery');
    expect(await file.readAsBytes(), external);
    var state = await restarted.invokeMapMethod<String, dynamic>(
      'getOriginalRecoveryState',
    );
    expect(state!['status'], 'conflict');
    expect(state['canFinish'], isFalse);
    await expectLater(
      restarted.invokeMethod<void>('acknowledgeExportRecovery'),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      restarted.invokeMethod<void>('finishOriginalRecovery'),
      throwsA(isA<PlatformException>()),
    );
    await restarted.invokeMethod<String>('restoreOriginalBackup');
    expect(await file.readAsBytes(), original);
    state = await restarted.invokeMapMethod<String, dynamic>(
      'getOriginalRecoveryState',
    );
    final versions = state!['versions'] as List;
    expect(
      versions.map((v) => (v as Map)['sha256']),
      containsAll([
        sha256.convert(original).toString(),
        sha256.convert(tagged).toString(),
        sha256.convert(external).toString(),
      ]),
    );
    selection = exports.path;
    final copies = <File>[];
    for (final row in versions) {
      final version = row as Map;
      if (version['id'] == 'original') continue;
      final uri = await restarted.invokeMethod<String>(
        'exportOriginalRecoveryVersion',
        {'versionId': version['id']},
      );
      final copy = File.fromUri(Uri.parse(uri!));
      copies.add(copy);
      expect(await windowsFileSha256(copy), version['sha256']);
    }
    expect(
      (await restarted.invokeMapMethod<String, dynamic>(
        'getOriginalRecoveryState',
      ))!['canFinish'],
      isTrue,
    );
    // Exported retention is reverified, not trusted forever from a flag.
    await copies.first.writeAsString('changed outside app');
    expect(
      (await restarted.invokeMapMethod<String, dynamic>(
        'getOriginalRecoveryState',
      ))!['canFinish'],
      isFalse,
    );
    await restarted.invokeMethod<String>('exportOriginalRecoveryVersion', {
      'versionId': 'tagged',
    });
    await restarted.invokeMethod<void>('finishOriginalRecovery');
    expect(
      await restarted.invokeMethod<Object>('getOriginalRecoveryState'),
      isNull,
    );
    expect(await file.readAsBytes(), original);
    expect(await copies.first.readAsString(), 'changed outside app');
  });

  test(
    'corrupt backup blocks recovery and cleanup without touching current audio',
    () async {
      final file = await source();
      await library.chooseFolder();
      final original = await file.readAsBytes();
      await rawSave(file, await staged([...original, 6]));
      final journalFile = File(
        p.join(support.path, 'windows_recovery', 'pending.json'),
      );
      final journal = jsonDecode(await journalFile.readAsString()) as Map;
      await File(
        p.join(
          support.path,
          'windows_recovery',
          journal['session'] as String,
          'tagged.audio',
        ),
      ).writeAsString('corrupt');
      var state = await channel.invokeMapMethod<String, dynamic>(
        'getOriginalRecoveryState',
      );
      expect(state!['canRestore'], isFalse);
      await expectLater(
        channel.invokeMethod<String>('restoreOriginalBackup'),
        throwsA(isA<PlatformException>()),
      );
      expect(await file.readAsBytes(), [...original, 6]);
      expect(await journalFile.exists(), isTrue);
      state = await channel.invokeMapMethod<String, dynamic>(
        'getOriginalRecoveryState',
      );
      expect(state!['canFinish'], isFalse);
    },
  );

  test(
    'real exporter shares verified tags and preserves audio payload',
    () async {
      final file = await source();
      await library.chooseFolder();
      final track = await library.readDetails(
        (await library.querySongs()).single,
      );
      final digest = await audioPayloadDigest(file, 'mp3');
      final exporter = SafeAudioCopyExporter(
        () async => support,
        channel: channel,
      );
      final uri = await exporter.saveOriginal(track, [_lyric]);
      expect(uri, file.uri.toString());
      expect(readStandardAudioTags(file).lyrics, _lyric.value);
      expect(await audioPayloadDigest(file, 'mp3'), digest);
      await exporter.confirmExportRecorded(uri!);
      expect(await exporter.getOriginalRecoveryState(), isNull);
    },
  );

  test('copy exports preserve existing names and block before recovery acknowledgement', () async {
    final file = await source();
    await library.chooseFolder();
    final track = await library.readDetails(
      (await library.querySongs()).single,
    );
    final exporter = SafeAudioCopyExporter(
      () async => support,
      channel: channel,
    );
    selection = exports.path;
    final directory = await exporter.chooseExportDirectory();
    final first = await exporter.exportToDirectory(track, [_lyric], directory!);
    expect(
      readStandardAudioTags(File.fromUri(Uri.parse(first!))).lyrics,
      _lyric.value,
    );
    await expectLater(
      exporter.exportToDirectory(track, [_lyric], directory),
      throwsA(isA<PlatformException>()),
    );
    await exporter.confirmExportRecorded(first);
    final second = await exporter.exportToDirectory(track, [_lyric], directory);
    expect(second, isNot(first));
    expect(await File.fromUri(Uri.parse(first)).exists(), isTrue);
    expect(await file.readAsBytes(), _mp3());
    await exporter.confirmExportRecorded(second!);
  });

  test('inventory saves UTF-8 scoped TXT with hash-verified retry and cancellation', () async {
    final file = await source();
    await library.chooseFolder();
    final exporter = SafeAudioCopyExporter(
      () async => support,
      channel: channel,
    );
    final track = await library.readDetails(
      (await library.querySongs()).single,
    );
    final savedUri = await exporter.saveOriginal(track, [_lyric]);
    await exporter.confirmExportRecorded(savedUri!);
    final backend = WindowsAudioInventoryBackend(library, access);
    final events = <AudioInventoryProgress>[];
    final subscription = backend.progress.listen(events.add);
    selection = null;
    final cancelled = await backend.exportInventory(operationId: 1);
    expect(cancelled.status, AudioInventoryStatus.cancelled);
    expect(cancelled.canRetrySave, isTrue);
    expect(cancelled.scanned, 1);
    selection = exports.path;
    final saved = await backend.retrySave(operationId: 2);
    expect(saved.isSaved, isTrue);
    expect(saved.metadataSuccess, 1);
    expect(saved.possiblePartialDocument, isFalse);
    final report = File(p.join(exports.path, saved.fileName!));
    final text = await report.readAsString();
    expect(text, contains(file.path));
    expect(text, contains('路径：'));
    expect(text, contains('仅所选音乐文件夹'));
    expect(text, contains('歌词：有'));
    expect(text, isNot(contains(_lyric.value)));
    expect(text, isNot(contains('device_artwork')));
    expect(
      events.any((event) => event.phase == AudioInventoryPhase.scanning),
      isTrue,
    );
    expect(
      (await backend.retrySave(operationId: 3)).status,
      AudioInventoryStatus.failed,
    );
    await subscription.cancel();
  });

  test(
    'reserved export names reject external replacement without truncation',
    () async {
      final input = await source();
      final reserved = await createWindowsOutput(exports, 'copy.mp3');
      await reserved.writeAsString('new external bytes');
      await expectLater(
        copyWindowsReservedOutput(input, reserved),
        throwsA(isA<FileSystemException>()),
      );
      expect(await reserved.readAsString(), 'new external bytes');
      final next = await createWindowsOutput(exports, 'copy.mp3');
      expect(next.path, isNot(reserved.path));
      await copyWindowsReservedOutput(input, next);
      expect(await next.readAsBytes(), _mp3());
    },
  );

  test(
    'inventory cancellation while picker pending writes no output',
    () async {
      await source();
      await library.chooseFolder();
      final picker = Completer<String?>();
      final pendingAccess = WindowsFileAccess(
        () async => support,
        environment: const {},
        pickDirectory: (_) => picker.future,
      );
      final backend = WindowsAudioInventoryBackend(
        WindowsMusicLibrary(pendingAccess),
        pendingAccess,
      );
      final choosing = Completer<void>();
      final subscription = backend.progress.listen((event) {
        if (event.phase == AudioInventoryPhase.choosingDestination &&
            !choosing.isCompleted) {
          choosing.complete();
        }
      });
      final running = backend.exportInventory(operationId: 30);
      await choosing.future;
      expect(await backend.cancelExport(operationId: 30), isTrue);
      picker.complete(exports.path);
      final result = await running;
      expect(result.status, AudioInventoryStatus.cancelled);
      expect(result.canRetrySave, isFalse);
      expect(await exports.list().isEmpty, isTrue);
      await subscription.cancel();
    },
  );
}

List<int> _mp3() => base64Decode(_syntheticMp3Base64);

const _syntheticMp3Base64 =
    'SUQzAwAAAAAAIlRTU0UAAAAOAAAATGF2ZjYxLjcuMTAzAAAAAAAAAAAAAAD/+xDEAAPAAAGkAAAA'
    'IAAANIAAAARMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
    'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTMuMTAwVf/7EsQpg8AAAaQAAAAgAAA0gAAABFVV'
    'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
    'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVf/7EMRTg8AAAaQAAAAgAAA0gAAABFVVVVVVVVVVVVVV'
    'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
    'VVVVVVVVVVVVVVVVVVVV//sSxH0DwAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
    'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
    'VVVVVVVV//sQxKcDwAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
    'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/+xLE'
    '0IPAAAGkAAAAIAAANIAAAARVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
    'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/+xDE1gPAAAGkAAAA'
    'IAAANIAAAARVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
    'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQ==';
