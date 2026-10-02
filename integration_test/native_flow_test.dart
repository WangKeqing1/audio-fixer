import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/batch_operation.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_importer.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// The host generates this media with generate_audio_fixtures.py and handles
// Android-owned dialogs from fresh UI hierarchies. No MethodChannel is mocked.
const _fileName = 'native_fixture.mp3';
const _unapprovedFileName = 'native_unapproved.mp3';
const _lyrics =
    '[00:00.00]Synthetic Android runtime fixture only\n'
    '[00:00.60]Native save cancellation and retry';

class _OfflineFixtureSource implements MetadataSource {
  int calls = 0;

  @override
  String get name => 'Offline synthetic fixture';

  @override
  Set<AudioField> get supportedFields => {AudioField.lyrics};

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    calls++;
    expect({_fileName, _unapprovedFileName}, contains(track.fileName));
    expect(track.detailsLoaded, isTrue);
    expect(requestedFields, {AudioField.lyrics});
    return [
      FieldSuggestion(
        field: AudioField.lyrics,
        value: _lyrics,
        source: name,
        matchDescription: 'Explicit offline test data; no provider was called.',
      ),
    ];
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition,
  String description,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 70));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native permission, reviewed-only batch original save and optional export',
    (tester) async {
      expect(Platform.isAndroid, isTrue);
      final support = await getApplicationSupportDirectory();
      final cache = await getTemporaryDirectory();
      Future<void> phase(String value) =>
          File('${support.path}/native_runtime_phase').writeAsString(value);
      Future<void> checkpoint(String value) async {
        await tester.pumpAndSettle();
        await phase(value);
        final ack = File('${support.path}/native_runtime_ack');
        final deadline = DateTime.now().add(const Duration(seconds: 35));
        while (!await ack.exists() || await ack.readAsString() != value) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Host did not capture the synthetic $value screen');
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }

      final source = _OfflineFixtureSource();
      final library = AndroidMusicLibrary(getApplicationSupportDirectory);
      final controller = LibraryController(
        store: JsonLibraryStore(getApplicationSupportDirectory),
        picker: SystemAudioPicker(),
        importer: LocalAudioImporter(getApplicationSupportDirectory),
        completion: CompletionService(sources: [source]),
        deviceLibrary: library,
        exporter: SafeAudioCopyExporter(getTemporaryDirectory),
      );
      expect(
        await library.permissionStatus(),
        AudioLibraryPermission.notRequested,
        reason: 'Run only in a clean, disposable emulator install.',
      );
      await phase('permission_deny');
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await _waitFor(
        tester,
        () => !controller.isLoading && !controller.isBusy,
        'the native permission denial',
      );
      expect(controller.loadError, isNull);
      expect(controller.libraryPermission, AudioLibraryPermission.denied);
      expect(controller.tracks, isEmpty);
      expect(find.text('允许访问音乐'), findsOneWidget);
      await checkpoint('permission_denied_ready');

      await phase('permission_grant');
      await tester.tap(find.text('允许访问音乐'));
      await _waitFor(
        tester,
        () => !controller.isBusy && controller.canReadDeviceLibrary,
        'the real permission grant and MediaStore query',
      );
      expect(await library.permissionStatus(), AudioLibraryPermission.granted);
      expect(controller.libraryError, isNull);
      final track = controller.tracks.singleWhere(
        (item) => item.fileName == _fileName,
      );
      expect(track.isDeviceTrack, isTrue);
      expect(Uri.parse(track.contentUri!).scheme, 'content');
      expect(Uri.parse(track.contentUri!).authority, 'media');
      expect(track.detailsLoaded, isFalse);

      await phase('read_details');
      await tester.enterText(find.byType(TextField).first, _fileName);
      await tester.pumpAndSettle();
      final title = find.text(track.displayTitle);
      await tester.scrollUntilVisible(
        title,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(title);
      await _waitFor(
        tester,
        () =>
            !controller.isBusy && controller.trackById(track.id)!.detailsLoaded,
        'native content-URI read and embedded tag extraction',
      );
      expect(find.byType(TrackDetailPage), findsOneWidget);
      final detailed = controller.trackById(track.id)!;
      expect(detailed.readError, isNull);
      expect(detailed.title, '夜空 – Café 🎵');
      expect(detailed.artist, '演奏者 / Sigur Rós');
      expect(detailed.album, '試験アルバム №1');
      expect(detailed.missingFields, {AudioField.lyrics});
      final coverHash = sha256
          .convert(await File(detailed.artworkPath!).readAsBytes())
          .toString();
      await checkpoint('details_ready');

      await tester.tap(find.text('补全缺失信息'));
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            find.byType(CandidateReviewPage).evaluate().isNotEmpty,
        'offline candidate review',
      );
      expect(source.calls, 1);
      expect(controller.taskForTrack(track.id)!.status, TaskStatus.needsReview);
      await tester.scrollUntilVisible(
        find.byType(Checkbox),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-original')))
            .onPressed,
        isNull,
        reason: 'Newly fetched candidates require explicit review.',
      );
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('保存到原文件（1 项）'), findsOneWidget);
      expect(find.text('导出副本（1 项）'), findsOneWidget);
      await checkpoint('review_ready');

      await phase('save_cancel');
      await tester.tap(find.text('导出副本（1 项）'));
      await _waitFor(
        tester,
        () => !controller.isBusy && controller.notice == '已取消保存，原音频未修改。',
        'cancellation of the actual Android create-document dialog',
      );
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      expect(controller.taskForTrack(track.id)!.status, TaskStatus.needsReview);
      expect(controller.taskForTrack(track.id)!.exportedCopyUri, isNull);
      expect(find.text('已取消保存，原音频未修改。'), findsWidgets);
      await checkpoint('cancelled_ready');

      await phase('save_confirm');
      await tester.tap(find.text('导出副本（1 项）'));
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            controller.taskForTrack(track.id)!.status == TaskStatus.exported,
        'a new document saved by the Android system picker',
      );
      await tester.pumpAndSettle();
      expect(find.byType(CandidateReviewPage), findsNothing);
      expect(find.byType(TrackDetailPage), findsOneWidget);
      final exported = controller.taskForTrack(track.id)!;
      expect(Uri.parse(exported.exportedCopyUri!).scheme, 'content');
      expect(exported.exportedCopyUri, isNot(track.contentUri));
      expect(controller.trackById(track.id)!.lyrics, isNull);
      await checkpoint('exported_ready');

      // Re-read through the native content URI after saving, rather than
      // trusting the controller cache. Host FFmpeg checks are independent.
      final reread = await library.readDetails(track);
      expect(reread.readError, isNull);
      expect(reread.title, detailed.title);
      expect(reread.artist, detailed.artist);
      expect(reread.album, detailed.album);
      expect(reread.lyrics, isNull);
      expect(
        sha256
            .convert(await File(reread.artworkPath!).readAsBytes())
            .toString(),
        coverHash,
      );
      // A new lookup requires fresh explicit review. The primary original-save
      // action must keep the review open when Android write consent is denied.
      await tester.tap(find.text('补全缺失信息'));
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            find.byType(CandidateReviewPage).evaluate().isNotEmpty,
        'new original-save candidate review',
      );
      await tester.scrollUntilVisible(
        find.byType(Checkbox),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isFalse,
      );
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await phase('original_cancel');
      await tester.ensureVisible(find.byKey(const ValueKey('save-original')));
      await tester.tap(find.byKey(const ValueKey('save-original')));
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            controller.taskForTrack(track.id)!.status == TaskStatus.needsReview,
        'cancellation of real Android write consent',
      );
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      expect((await library.readDetails(track)).lyrics, isNull);
      await checkpoint('original_cancelled_ready');

      // Persist one explicit approval; the other selected song stays unreviewed.
      await tester.ensureVisible(
        find.byKey(const ValueKey('approve-for-batch')),
      );
      await tester.tap(find.byKey(const ValueKey('approve-for-batch')));
      await _waitFor(
        tester,
        () => !controller.isBusy,
        'persisted field approval',
      );
      final unapproved = controller.tracks.singleWhere(
        (item) => item.fileName == _unapprovedFileName,
      );
      await controller.complete(trackIds: {unapproved.id});
      await tester.pumpAndSettle();
      expect(
        controller.taskForTrack(unapproved.id)!.status,
        TaskStatus.needsReview,
      );
      controller.selectTracks({track.id, unapproved.id});
      await checkpoint('bulk_review_ready');
      await phase('original_confirm');
      final batchSave = controller.saveSelectedCandidates();
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            controller.taskForTrack(track.id)!.status ==
                TaskStatus.savedOriginal,
        'real original write consent, backup, replacement, and read-back',
      );
      await batchSave;
      expect(controller.batchOperation!.kind, BatchOperationKind.saveOriginal);
      expect(controller.batchOperation!.totalCount, 2);
      expect(controller.batchOperation!.completedCount, 2);
      expect(controller.batchOperation!.savedOriginalCount, 1);
      expect(controller.batchOperation!.skippedCount, 1);
      expect(controller.batchOperation!.failedCount, 0);
      expect(controller.batchOperation!.isRunning, isFalse);
      final savedOriginal = controller.taskForTrack(track.id)!;
      final savedDetails = await library.readDetails(
        controller.trackById(track.id)!,
      );
      expect(savedDetails.lyrics, _lyrics);
      expect(savedDetails.title, detailed.title);
      expect(savedDetails.artist, detailed.artist);
      expect(savedDetails.album, detailed.album);
      expect((await library.readDetails(unapproved)).lyrics, isNull);
      expect(
        sha256
            .convert(await File(savedDetails.artworkPath!).readAsBytes())
            .toString(),
        coverHash,
      );
      await checkpoint('saved_ready');

      for (final name in ['device_library_read', 'tagged_exports']) {
        final directory = Directory('${cache.path}/$name');
        if (await directory.exists()) {
          expect(
            await directory.list().toList(),
            isEmpty,
            reason: 'Temporary read/export copies must be released.',
          );
        }
      }
      final persisted = await JsonLibraryStore(getApplicationSupportDirectory)
          .load();
      expect(
        persisted.tasks.singleWhere((task) => task.trackId == track.id).status,
        TaskStatus.savedOriginal,
      );
      expect(persisted.batchOperation!.savedOriginalCount, 1);
      expect(persisted.batchOperation!.skippedCount, 1);
      await File('${support.path}/native_runtime_result.json').writeAsString(
        jsonEncode({
          'passed': true,
          'synthetic_only': true,
          'mocked_native_channels': false,
          'online_provider_calls': 0,
          'offline_source_calls': source.calls,
          'source_uri': track.contentUri,
          'export_uri': exported.exportedCopyUri,
          'original_save_status': savedOriginal.status.name,
          'unapproved_source_uri': unapproved.contentUri,
          'batch_saved_original': controller.batchOperation!.savedOriginalCount,
          'batch_skipped_unapproved': controller.batchOperation!.skippedCount,
          'cover_sha256': coverHash,
          'expected_tags': {'lyrics': _lyrics},
          'checks': [
            'real_permission_deny_and_retry_grant',
            'mediastore_query_and_content_uri_read',
            'real_widgets_and_native_bridge',
            'unicode_tags_and_embedded_cover_read',
            'offline_candidate_review',
            'new_candidates_unchecked_until_explicit_review',
            'system_save_cancel_retains_review_and_task',
            'system_save_retry_creates_new_document',
            'source_unchanged_after_export_and_cancel',
            'real_original_write_consent_cancel_and_retry',
            'approved_only_bulk_original_save',
            'unapproved_selected_song_unchanged',
            'batch_result_counters_persisted',
            'original_tags_and_cover_reread',
            'temporary_copies_released',
            'original_save_record_persisted',
          ],
        }),
      );
      await phase('complete');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
