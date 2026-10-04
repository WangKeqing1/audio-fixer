import 'dart:convert';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'large_library_fixture.dart';

/// Same workload for Linux widget evidence and the Windows native-engine run.
/// Timings are recorded, not compared to a flaky absolute frame-time threshold.
Future<Map<String, Object>> runLargeLibraryScenario(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = LargeLibraryFixture();
  final controller = fixture.controller;
  final phases = <String, Object>{};
  Future<void> measure(String name, Future<void> Function() action) async {
    fixture.settings.exclusionChecks = 0;
    controller.resetMeasurements();
    final coverReads = fixture.device.artworkReadCount;
    final watch = Stopwatch()..start();
    await action();
    watch.stop();
    phases[name] = {
      'elapsed_us': watch.elapsedMicroseconds,
      'exclusion_checks': fixture.settings.exclusionChecks,
      'track_list_reads': controller.trackListReads,
      'track_lookups': controller.trackLookups,
      'task_lookups': controller.taskLookups,
      'thumbnail_reads': fixture.device.artworkReadCount - coverReads,
    };
    // ignore: avoid_print
    print('LARGE_LIBRARY_PHASE $name ${jsonEncode(phases[name])}');
    expect(tester.takeException(), isNull, reason: name);
  }

  await measure('startup', () async {
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
  });
  final initialCovers = fixture.device.artworkReadCount;
  expect(initialCovers, greaterThan(0));
  expect(
    initialCovers,
    lessThan(80),
    reason: 'Only mounted rows may load covers',
  );
  final list = find.byKey(const PageStorageKey('library-scroll-view'));
  final scroll = tester.widget<CustomScrollView>(list).controller!;
  await measure('thumbnail_scroll', () async {
    for (var step = 1; step <= 8; step++) {
      scroll.jumpTo(step * 420);
      await tester.pumpAndSettle();
    }
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
  });
  await measure('selection', () async {
    await tester.tap(find.byKey(const ValueKey('toggle-library-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-track-large-0')));
    await tester.pumpAndSettle();
    expect(controller.selectedTrackIds, {'large-0'});
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byKey(const ValueKey('select-track-large-1')));
      await tester.pumpAndSettle();
    }
    expect(controller.selectedTrackIds, {'large-0'});
  });
  var notifications = 0;
  void onLibraryChange() => notifications++;
  controller.addListener(onLibraryChange);
  await tester.tap(find.byKey(const ValueKey('preview-track-large-0')));
  await tester.pumpAndSettle();
  final artwork = tester.widget(
    find.byKey(const ValueKey('library-artwork-large-0')),
  );
  final coversBeforePlayback = fixture.device.artworkReadCount;
  await measure('playback_24_updates', () async {
    for (var tick = 1; tick <= 24; tick++) {
      fixture.backend.progress(tick * 250);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.preview.positionMs, 6000);
    expect(notifications, 0);
    expect(fixture.device.artworkReadCount, coversBeforePlayback);
    expect(
      tester.widget(find.byKey(const ValueKey('library-artwork-large-0'))),
      same(artwork),
    );
  });
  controller.removeListener(onLibraryChange);
  await controller.preview.stop();
  await tester.pumpAndSettle();
  // Leave selection before opening details; selection itself never navigates.
  controller.clearSelection();
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('toggle-library-selection')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('song-tile-large-1')));
  await tester.pumpAndSettle();
  final details = tester.state(find.byType(TrackDetailPage));
  final offset = scroll.offset;
  await measure('resize_4_transitions', () async {
    for (final size in [
      const Size(390, 844),
      const Size(1000, 900),
      const Size(844, 900),
      const Size(1440, 1000),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(TrackDetailPage)), same(details));
    }
    expect(scroll.offset, closeTo(offset, 1));
  });
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  final result = <String, Object>{
    'tracks': fixture.tracks.length,
    'tasks': fixture.tasks.length,
    'initial_thumbnail_reads': initialCovers,
    'distinct_thumbnail_reads': fixture.device.artworkReads.length,
    'phases': phases,
  };
  // ignore: avoid_print
  print('LARGE_LIBRARY_INTERACTION ${jsonEncode(result)}');
  return result;
}
