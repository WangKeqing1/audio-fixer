import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'support/large_library_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('4096-track indexed catalog interaction measurement', () async {
    final fixture = LargeLibraryFixture();
    final controller = fixture.controller;
    await controller.initialize();
    addTearDown(controller.dispose);
    fixture.settings.exclusionChecks = 0;
    controller.resetMeasurements();
    final watch = Stopwatch()..start();
    for (var iteration = 0; iteration < 512; iteration++) {
      final index = iteration * 7 % 4096;
      expect(controller.trackById('large-$index'), isNotNull);
      controller.taskForTrack('large-$index');
      controller.toggleTrackSelection('large-$index');
      controller.selectedCount;
    }
    watch.stop();
    // Timing is evidence, never a host-dependent absolute pass/fail budget.
    // ignore: avoid_print
    print(
      'LARGE_LIBRARY_CATALOG ${jsonEncode({'tracks': 4096, 'tasks': 512, 'iterations': 512, 'elapsed_us': watch.elapsedMicroseconds, 'exclusion_checks': fixture.settings.exclusionChecks, 'track_list_reads': controller.trackListReads, 'track_lookups': controller.trackLookups, 'task_lookups': controller.taskLookups, 'selected': controller.selectedCount})}',
    );
    expect(controller.selectedCount, 512);
  });
}
