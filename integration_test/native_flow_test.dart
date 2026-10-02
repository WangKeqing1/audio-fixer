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
import 'package:audio_fixer/features/settings/settings_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

// This runs against indexed synthetic Android media and production widgets.
// Re-mounting a new controller checks persisted initialization, not process kill.
Future<LibraryController> _verifyLibraryFilters(
  WidgetTester tester,
  LibraryController controller,
  LibraryController Function() createController,
  Future<void> Function(String) checkpoint,
) async {
  const seededRows = 36;
  expect(controller.settings.excludeShortAudio, isFalse);
  expect(controller.settings.excludedFolders, isEmpty);
  expect(controller.allTracks.length, seededRows);
  expect(controller.tracks.length, seededRows);
  final initialIds = controller.allTracks.map((track) => track.id).toSet();
  AudioTrack named(String name) =>
      controller.allTracks.singleWhere((track) => track.fileName == name);
  for (final milliseconds in [59999, 60000, 60001]) {
    expect(
      named('native_duration_$milliseconds.wav').durationMs,
      milliseconds,
      reason:
          'Native MediaStore duration must preserve the exact WAV boundary.',
    );
    expect(
      named('native_duration_$milliseconds.wav').indexedDurationMs,
      milliseconds,
    );
  }
  final excludedParent = named('native_parent.wav');
  final excludedNested = named('native_nested.wav');
  final retainedSibling = named('native_neighbor.wav');
  expect(excludedParent.folder, isNotNull);
  expect(excludedParent.volumeName, isNotEmpty);
  expect(excludedParent.relativePath, 'Music/AudioFixerSynthetic/Exclude/');
  expect(
    excludedNested.relativePath,
    'Music/AudioFixerSynthetic/Exclude/Nested/',
  );
  expect(
    retainedSibling.relativePath,
    'Music/AudioFixerSynthetic/ExcludeNeighbor/',
  );
  expect(excludedNested.volumeName, excludedParent.volumeName);
  final excludedFolder = excludedParent.folder!;

  final list = find.byKey(const PageStorageKey('library-scroll-view'));
  final toolbar = find.byKey(const ValueKey('fixed-library-selection-toolbar'));
  final selectVisible = find.byKey(const ValueKey('select-visible-tracks'));
  final toggleSelection = find.byKey(
    const ValueKey('toggle-library-selection'),
  );
  await tester.scrollUntilVisible(
    toggleSelection,
    220,
    scrollable: find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first,
  );
  await tester.tap(toggleSelection);
  await tester.pumpAndSettle();
  expect(toolbar, findsOneWidget);
  await tester.tap(selectVisible);
  await tester.pumpAndSettle();
  expect(controller.selectedTrackIds, initialIds);
  final toolbarBefore = tester.getRect(toolbar);
  final query = find.byKey(const ValueKey('bulk-query-selected'));
  expect(query.hitTestable(), findsOneWidget);
  await checkpoint('selection_toolbar_top');
  for (var gesture = 0; gesture < 7; gesture++) {
    await tester.drag(list, const Offset(0, -640));
    await tester.pumpAndSettle();
  }
  final scrollable = tester.state<ScrollableState>(
    find.descendant(of: list, matching: find.byType(Scrollable)).first,
  );
  expect(scrollable.position.pixels, greaterThan(1200));
  expect(tester.getRect(toolbar), toolbarBefore);
  expect(query.hitTestable(), findsOneWidget);
  expect(selectVisible.hitTestable(), findsOneWidget);
  await tester.tap(query);
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
  await tester.tap(find.text('取消'));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsNothing);
  expect(controller.selectedTrackIds, initialIds);
  expect(tester.getRect(toolbar), toolbarBefore);
  expect(tester.takeException(), isNull);
  await checkpoint('selection_toolbar_scrolled');

  Future<void> openSettings() async {
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
  }

  Future<void> tapSetting(String key) async {
    final control = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(
      control,
      240,
      scrollable: find.descendant(
        of: find.byType(SettingsPage),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(control);
    await tester.pumpAndSettle();
    await _waitFor(tester, () => !controller.isBusy, '$key persistence');
  }

  Future<void> toggleExcludedFolder() async {
    await tapSetting('manage-excluded-folders');
    final page = find.byKey(const ValueKey('folder-filter-page'));
    expect(page, findsOneWidget);
    final row = find.byKey(ValueKey('exclude-folder-${excludedFolder.id}'));
    await tester.scrollUntilVisible(
      row,
      240,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('exclude-folder-list')),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 50,
    );
    // Native scrolling can still be settling when scrollUntilVisible returns.
    // A row partly below the viewport must never tap the fixed Apply footer.
    await tester.pumpAndSettle();
    final checkbox = find.descendant(of: row, matching: find.byType(Checkbox));
    await Scrollable.ensureVisible(tester.element(checkbox), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(checkbox.hitTestable(), findsOneWidget);
    final wasChecked = tester.widget<Checkbox>(checkbox).value;
    await tester.tap(checkbox.hitTestable());
    await tester.pumpAndSettle();
    expect(page, findsOneWidget);
    expect(tester.widget<Checkbox>(checkbox).value, !wasChecked!);
    final apply = find.byKey(const ValueKey('apply-folder-exclusions'));
    expect(apply.hitTestable(), findsOneWidget);
    await tester.tap(apply.hitTestable());
    await _waitFor(
      tester,
      () => !controller.isBusy && page.evaluate().isEmpty,
      'folder exclusion persistence',
    );
    await tester.pumpAndSettle();
  }

  await openSettings();
  await tapSetting('exclude-short-audio');
  expect(controller.settings.excludeShortAudio, isTrue);
  expect(
    controller.tracks.map((track) => track.fileName),
    isNot(contains('native_duration_59999.wav')),
  );
  expect(
    controller.tracks.map((track) => track.fileName),
    containsAll(['native_duration_60000.wav', 'native_duration_60001.wav']),
  );
  expect(controller.tracks.length, 5);
  expect(
    controller.selectedTrackIds,
    controller.tracks.map((track) => track.id).toSet(),
  );
  final durationEligibleIds = controller.selectedTrackIds;
  await tapSetting('exclude-short-audio');
  expect(controller.tracks.length, seededRows);
  expect(
    controller.selectedTrackIds,
    durationEligibleIds,
    reason: 'Restoring short audio must not silently reselect excluded songs.',
  );
  await tapSetting('exclude-short-audio');
  expect(controller.tracks.length, 5);
  await toggleExcludedFolder();
  expect(
    controller.settings.excludedFolders.map((folder) => folder.id),
    contains(excludedFolder.id),
  );
  expect(controller.tracks.length, 3);
  expect(controller.trackById(excludedParent.id), isNull);
  expect(controller.trackById(excludedNested.id), isNull);
  expect(
    controller.tracks.map((track) => track.id),
    isNot(contains(excludedParent.id)),
  );
  expect(
    controller.tracks.map((track) => track.id),
    isNot(contains(excludedNested.id)),
  );
  expect(
    controller.tracks.map((track) => track.id),
    contains(retainedSibling.id),
  );
  expect(controller.allTracks.map((track) => track.id).toSet(), initialIds);
  expect(
    controller.selectedTrackIds,
    controller.tracks.map((track) => track.id).toSet(),
  );
  final folderEligibleIds = controller.selectedTrackIds;
  await toggleExcludedFolder();
  expect(controller.tracks.length, 5);
  expect(
    controller.selectedTrackIds,
    folderEligibleIds,
    reason: 'Restoring a folder must not silently reselect excluded songs.',
  );
  await toggleExcludedFolder();
  expect(controller.tracks.length, 3);
  expect(controller.selectedTrackIds, folderEligibleIds);
  await checkpoint('library_filters_ready');
  final stored = await JsonLibraryStore(getApplicationSupportDirectory).load();
  expect(stored.tracks.map((track) => track.id).toSet(), initialIds);
  expect(stored.settings.excludeShortAudio, isTrue);
  expect(
    stored.settings.excludedFolders.map((folder) => folder.id),
    contains(excludedFolder.id),
  );

  // Dispose the original app/controller and create a real new one over the same
  // JSON store and Android bridge. No native channels or storage are mocked.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  controller = createController();
  await tester.pumpWidget(AudioFixerApp(controller: controller));
  await _waitFor(
    tester,
    () => !controller.isLoading && !controller.isBusy,
    'fresh persisted filter initialization and MediaStore rescan',
  );
  expect(controller.loadError, isNull);
  expect(controller.libraryError, isNull);
  expect(controller.settings.excludeShortAudio, isTrue);
  expect(
    controller.settings.excludedFolders.map((folder) => folder.id),
    contains(excludedFolder.id),
  );
  expect(controller.allTracks.map((track) => track.id).toSet(), initialIds);
  expect(controller.tracks.map((track) => track.fileName).toSet(), {
    'native_duration_60000.wav',
    'native_duration_60001.wav',
    'native_neighbor.wav',
  });
  expect(controller.selectedTrackIds, isEmpty);
  await checkpoint('library_filters_reloaded');

  // Restore visibility through the same controls before running the pre-existing
  // short-MP3 review/export/original-save acceptance flow.
  await openSettings();
  await toggleExcludedFolder();
  await tapSetting('exclude-short-audio');
  expect(controller.settings.excludedFolders, isEmpty);
  expect(controller.settings.excludeShortAudio, isFalse);
  expect(controller.tracks.map((track) => track.id).toSet(), initialIds);
  expect(controller.selectedTrackIds, isEmpty);
  await tester.tap(find.text('音乐库'));
  await tester.pumpAndSettle();
  return controller;
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
      LibraryController createController() => LibraryController(
        store: JsonLibraryStore(getApplicationSupportDirectory),
        picker: SystemAudioPicker(),
        importer: LocalAudioImporter(getApplicationSupportDirectory),
        completion: CompletionService(sources: [source]),
        deviceLibrary: library,
        exporter: SafeAudioCopyExporter(getTemporaryDirectory),
      );
      var controller = createController();
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
      controller = await _verifyLibraryFilters(
        tester,
        controller,
        createController,
        checkpoint,
      );
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
      expect(detailed.indexedDurationMs, track.indexedDurationMs);
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
      // Use the actual task-selection and bulk action widgets so native
      // evidence also shows reviewed counts and the final batch result panel.
      // pageBack() matches the English 'Back' tooltip, not this Chinese UI.
      expect(find.byType(TrackDetailPage), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(TrackDetailPage), findsNothing);
      await tester.tap(find.text('补全任务'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('select-all-task-tracks')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('select-all-task-tracks')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(controller.selectedTrackIds, {track.id, unapproved.id});
      expect(find.text('已选 2 首'), findsOneWidget);
      expect(find.text('已确认 1 首 · 仅保存已确认资料'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fixed-task-selection-toolbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bulk-save-original')).hitTestable(),
        findsOneWidget,
      );
      await checkpoint('bulk_review_ready');
      await phase('original_confirm');
      await tester.tap(
        find.byKey(const ValueKey('bulk-save-original')).hitTestable(),
      );
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            controller.taskForTrack(track.id)!.status ==
                TaskStatus.savedOriginal,
        'real original write consent, backup, replacement, and read-back',
      );
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
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('batch-progress')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('batch-progress')),
          matching: find.text(controller.batchOperation!.summary),
        ),
        findsOneWidget,
      );
      await checkpoint('saved_ready');

      // The batch grant is already live for this MediaStore URI. A deliberately
      // stale source snapshot must be rejected by the real native guard without
      // another write or a new authorization sheet.
      const native = MethodChannel('audio_fixer/device_library');
      final guardWork = Directory(
        '${cache.path}/tagged_exports/export_native_guard',
      );
      await guardWork.create(recursive: true);
      String? guardReadCopy;
      try {
        guardReadCopy = await native.invokeMethod<String>('copyForRead', {
          'uri': track.contentUri,
        });
        final currentBytes = await File(guardReadCopy!).readAsBytes();
        final expectedHash = sha256.convert(currentBytes).toString();
        final tagged = await File('${guardWork.path}/tagged.mp3')
            .writeAsBytes(currentBytes);
        await native.invokeMethod<void>('releaseReadCopy', {
          'path': guardReadCopy,
        });
        guardReadCopy = null;
        await expectLater(
          native.invokeMethod<String>('saveAudioOriginal', {
            'path': tagged.path,
            'sourceUri': track.contentUri,
            'sourcePath': null,
            'sourceSha256': List.filled(64, '0').join(),
          }),
          throwsA(
            isA<PlatformException>()
                .having((error) => error.code, 'code', 'original_save_failed')
                .having(
                  (error) => error.message,
                  'message',
                  contains('原音频已变化'),
                ),
          ),
        );
        guardReadCopy = await native.invokeMethod<String>('copyForRead', {
          'uri': track.contentUri,
        });
        expect(
          sha256.convert(await File(guardReadCopy!).readAsBytes()).toString(),
          expectedHash,
        );
        expect(await native.invokeMethod<String>('recoverExport'), isNull);
      } finally {
        if (guardReadCopy != null) {
          await native.invokeMethod<void>('releaseReadCopy', {
            'path': guardReadCopy,
          });
        }
        await guardWork.delete(recursive: true);
      }

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
          'library_filters': {
            'native_boundary_duration_ms': [59999, 60000, 60001],
            'seeded_media_rows': 36,
            'fixed_toolbar_after_long_scroll': true,
            'strict_under_one_minute': true,
            'parent_folder_includes_nested_not_prefix_sibling': true,
            'excluded_tracks_retained_in_store': true,
            'selection_pruned_to_eligible_tracks': true,
            'fresh_controller_initialization': true,
            'physical_process_restart': false,
          },
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
            'fixed_library_selection_toolbar_after_long_scroll',
            'fixed_toolbar_query_dialog_cancel_keeps_selection',
            'native_duration_59999_60000_60001_boundary',
            'native_volume_aware_parent_folder_exclusion',
            'folder_sibling_prefix_stays_visible',
            'filters_persist_across_real_controller_initialization',
            'excluded_backing_tracks_persist_and_selection_is_pruned',
            'disabling_filters_restores_native_tracks',
            'unicode_tags_and_embedded_cover_read',
            'offline_candidate_review',
            'new_candidates_unchecked_until_explicit_review',
            'system_save_cancel_retains_review_and_task',
            'system_save_retry_creates_new_document',
            'source_unchanged_after_export_and_cancel',
            'real_original_write_consent_cancel_and_retry',
            'task_multiselect_and_bulk_save_widgets',
            'approved_only_bulk_original_save',
            'unapproved_selected_song_unchanged',
            'batch_result_counters_persisted',
            'original_tags_and_cover_reread',
            'mediastore_stale_source_hash_rejected_before_write',
            'source_hash_unchanged_after_native_guard_rejection',
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
