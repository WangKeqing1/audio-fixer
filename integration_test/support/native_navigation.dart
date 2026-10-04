import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Shared with a native-sized widget regression so this exact interaction is
// checked before another emulator build. This never invokes a
// controller operation in place of the visible repair action.
Future<void> tapNativeMissingOnly(WidgetTester tester) async {
  final detail = find.byType(TrackDetailPage);
  final scroll = find
      .descendant(of: detail, matching: find.byType(Scrollable))
      .first;
  Future<void> show(Finder target) async {
    await tester.scrollUntilVisible(target, 180, scrollable: scroll);
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
  }

  // Inspect expansion only after the disclosure itself has been mounted.
  final disclosure = find.descendant(of: detail, matching: find.text('其他修复方式'));
  await show(disclosure);
  final action = find.descendant(
    of: detail,
    matching: find.byKey(const ValueKey('complete-missing-only')),
  );
  if (action.evaluate().isEmpty) {
    await tester.tap(disclosure.hitTestable());
    await tester.pumpAndSettle();
  }
  await show(action);
  expect(tester.widget<ListTile>(action).onTap, isNotNull);
  await tester.tap(action.hitTestable());
}
