import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/large_library_fixture.dart';

void main() {
  testWidgets(
    'hidden task page builds only visible cards and keeps bulk actions',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = LargeLibraryFixture();
      final controller = fixture.controller;
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      controller.resetMeasurements();
      controller.toggleTrackSelection('large-0');
      await tester.pumpAndSettle();
      // One linear summary pass is allowed; building every card is not. The old
      // eager list makes over 4,600 track lookups for these same 512 tasks.
      expect(controller.trackLookups, lessThan(fixture.tasks.length * 3));
      await tester.tap(find.text('补全任务').last);
      await tester.pumpAndSettle();
      final list = find.byKey(const PageStorageKey('tasks'));
      final scroll = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('task-large-80')),
        450,
        scrollable: scroll,
        maxScrolls: 40,
      );
      await tester.pumpAndSettle();
      expect(
        find
            .byKey(const ValueKey('fixed-task-selection-toolbar'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(controller.selectedTrackIds, {'large-0'});
      await tester.tap(find.byKey(const ValueKey('end-task-selection')));
      await tester.pumpAndSettle();
      expect(controller.selectedTrackIds, isEmpty);
      expect(
        find.byKey(const ValueKey('fixed-task-selection-toolbar')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
