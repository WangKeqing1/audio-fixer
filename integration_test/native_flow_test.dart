import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/batch_operation.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_importer.dart';
import 'package:audio_fixer/core/services/audio_preview_service.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/settings/settings_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:audio_fixer/shared/widgets/track_artwork.dart';
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
const _previewChannel = MethodChannel('audio_fixer/audio_preview');
const _lyrics =
    '[00:00.00]Synthetic Android runtime fixture only\n'
    '[00:00.60]Native save cancellation and retry';

class _OfflineFixtureSource implements MetadataSource {
  int calls = 0;
  bool returnNoMatch = false;

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
    if (returnNoMatch) return [];
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

Future<void> _searchLibrary(WidgetTester tester, String query) async {
  final list = find.byKey(const PageStorageKey('library-scroll-view'));
  final scroll = find
      .descendant(of: list, matching: find.byType(Scrollable))
      .first;
  final search = find.descendant(of: list, matching: find.byType(TextField));
  // A native IME can retain a previous editing session while the list has
  // scrolled. Return to the real visible search control before each edit.
  await tester.scrollUntilVisible(search, -220, scrollable: scroll);
  await tester.pumpAndSettle();
  expect(search.hitTestable(), findsOneWidget);
  await tester.tap(search.hitTestable());
  await tester.pumpAndSettle();
  await tester.enterText(search, query);
  await tester.pumpAndSettle();
  expect(tester.widget<TextField>(search).controller!.text, query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
  expect(tester.widget<TextField>(search).controller!.text, query);
}

Future<void> _verifyInitialCover(
  WidgetTester tester,
  LibraryController controller,
  AndroidMusicLibrary library,
  Future<void> Function(String) checkpoint,
  String checkpointName,
) async {
  final track = controller.tracks.singleWhere(
    (item) => item.fileName == _fileName,
  );
  expect(track.detailsLoaded, isFalse);
  expect(track.artworkPath, isNull);
  final list = find.byKey(const PageStorageKey('library-scroll-view'));
  await _searchLibrary(tester, _fileName);
  final cover = find.byKey(ValueKey('library-artwork-${track.id}'));
  await tester.scrollUntilVisible(
    cover,
    220,
    scrollable: find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first,
  );
  final artwork = find.descendant(
    of: cover,
    matching: find.byType(TrackArtwork),
  );
  await _waitFor(
    tester,
    () =>
        artwork.evaluate().isNotEmpty &&
        tester.widget<TrackArtwork>(artwork).bytes != null,
    'initial embedded cover thumbnail without a detail read',
  );
  final displayed = tester.widget<TrackArtwork>(artwork).bytes!;
  expect(displayed.length, inInclusiveRange(1, 256 * 1024));
  expect(
    find.descendant(of: cover, matching: find.byType(Image)),
    findsOneWidget,
  );
  final pixels = find.descendant(of: cover, matching: find.byType(RawImage));
  await _waitFor(
    tester,
    () =>
        pixels.evaluate().isNotEmpty &&
        tester.widget<RawImage>(pixels).image != null,
    'decoded thumbnail pixels in the initial list',
  );
  expect(controller.trackById(track.id)!.detailsLoaded, isFalse);
  expect(controller.trackById(track.id)!.artworkPath, isNull);
  expect(await library.readArtworkThumbnail(track), orderedEquals(displayed));
  await checkpoint(checkpointName);

  final noCover = controller.tracks.singleWhere(
    (item) => item.fileName == 'native_duration_60000.wav',
  );
  expect(await library.readArtworkThumbnail(noCover), isNull);
  await _searchLibrary(tester, noCover.fileName);
  final emptyCover = find.byKey(ValueKey('library-artwork-${noCover.id}'));
  await tester.scrollUntilVisible(
    emptyCover,
    180,
    scrollable: find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first,
  );
  await tester.pumpAndSettle();
  expect(
    find.descendant(of: emptyCover, matching: find.byType(Image)),
    findsNothing,
  );
  expect(controller.trackById(noCover.id)!.detailsLoaded, isFalse);
  await _searchLibrary(tester, '');
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

Future<Map<String, dynamic>> _nativePreviewState() async =>
    (await _previewChannel.invokeMapMethod<String, dynamic>('getState'))!;

Future<Map<String, dynamic>> _waitForNativePreview(
  WidgetTester tester,
  bool Function(Map<String, dynamic>) condition,
  String description,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (true) {
    final state = await _nativePreviewState();
    if (condition(state)) return state;
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $description; native state: $state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

// Actual MediaPlayer state is read independently of the Flutter display. Only
// generated MediaStore WAVs and app-private copies of those WAVs are played.
Future<Map<String, Object?>> _verifyAudioPreview(
  WidgetTester tester,
  LibraryController controller,
  Future<void> Function(String) checkpoint,
  Future<void> Function(String) phase,
  Directory support,
) async {
  final first = controller.tracks.singleWhere(
    (track) => track.fileName == 'native_duration_60000.wav',
  );
  final second = controller.tracks.singleWhere(
    (track) => track.fileName == 'native_duration_60001.wav',
  );
  expect(first.contentUri, startsWith('content://media/'));
  final preview = controller.preview;
  final list = find.byKey(const PageStorageKey('library-scroll-view'));
  final scrollable = find
      .descendant(of: list, matching: find.byType(Scrollable))
      .first;
  final player = find.byKey(const ValueKey('audio-preview-player'));
  final toggle = find.byKey(const ValueKey('audio-preview-toggle'));
  Future<void> show(Finder target) async {
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(target, 220, scrollable: scrollable);
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
  }

  // Enter selection through its real controls, then establish an independent
  // selection whose identity every playback action must preserve.
  await show(find.byKey(const ValueKey('toggle-library-selection')));
  await tester.tap(find.byKey(const ValueKey('toggle-library-selection')));
  await tester.pumpAndSettle();
  final selected = find.byKey(ValueKey('select-track-${first.id}'));
  await show(selected);
  await tester.tap(selected);
  await tester.pumpAndSettle();
  final selection = Set<String>.of(controller.selectedTrackIds);
  expect(selection, {first.id});
  Future<void> playRow(AudioTrack track) async {
    final play = find.byKey(ValueKey('preview-track-${track.id}'));
    await show(play);
    await tester.tap(play.hitTestable());
    await _waitForNativePreview(
      tester,
      (state) => state['trackId'] == track.id && state['status'] == 'playing',
      'the actual MediaStore preview for ${track.fileName}',
    );
    await _waitFor(tester, () => preview.isPlaying, 'playing UI event');
    expect(controller.selectedTrackIds, selection);
  }

  await playRow(first);
  final progressing = await _waitForNativePreview(
    tester,
    (state) => (state['positionMs'] as num) >= 750,
    'native playback position advancing',
  );
  expect(progressing['durationMs'], inInclusiveRange(59900, 60100));
  expect(first.detailsLoaded, isFalse);
  expect(controller.trackById(first.id)!.detailsLoaded, isFalse);
  await tester.pumpAndSettle();
  final playerRect = tester.getRect(player);
  for (var gesture = 0; gesture < 7; gesture++) {
    await tester.drag(list, const Offset(0, -640));
    await tester.pumpAndSettle();
  }
  expect(
    tester.state<ScrollableState>(scrollable).position.pixels,
    greaterThan(1200),
  );
  expect(tester.getRect(player), playerRect);
  expect(toggle.hitTestable(), findsOneWidget);
  expect(
    find.byKey(const ValueKey('fixed-library-selection-toolbar')),
    findsOneWidget,
  );
  expect(controller.selectedTrackIds, selection);
  await checkpoint('preview_playing_scrolled');

  await tester.tap(toggle.hitTestable());
  final paused = await _waitForNativePreview(
    tester,
    (state) => state['status'] == 'paused',
    'native pause',
  );
  await Future<void>.delayed(const Duration(milliseconds: 800));
  final stillPaused = await _nativePreviewState();
  expect(stillPaused['status'], 'paused');
  expect(
    (stillPaused['positionMs'] as num) - (paused['positionMs'] as num),
    inInclusiveRange(0, 150),
  );
  await tester.pumpAndSettle();
  final seek = find.byKey(const ValueKey('audio-preview-seek'));
  expect(tester.widget<Slider>(seek).onChanged, isNotNull);
  await tester.tapAt(tester.getRect(seek).center);
  final sought = await _waitForNativePreview(
    tester,
    (state) =>
        state['status'] == 'paused' &&
        (state['positionMs'] as num) >= 25000 &&
        (state['positionMs'] as num) <= 35000,
    'native seek through the visible slider',
  );
  expect(controller.selectedTrackIds, selection);
  await checkpoint('preview_paused_seeked');
  await tester.tap(toggle.hitTestable());
  await _waitForNativePreview(
    tester,
    (state) => state['status'] == 'playing',
    'native resume',
  );

  // Move up to the other long row without changing the search or selection.
  final scrollState = tester.state<ScrollableState>(scrollable);
  scrollState.position.jumpTo(0);
  await tester.pumpAndSettle();
  await playRow(second);
  final switched = await _nativePreviewState();
  expect(switched['requestId'], isNot(progressing['requestId']));
  expect(switched['trackId'], second.id);
  await tester.tap(find.byKey(const ValueKey('audio-preview-close')));
  await _waitForNativePreview(
    tester,
    (state) => state['status'] == 'stopped',
    'native close/release',
  );
  await tester.pumpAndSettle();
  expect(player, findsNothing);
  expect(controller.selectedTrackIds, selection);

  await controller.refreshLibrary();
  await tester.pumpAndSettle();
  await playRow(controller.trackById(first.id)!);
  await tester.tap(find.text('设置'));
  await tester.pumpAndSettle();
  await _waitForNativePreview(
    tester,
    (state) => state['status'] == 'stopped',
    'tab departure release',
  );
  await tester.tap(find.text('音乐库'));
  await tester.pumpAndSettle();
  // A row tap in selection mode intentionally selects. Leave that mode through
  // its visible control before testing normal detail navigation.
  await tester.tap(find.byKey(const ValueKey('toggle-library-selection')));
  await tester.pumpAndSettle();
  expect(controller.selectedTrackIds, isEmpty);
  selection.clear();
  await playRow(controller.trackById(first.id)!);
  final title = find.text(first.displayTitle);
  // The same title is also visible in the player; tap only the library row.
  final rowTitle = find.descendant(of: list, matching: title);
  await show(rowTitle);
  await tester.tap(rowTitle.hitTestable());
  await _waitFor(
    tester,
    () =>
        find.byType(TrackDetailPage).evaluate().isNotEmpty &&
        !controller.isBusy,
    'detail navigation',
  );
  expect((await _nativePreviewState())['status'], 'stopped');
  await tester.tap(find.byKey(const ValueKey('close-selected-song')));
  await tester.pumpAndSettle();
  await playRow(controller.trackById(first.id)!);

  // Host presses Android Home, observes the launcher, and relaunches this QA
  // Activity. No synthetic Flutter lifecycle event stands in for backgrounding.
  await phase('preview_background');
  final ack = File('${support.path}/native_runtime_ack');
  final deadline = DateTime.now().add(const Duration(seconds: 35));
  while (!await ack.exists() ||
      await ack.readAsString() != 'preview_background') {
    if (DateTime.now().isAfter(deadline)) {
      fail('Host did not background/resume QA app');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  await _waitForNativePreview(
    tester,
    (state) => state['status'] == 'stopped',
    'Android background release',
  );
  await _waitFor(tester, () => !controller.isBusy, 'resume refresh');
  expect(preview.track, isNull);
  expect(controller.selectedTrackIds, selection);
  await checkpoint('preview_background_stopped');

  // Import from a temporary native read copy using the production importer.
  // The source descriptor and copied fixture are released before cleanup.
  const libraryChannel = MethodChannel('audio_fixer/device_library');
  final readCopy = await libraryChannel.invokeMethod<String>('copyForRead', {
    'uri': first.contentUri,
  });
  late AudioTrack imported;
  try {
    imported = await LocalAudioImporter(getApplicationSupportDirectory).import(
      AudioSelection(name: first.fileName, openRead: File(readCopy!).openRead),
    );
  } finally {
    await libraryChannel.invokeMethod<void>('releaseReadCopy', {
      'path': readCopy,
    });
  }
  expect(imported.isDeviceTrack, isFalse);
  expect(imported.localPath, startsWith(support.path));
  final importedHash = sha256
      .convert(await File(imported.localPath).readAsBytes())
      .toString();
  expect(imported.id, importedHash);
  await preview.play(imported);
  await _waitForNativePreview(
    tester,
    (state) => state['trackId'] == imported.id && state['status'] == 'playing',
    'app-private imported-copy playback',
  );
  await preview.stop();
  expect((await _nativePreviewState())['status'], 'stopped');
  await File(imported.localPath).delete();

  final corrupt = File('${support.path}/native_preview_corrupt.wav');
  await corrupt.writeAsString('authored synthetic invalid audio');
  Future<String> expectPreviewError(String id, String path) async {
    await preview.play(
      AudioTrack(
        id: id,
        fileName: '$id.wav',
        localPath: path,
        sizeBytes: 0,
        importedAt: DateTime.now(),
      ),
    );
    final failure = await _waitForNativePreview(
      tester,
      (state) => state['trackId'] == id && state['status'] == 'error',
      'native failure for $id',
    );
    await _waitFor(
      tester,
      () => preview.status == AudioPreviewStatus.error,
      'visible preview error',
    );
    expect(preview.errorMessage, isNotEmpty);
    expect(controller.selectedTrackIds, selection);
    return failure['errorCode'] as String;
  }

  late String corruptError;
  late String missingError;
  try {
    corruptError = await expectPreviewError(
      'native-preview-corrupt',
      corrupt.path,
    );
    expect({
      'unsupported_format',
      'playback_failed',
      'source_unavailable',
    }, contains(corruptError));
    missingError = await expectPreviewError(
      'native-preview-missing',
      '${support.path}/native_preview_missing.wav',
    );
    expect(missingError, 'source_unavailable');
    await checkpoint('preview_missing_error');
  } finally {
    await preview.stop();
    await corrupt.delete();
  }
  await playRow(controller.trackById(second.id)!);
  await preview.stop();
  expect((await _nativePreviewState())['status'], 'stopped');
  await tester.pumpAndSettle();
  expect(controller.selectedTrackIds, isEmpty);
  expect(tester.takeException(), isNull);
  return {
    'source_kind': 'mediastore_and_private_import',
    'first_duration_ms': progressing['durationMs'],
    'first_progress_ms': progressing['positionMs'],
    'paused_position_ms': paused['positionMs'],
    'paused_after_wait_ms': stillPaused['positionMs'],
    'seek_position_ms': sought['positionMs'],
    'imported_copy_sha256': importedHash,
    'corrupt_error_code': corruptError,
    'missing_error_code': missingError,
    'selection_unchanged': true,
    'player_pinned_after_scroll': true,
    'pause_resume_seek_switch_stop': true,
    'replay_after_refresh': true,
    'detail_and_tab_release': true,
    'android_home_resume_release': true,
    'error_then_valid_replay': true,
    'speaker_output_assessed': false,
  };
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
    await tester.pumpAndSettle();
    final switchControl = find.descendant(
      of: control,
      matching: find.byType(Switch),
    );
    final wasEnabled = switchControl.evaluate().isEmpty
        ? null
        : tester.widget<Switch>(switchControl).value;
    final target = wasEnabled == null ? control : switchControl;
    await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
    await tester.tap(target.hitTestable());
    await tester.pumpAndSettle();
    await _waitFor(tester, () => !controller.isBusy, '$key persistence');
    if (wasEnabled != null) {
      expect(tester.widget<Switch>(switchControl).value, !wasEnabled);
    }
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

Future<void> _tapMissingOnly(WidgetTester tester) async {
  final action = find.byKey(const ValueKey('complete-missing-only'));
  final scroll = find
      .descendant(
        of: find.byType(TrackDetailPage),
        matching: find.byType(Scrollable),
      )
      .first;
  if (action.evaluate().isEmpty) {
    final disclosure = find.text('其他修复方式');
    await tester.scrollUntilVisible(disclosure, 180, scrollable: scroll);
    await tester.tap(disclosure);
    await tester.pumpAndSettle();
  }
  await tester.scrollUntilVisible(action, 180, scrollable: scroll);
  await tester.tap(action.hitTestable());
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
      await _verifyInitialCover(
        tester,
        controller,
        library,
        checkpoint,
        'initial_cover_ready',
      );
      controller = await _verifyLibraryFilters(
        tester,
        controller,
        createController,
        checkpoint,
      );
      await _verifyInitialCover(
        tester,
        controller,
        library,
        checkpoint,
        'initial_cover_reloaded',
      );
      final previewEvidence = await _verifyAudioPreview(
        tester,
        controller,
        checkpoint,
        phase,
        support,
      );
      final track = controller.tracks.singleWhere(
        (item) => item.fileName == _fileName,
      );
      expect(track.isDeviceTrack, isTrue);
      expect(Uri.parse(track.contentUri!).scheme, 'content');
      expect(Uri.parse(track.contentUri!).authority, 'media');
      expect(track.detailsLoaded, isFalse);

      await phase('read_details');
      await _searchLibrary(tester, _fileName);
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

      // Missing search results do not imply instrumental music. The user must
      // explicitly mark it, and only the app catalog should change.
      source.returnNoMatch = true;
      await _tapMissingOnly(tester);
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            controller.taskForTrack(track.id)?.status == TaskStatus.noMatch,
        'an explicit no-match lyric result',
      );
      expect(controller.trackById(track.id)!.isInstrumental, isFalse);
      final instrumental = find.byKey(ValueKey('instrumental-${track.id}'));
      await tester.scrollUntilVisible(
        instrumental,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(instrumental),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(instrumental.hitTestable());
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            controller.trackById(track.id)!.isInstrumental,
        'explicit app-local instrumental setting',
      );
      expect(controller.trackById(track.id)!.missingFields, isEmpty);
      final callsBeforeSkippedQuery = source.calls;
      await controller.complete(track: controller.trackById(track.id)!);
      expect(
        source.calls,
        callsBeforeSkippedQuery,
        reason: 'An instrumental annotation must stop repeated lyric requests.',
      );
      final unchanged = await library.readDetails(
        controller.trackById(track.id)!,
      );
      expect(unchanged.lyrics, isNull);
      expect(
        sha256
            .convert(await File(unchanged.artworkPath!).readAsBytes())
            .toString(),
        coverHash,
      );
      final annotatedStore = await JsonLibraryStore(
        getApplicationSupportDirectory,
      ).load();
      expect(
        annotatedStore.tracks
            .singleWhere((item) => item.id == track.id)
            .isInstrumental,
        isTrue,
      );
      await checkpoint('instrumental_marked_ready');

      // Fresh app/controller initialization uses the real persistent JSON store.
      // This proves reload behavior without claiming a timed process-kill test.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      controller = createController();
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await _waitFor(
        tester,
        () => !controller.isLoading && !controller.isBusy,
        'instrumental annotation reload',
      );
      expect(controller.trackById(track.id)!.isInstrumental, isTrue);
      await controller.refreshLibrary();
      expect(controller.trackById(track.id)!.isInstrumental, isTrue);
      await _searchLibrary(tester, _fileName);
      final restoredTitle = find.text(track.displayTitle);
      await tester.scrollUntilVisible(
        restoredTitle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(restoredTitle);
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            find.byType(TrackDetailPage).evaluate().isNotEmpty,
        'reloaded detail page',
      );
      await tester.scrollUntilVisible(
        instrumental,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(instrumental),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      expect(find.text('取消纯音乐标记'), findsOneWidget);
      await tester.tap(instrumental.hitTestable());
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            !controller.trackById(track.id)!.isInstrumental,
        'explicit instrumental annotation removal',
      );
      expect(controller.trackById(track.id)!.missingFields, {
        AudioField.lyrics,
      });
      await checkpoint('instrumental_unmarked_ready');
      source.returnNoMatch = false;

      await _tapMissingOnly(tester);
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            find.byType(CandidateReviewPage).evaluate().isNotEmpty,
        'offline candidate review',
      );
      expect(source.calls, 2);
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
      expect(find.text('应用建议（1 项）'), findsOneWidget);
      expect(find.text('导出副本'), findsOneWidget);
      await checkpoint('review_ready');

      await phase('save_cancel');
      await tester.tap(find.text('导出副本'));
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
      await tester.tap(find.text('导出副本'));
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
      await _tapMissingOnly(tester);
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
      final previewSource = controller.tracks.singleWhere(
        (item) => item.fileName == 'native_duration_60000.wav',
      );
      await controller.preview.play(previewSource);
      await _waitForNativePreview(
        tester,
        (state) =>
            state['trackId'] == previewSource.id &&
            state['status'] == 'playing',
        'preview before original-save release barrier',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-original')));
      await tester.tap(find.byKey(const ValueKey('save-original')));
      await _waitFor(
        tester,
        () => controller.preview.isBlocked,
        'write lock while actual consent is pending',
      );
      await _waitForNativePreview(
        tester,
        (state) => state['status'] == 'stopped',
        'release while write consent awaits a response',
      );
      await controller.preview.play(previewSource);
      expect(controller.preview.track, isNull);
      expect((await _nativePreviewState())['status'], 'stopped');
      previewEvidence['original_save_release_before_consent_response'] = true;
      previewEvidence['play_blocked_during_original_write'] = true;
      await phase('original_cancel');
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            controller.taskForTrack(track.id)!.status == TaskStatus.needsReview,
        'cancellation of real Android write consent',
      );
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      expect((await library.readDetails(track)).lyrics, isNull);
      expect(controller.preview.isBlocked, isFalse);
      expect((await _nativePreviewState())['status'], 'stopped');
      previewEvidence['cancelled_write_never_autoplays'] = true;
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
      expect(find.byKey(const ValueKey('close-selected-song')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('close-selected-song')));
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
      expect(find.text('可应用 1 首 · 已确认 1 首'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fixed-task-selection-toolbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bulk-save-original')).hitTestable(),
        findsOneWidget,
      );
      await checkpoint('bulk_review_ready');
      await tester.tap(
        find.byKey(const ValueKey('bulk-save-original')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(find.text('查看本次修改'), findsOneWidget);
      expect(controller.isBusy, isFalse);
      await phase('original_confirm');
      await tester.tap(find.byKey(const ValueKey('apply-reviewed-batch')));
      await _waitFor(
        tester,
        () =>
            !controller.isBusy &&
            controller.taskForTrack(track.id)!.status ==
                TaskStatus.savedOriginal,
        'real original write consent, backup, replacement, and read-back',
      );
      expect(controller.batchOperation!.kind, BatchOperationKind.saveOriginal);
      expect(controller.batchOperation!.totalCount, 1);
      expect(controller.batchOperation!.completedCount, 1);
      expect(controller.batchOperation!.savedOriginalCount, 1);
      expect(controller.batchOperation!.skippedCount, 0);
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
      expect(persisted.batchOperation!.skippedCount, 0);
      await File('${support.path}/native_runtime_result.json').writeAsString(
        jsonEncode({
          'passed': true,
          'synthetic_only': true,
          'mocked_native_channels': false,
          'online_provider_calls': 0,
          'offline_source_calls': source.calls,
          'audio_preview': previewEvidence,
          'initial_artwork': {
            'before_detail_read': true,
            'real_native_embedded_thumbnail': true,
            'no_artwork_placeholder': true,
            'fresh_controller_reload': true,
            'online_requests': 0,
          },
          'instrumental_annotation': {
            'explicit_after_no_match': true,
            'catalog_only': true,
            'lyric_requests_skipped': true,
            'fresh_controller_reload': true,
            'refresh_preserved': true,
            'removal_restores_lyric_search': true,
            'existing_lyrics_and_cover_unchanged': true,
          },
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
          'batch_excluded_unapproved':
              !controller.batchOperation!.items.any(
                (item) => item.trackId == unapproved.id,
              ) &&
              controller
                  .approvedSuggestionsFor(
                    controller.taskForTrack(unapproved.id)!,
                  )
                  .isEmpty,
          'cover_sha256': coverHash,
          'expected_tags': {'lyrics': _lyrics},
          'checks': [
            'real_permission_deny_and_retry_grant',
            'mediastore_query_and_content_uri_read',
            'real_widgets_and_native_bridge',
            'real_mediastore_preview_progress_pause_resume_and_seek',
            'preview_selection_isolation_and_pinned_controls',
            'preview_switch_close_refresh_and_error_retry',
            'preview_releases_on_detail_tab_and_android_home',
            'private_import_preview_and_corrupt_missing_errors',
            'original_save_blocks_preview_before_consent_response',
            'initial_cover_loaded_before_any_detail_read',
            'native_cover_survives_scroll_and_fresh_controller_reload',
            'missing_cover_uses_placeholder_without_marking_details_read',
            'lyric_no_match_never_auto_marks_instrumental',
            'explicit_instrumental_mark_persists_and_skips_lyric_requests',
            'instrumental_mark_does_not_change_audio_lyrics_or_cover',
            'instrumental_mark_survives_reload_and_refresh',
            'removing_instrumental_mark_restores_lyric_query',
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
