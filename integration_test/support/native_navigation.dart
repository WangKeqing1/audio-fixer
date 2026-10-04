import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/tasks/recommended_batch_review_page.dart';
import 'package:audio_fixer/features/tasks/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> showNativeTarget(
  WidgetTester tester,
  Finder target, {
  required Finder scrollable,
  double delta = 180,
}) async {
  await tester.scrollUntilVisible(target, delta, scrollable: scrollable);
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
}

Future<Finder> showNativeSavedBatchResult(WidgetTester tester) async {
  // Successful reviewed saves pop their route. Until that transition settles,
  // both the departing review and the task page can contain a result panel.
  await tester.pumpAndSettle();
  expect(find.byType(RecommendedBatchReviewPage), findsNothing);
  final tasks = find.byType(TasksPage);
  expect(tasks, findsOneWidget);
  final result = find.descendant(
    of: tasks,
    matching: find.byKey(const ValueKey('batch-progress')),
  );
  await showNativeTarget(
    tester,
    result,
    scrollable: find
        .descendant(of: tasks, matching: find.byType(Scrollable))
        .first,
  );
  return result;
}

// Shared with a native-sized widget regression so this exact interaction is
// checked before another emulator build. This never invokes a
// controller operation in place of the visible repair action.
Future<void> tapNativeMissingOnly(WidgetTester tester) async {
  final detail = find.byType(TrackDetailPage);
  final scroll = find
      .descendant(of: detail, matching: find.byType(Scrollable))
      .first;

  // Inspect expansion only after the disclosure itself has been mounted.
  final disclosure = find.descendant(of: detail, matching: find.text('其他修复方式'));
  await showNativeTarget(tester, disclosure, scrollable: scroll);
  final action = find.descendant(
    of: detail,
    matching: find.byKey(const ValueKey('complete-missing-only')),
  );
  if (action.evaluate().isEmpty) {
    await tester.tap(disclosure.hitTestable());
    await tester.pumpAndSettle();
  }
  await showNativeTarget(tester, action, scrollable: scroll);
  expect(tester.widget<ListTile>(action).onTap, isNotNull);
  await tester.tap(action.hitTestable());
}
