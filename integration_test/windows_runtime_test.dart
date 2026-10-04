import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_importer.dart';
import 'package:audio_fixer/core/services/audio_inventory_service.dart';
import 'package:audio_fixer/core/services/audio_preview_service.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/export/audio_payload.dart';
import 'package:audio_fixer/core/services/standard_audio_tags.dart';
import 'package:audio_fixer/core/services/windows_audio_inventory_backend.dart';
import 'package:audio_fixer/core/services/windows_file_access.dart';
import 'package:audio_fixer/core/services/windows_file_method_channel.dart';
import 'package:audio_fixer/core/services/windows_music_library.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../test/support/expanded_review_scenario.dart';

// Run on an actual Windows desktop runner:
// flutter test integration_test/windows_runtime_test.dart -d windows
//
// All media is synthetic and created below in one disposable temporary root.
// The fixture is 0.15 seconds of mono silence encoded locally with FFmpeg:
// ffmpeg -f lavfi -i anullsrc=r=44100:cl=mono -t 0.15 -map_metadata -1
//   -c:a libmp3lame -b:a 32k -id3v2_version 3 -write_xing 0 fixture.mp3
// Embedding the result makes the runtime test independent of network, FFmpeg,
// real user files, and audio-device availability on hosted Windows runners.
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

const _fixtureFileName = '夜空 Café #100% 🎵.mp3';
const _previewChannel = MethodChannel('audio_fixer/audio_preview');

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition,
  String description,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
  await tester.pump();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows Unicode library, UI, safe writes and persisted conflict recovery',
    (tester) async {
      expect(Platform.isWindows, isTrue);
      final temporary = await Directory.systemTemp.createTemp(
        'audio_fixer_windows_',
      );
      // Windows TEMP can contain an 8.3 alias such as RUNNER~1.
      final root = Directory(await temporary.resolveSymbolicLinks());
      final music = await Directory(p.join(root.path, '音乐资料 – 目录 #1')).create();
      final support = await Directory(p.join(root.path, 'support')).create();
      final exports = await Directory(p.join(root.path, '导出 #100%')).create();
      final source = await File(p.join(music.path, _fixtureFileName))
          .writeAsBytes(base64Decode(_syntheticMp3Base64), flush: true);
      final outside = await File(p.join(root.path, 'not-selected.mp3'))
          .writeAsBytes(base64Decode(_syntheticMp3Base64), flush: true);
      final originalHash = await _hash(source);
      final originalPayload = await audioPayloadDigest(source, 'mp3');
      String? selectedDirectory = music.path;
      var pickerCalls = 0;
      WindowsFileAccess newAccess() => WindowsFileAccess(
        () async => support,
        pickDirectory: (title) async {
          expect(title, isNotEmpty);
          pickerCalls++;
          return selectedDirectory;
        },
        // Never discover or scan the hosted runner's real Music folder.
        environment: const {},
      );
      final access = newAccess();
      final library = WindowsMusicLibrary(access);
      final channel = WindowsFileMethodChannel(access);
      // Prepared-file authority and the exporter's staging root must match.
      final exporter = SafeAudioCopyExporter(
        () async => support,
        channel: channel,
      );
      LibraryController? controller;
      var mounted = false;
      try {
        expect(
          await library.permissionStatus(),
          AudioLibraryPermission.notRequested,
        );
        expect(await library.chooseFolder(), isTrue);
        expect(
          await library.permissionStatus(),
          AudioLibraryPermission.granted,
        );
        expect(pickerCalls, 1);
        final rows = await library.querySongs();
        expect(rows, hasLength(1));
        final indexed = rows.single;
        expect(indexed.fileName, _fixtureFileName);
        expect(indexed.detailsLoaded, isFalse);
        expect(indexed.contentUri, source.uri.toString());
        expect(File.fromUri(Uri.parse(indexed.contentUri!)).path, source.path);
        expect(indexed.folder, isNotNull);
        expect(indexed.sizeBytes, await source.length());
        expect(library.lastScanErrors, 0);
        final details = await library.readDetails(indexed);
        expect(details.readError, isNull);
        expect(details.detailsLoaded, isTrue);
        expect(details.durationMs, greaterThan(0));
        expect(details.title, isNull);
        expect(details.lyrics, isNull);
        expect(await library.readArtworkThumbnail(indexed), isNull);
        await expectLater(
          channel.invokeMethod<String>('copyForRead', {
            'uri': outside.uri.toString(),
          }),
          throwsA(isA<PlatformException>()),
        );
        expect(await _hash(outside), originalHash);

        // Exercise the actual app shell, catalog persistence and detail route.
        // Only the OS directory-picker callback is replaced; services, tag
        // parsing, storage, native preview, and file writes remain production.
        controller = LibraryController(
          store: JsonLibraryStore(() async => support),
          picker: SystemAudioPicker(),
          importer: LocalAudioImporter(() async => support),
          completion: CompletionService(),
          deviceLibrary: library,
          exporter: exporter,
        );
        final appController = controller;
        await tester.pumpWidget(AudioFixerApp(controller: appController));
        mounted = true;
        await _waitFor(
          tester,
          () => !appController.isLoading,
          'Windows app startup',
        );
        expect(appController.loadError, isNull);
        expect(appController.libraryError, isNull);
        expect(appController.tracks, hasLength(1));
        final list = find.byKey(const PageStorageKey('library-scroll-view'));
        await tester.scrollUntilVisible(
          find.text(_fixtureFileName).first,
          200,
          scrollable: find
              .descendant(of: list, matching: find.byType(Scrollable))
              .first,
        );
        await tester.tap(find.text(_fixtureFileName).first);
        await _waitFor(
          tester,
          () =>
              find.byType(TrackDetailPage).evaluate().isNotEmpty &&
              appController.trackById(indexed.id)!.detailsLoaded,
          'Windows track detail route and real tag read',
        );
        expect(appController.trackById(indexed.id)!.readError, isNull);
        expect(find.text(_fixtureFileName), findsWidgets);
        expect(tester.takeException(), isNull);
        final backButton = find.byKey(const ValueKey('close-selected-song'));
        expect(backButton, findsOneWidget);
        await tester.tap(backButton);
        await tester.pumpAndSettle();
        expect(find.byType(TrackDetailPage), findsNothing);
        await appController.preview.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        mounted = false; // AudioFixerApp owns and disposes its controller.
        controller = null;
        await tester.pumpAndSettle();

        const suggestions = [
          FieldSuggestion(
            field: AudioField.title,
            value: 'Windows 测试 – Café 🎵',
            source: 'Synthetic runtime fixture',
          ),
          FieldSuggestion(
            field: AudioField.artist,
            value: '离线合成',
            source: 'Synthetic runtime fixture',
          ),
          FieldSuggestion(
            field: AudioField.lyrics,
            value: '[00:00.00]纯合成测试 / no real recording',
            source: 'Synthetic runtime fixture',
          ),
        ];
        selectedDirectory = exports.path;
        final directoryUri = await exporter.chooseExportDirectory();
        expect(directoryUri, exports.uri.toString());
        final exportedUri = await exporter.exportToDirectory(
          details,
          suggestions,
          directoryUri!,
        );
        expect(exportedUri, isNotNull);
        final exported = File.fromUri(Uri.parse(exportedUri!));
        expect(p.isWithin(exports.path, exported.path), isTrue);
        final taggedHash = await _hash(exported);
        expect(taggedHash, isNot(originalHash));
        expect(await _hash(source), originalHash);
        expect(await audioPayloadDigest(exported, 'mp3'), originalPayload);
        expect(readStandardAudioTags(exported).title, suggestions.first.value);
        expect(readStandardAudioTags(exported).lyrics, suggestions.last.value);
        await exporter.confirmExportRecorded(exportedUri);

        // A repeated export must reserve a new name instead of overwriting.
        final secondUri = await exporter.exportToDirectory(
          details,
          suggestions,
          directoryUri,
        );
        expect(secondUri, isNot(exportedUri));
        expect(await _hash(File.fromUri(Uri.parse(secondUri!))), taggedHash);
        expect(await _hash(exported), taggedHash);
        await exporter.confirmExportRecorded(secondUri);
        expect(await exporter.getOriginalRecoveryState(), isNull);

        final originalUri = await exporter.saveOriginal(details, suggestions);
        expect(originalUri, source.uri.toString());
        expect(await _hash(source), taggedHash);
        expect(await audioPayloadDigest(source, 'mp3'), originalPayload);
        final written = await library.readDetails(indexed);
        expect(written.title, suggestions.first.value);
        expect(written.lyrics, suggestions.last.value);
        expect(written.readError, isNull);
        expect(await exporter.getOriginalRecoveryState(), isNotNull);

        // Simulate another program changing ONLY this synthetic source after a
        // verified save but before catalog acknowledgement. Recreating services
        // reads the durable journal; this is not a timed process-crash test.
        final externalEdit = File(p.join(root.path, 'external-edit.mp3'));
        await prepareTaggedCopy(
          sourcePath: source.path,
          outputPath: externalEdit.path,
          extension: 'mp3',
          values: {AudioField.comment: 'Synthetic concurrent external edit'},
        );
        await source.writeAsBytes(
          await externalEdit.readAsBytes(),
          flush: true,
        );
        final thirdHash = await _hash(source);
        expect(thirdHash, isNot(originalHash));
        expect(thirdHash, isNot(taggedHash));
        final restarted = SafeAudioCopyExporter(
          () async => support,
          channel: WindowsFileMethodChannel(newAccess()),
        );
        expect(await restarted.recoverInterruptedExport(), isNotNull);
        var recovery = await restarted.getOriginalRecoveryState();
        expect(recovery, isNotNull);
        expect(recovery!.canRestore, isTrue);
        expect(recovery.canFinish, isFalse);
        expect(await _hash(source), thirdHash);
        await restarted.retryOriginalRecovery();
        expect(await _hash(source), thirdHash);
        await expectLater(
          restarted.acknowledgeExportRecovery(),
          throwsA(isA<PlatformException>()),
        );
        await expectLater(
          restarted.finishOriginalRecovery(),
          throwsA(isA<PlatformException>()),
        );
        expect(await _hash(source), thirdHash);

        expect(await restarted.restoreOriginalBackup(), isNotNull);
        expect(await _hash(source), originalHash);
        recovery = await restarted.getOriginalRecoveryState();
        expect(recovery, isNotNull);
        final versions = recovery!.versions;
        expect(
          versions.map((version) => version.sha256),
          containsAll([originalHash, taggedHash, thirdHash]),
        );
        expect(recovery.canFinish, isFalse);
        final retainedCopies = <File>[];
        for (final version in versions.where(
          (item) => item.sha256 != originalHash,
        )) {
          final uri = await restarted.exportOriginalRecoveryVersion(version.id);
          expect(uri, isNotNull);
          final preserved = File.fromUri(Uri.parse(uri!));
          expect(p.isWithin(exports.path, preserved.path), isTrue);
          expect(await _hash(preserved), version.sha256);
          retainedCopies.add(preserved);
        }
        expect((await restarted.getOriginalRecoveryState())!.canFinish, isTrue);
        await restarted.finishOriginalRecovery();
        expect(await restarted.getOriginalRecoveryState(), isNull);
        expect(await _hash(source), originalHash);
        expect(await _hash(outside), originalHash);
        expect(await _hash(exported), taggedHash);
        for (final retained in retainedCopies) {
          expect(await retained.exists(), isTrue);
        }
        await restarted.acknowledgeExportRecovery();
        expect(await restarted.recoverInterruptedExport(), isNull);

        // The ordinary successful acknowledgement path must also be restart-safe.
        final finalUri = await restarted.saveOriginal(details, suggestions);
        expect(finalUri, source.uri.toString());
        expect(await _hash(source), taggedHash);
        await restarted.confirmExportRecorded(finalUri!);
        expect(await restarted.getOriginalRecoveryState(), isNull);
        final finalAccess = newAccess();
        expect(
          await WindowsMusicLibrary(finalAccess).querySongs(),
          hasLength(1),
        );
        expect(
          await SafeAudioCopyExporter(
            () async => support,
            channel: WindowsFileMethodChannel(finalAccess),
          ).getOriginalRecoveryState(),
          isNull,
        );
        expect(await audioPayloadDigest(source, 'mp3'), originalPayload);

        // Cancel only the save picker, then retry the completed private report.
        // Its UTF-8 text must preserve both Unicode filenames and written tags.
        final inventory = AudioInventoryService(
          backend: WindowsAudioInventoryBackend(library, access),
        );
        try {
          selectedDirectory = null;
          final cancelled = await inventory.exportInventory();
          expect(cancelled!.status, AudioInventoryStatus.cancelled);
          expect(cancelled.scanned, 1);
          expect(cancelled.unreadable, 0);
          expect(inventory.canRetrySave, isTrue);
          selectedDirectory = exports.path;
          final saved = await inventory.retrySave();
          expect(saved!.status, AudioInventoryStatus.saved);
          expect(saved.totalIndexed, 1);
          expect(saved.metadataSuccess, 1);
          expect(saved.coveragePartial, isFalse);
          expect(saved.possiblePartialDocument, isFalse);
          final report = File(p.join(exports.path, saved.fileName!));
          final contents = utf8.decode(await report.readAsBytes());
          expect(contents, contains(_fixtureFileName));
          expect(contents, contains(suggestions.first.value));
          expect(contents, isNot(contains('not-selected.mp3')));
          expect(await _hash(source), taggedHash);
          expect(await _hash(outside), originalHash);
        } finally {
          inventory.dispose();
        }
        expect(tester.takeException(), isNull);
      } finally {
        if (mounted) {
          await controller!.preview.stop();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
        await _previewChannel.invokeMethod<void>('stop');
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'Windows expanded LRCLIB lyrics keeps source layout and fixed action usable',
    (tester) async {
      expect(Platform.isWindows, isTrue);
      final screenshot = File('build/ci/windows/expanded-review.png');
      final evidence = await runExpandedReviewWindowsScenario(
        tester,
        capture: (boundary) async {
          // Capture the actual Windows engine's painted frame directly. This
          // does not depend on integration_test's mobile screenshot plugin.
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            expect(bytes, isNotNull);
            await screenshot.parent.create(recursive: true);
            await screenshot.writeAsBytes(
              bytes!.buffer.asUint8List(),
              flush: true,
            );
            expect(await screenshot.length(), greaterThan(0));
            expect(image.width, 2048);
            expect(image.height, 1376);
          } finally {
            image.dispose();
          }
        },
      );
      evidence['screenshot'] = screenshot.path;
      binding.reportData = {
        ...?binding.reportData,
        'expanded_review': evidence,
      };
      // Retained by the existing Windows job's runtime.txt artifact.
      // ignore: avoid_print
      print('WINDOWS_EXPANDED_REVIEW ${jsonEncode(evidence)}');
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'real Windows preview channel rejects nonlocal sources and releases safely',
    (tester) async {
      expect(Platform.isWindows, isTrue);
      final support = await getApplicationSupportDirectory();
      final cache = await getTemporaryDirectory();
      expect(p.isAbsolute(support.path), isTrue);
      expect(p.isAbsolute(cache.path), isTrue);

      final backend = MethodChannelAudioPreviewBackend();
      final events = <AudioPreviewEvent>[];
      final subscription = backend.events.listen(events.add);
      final temporary = await Directory.systemTemp.createTemp(
        'audio_fixer_preview_',
      );
      // Windows TEMP can contain an 8.3 alias such as RUNNER~1.
      final root = Directory(await temporary.resolveSymbolicLinks());
      try {
        final initial = await backend.getState();
        expect(initial, isNotNull);
        expect(
          initial!.status,
          isIn([AudioPreviewStatus.idle, AudioPreviewStatus.stopped]),
        );
        await backend.stop();
        expect((await backend.getState())!.status, AudioPreviewStatus.stopped);

        for (final uri in [
          'https://example.invalid/never-requested.mp3',
          'file://server/share/never-opened.mp3',
          r'\\server\share\never-opened.mp3',
          'content://media/external/audio/media/1',
        ]) {
          await expectLater(
            backend.play(requestId: 101, trackId: 'rejected', uri: uri),
            throwsA(
              isA<PlatformException>().having(
                (error) => error.code,
                'code',
                'invalid_source',
              ),
            ),
          );
          expect(
            (await backend.getState())!.status,
            AudioPreviewStatus.stopped,
          );
        }

        final absent = File(p.join(root.path, '不存在 #100% 🎵.mp3'));
        await expectLater(
          backend.play(
            requestId: 102,
            trackId: 'missing-synthetic-file',
            uri: absent.uri.toString(),
          ),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'source_unavailable',
            ),
          ),
        );
        expect(await absent.exists(), isFalse);

        final playable = await File(p.join(root.path, _fixtureFileName))
            .writeAsBytes(base64Decode(_syntheticMp3Base64), flush: true);
        final playableHash = await _hash(playable);
        try {
          await backend.play(
            requestId: 103,
            trackId: 'synthetic-unicode-preview',
            uri: playable.uri.toString(),
          );
        } on PlatformException catch (error) {
          // A headless hosted runner may have no audio endpoint. Every other
          // synchronous failure, including broken URI decoding, fails this test.
          expect(error.code, 'audio_focus_denied');
        }
        await backend.stop();
        expect((await backend.getState())!.status, AudioPreviewStatus.stopped);
        final renamed = await playable.rename(p.join(root.path, '已释放 🎵.mp3'));
        await renamed.writeAsBytes(
          base64Decode(_syntheticMp3Base64),
          flush: true,
        );
        expect(await _hash(renamed), playableHash);
        await renamed.delete();
        // Allow already queued native callbacks to arrive; none may revive a
        // superseded player after the release barrier has completed.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await tester.pump();
        expect((await backend.getState())!.status, AudioPreviewStatus.stopped);

        // A stop acknowledgement is a native resource-release barrier. This
        // check works whether Media Foundation has an output device or not.
        await backend.stop();
        await backend.stop();
        await backend.pause(requestId: 999);
        await backend.seek(requestId: 999, positionMs: 0);
        final stopped = await backend.getState();
        expect(stopped!.status, AudioPreviewStatus.stopped);
        expect(stopped.positionMs, 0);
        await _waitFor(
          tester,
          () =>
              events.any((event) => event.status == AudioPreviewStatus.stopped),
          'real native preview event stream',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _previewChannel.invokeMethod<void>('stop');
        await subscription.cancel();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
