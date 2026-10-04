import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'expanded_review_fixture.dart';

/// Shared by the real Windows integration runner and a local widget harness.
/// The native runner supplies the Windows engine; this scenario uses only
/// authored lyrics, an in-memory catalog, and a recording fake writer.
Future<Map<String, Object>> runExpandedReviewWindowsScenario(
  WidgetTester tester, {
  Future<void> Function(RenderRepaintBoundary boundary)? capture,
}) async {
  const size = Size(2048, 1376);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final fixture = ExpandedReviewFixture(withExisting: true, translated: true);
  final captureKey = GlobalKey();
  final apply = find.byKey(const ValueKey('save-original'));
  final values = [
    expandedReviewLyrics,
    expandedReviewTranslation,
    expandedReviewOldLyrics,
  ];
  Finder text(String value) => find.byWidgetPredicate(
    (widget) => widget is SelectableText && widget.data == value,
  );
  Finder scroller(String value) => find
      .ancestor(of: text(value), matching: find.byType(SingleChildScrollView))
      .first;
  ScrollPosition position(String value) => tester
      .state<ScrollableState>(
        find
            .descendant(of: scroller(value), matching: find.byType(Scrollable))
            .first,
      )
      .position;
  Future<void> tap(Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target.hitTestable());
    await tester.pumpAndSettle();
  }

  void checkHealthy(String phase) {
    expect(tester.takeException(), isNull, reason: phase);
    expect(find.byType(ErrorWidget), findsNothing, reason: phase);
    final sourceSize = tester.getSize(text(expandedReviewSourceUrl));
    expect(sourceSize.width.isFinite, isTrue, reason: phase);
    expect(sourceSize.height.isFinite, isTrue, reason: phase);
    expect(sourceSize.height, lessThan(140), reason: phase);
    for (final value in values) {
      expect(
        tester.getSize(scroller(value)).height,
        lessThanOrEqualTo(value == expandedReviewOldLyrics ? 140 : 220),
        reason: phase,
      );
    }
    expect(apply.hitTestable(), findsOneWidget, reason: phase);
    expect(
      tester.widget<FilledButton>(apply).onPressed,
      isNotNull,
      reason: phase,
    );
    expect(fixture.writer.writeCount, 0, reason: phase);
  }

  final offsets = <String, double>{};
  try {
    await fixture.controller.initialize();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.dark)
              .copyWith(platform: TargetPlatform.windows),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: CandidateReviewPage(
            task: fixture.task,
            controller: fixture.controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Scaffold)), size);
    expect(
      tester.widget<FilledButton>(apply).onPressed,
      isNull,
      reason: 'An existing value must remain unselected until reviewed',
    );
    // Select only in the review UI. Never invoke the primary save action.
    await tap(find.byType(CheckboxListTile));
    await tap(find.text('预览与来源'));
    checkHealthy(
      'expanded LRCLIB source, original, translation and current lyrics',
    );
    final footer = tester.getRect(apply);
    final outer = tester.widget<ListView>(find.byType(ListView)).controller!;
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      await tester.ensureVisible(scroller(value));
      await tester.pumpAndSettle();
      final outerBefore = outer.offset;
      final before = {for (final item in values) item: position(item).pixels};
      final pointer = TestPointer(index + 1, PointerDeviceKind.mouse);
      pointer.hover(tester.getCenter(scroller(value)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 160)));
      await tester.pumpAndSettle();
      checkHealthy('Windows wheel scroll $index');
      expect(position(value).pixels, greaterThan(before[value]!));
      for (final other in values.where((item) => item != value)) {
        expect(position(other).pixels, before[other]);
      }
      expect(
        outer.offset,
        outerBefore,
        reason: 'Wheel scrolling in lyrics must not scroll the review page',
      );
      expect(tester.getRect(apply), footer);
      offsets[['original', 'translation', 'current'][index]] = position(value)
          .pixels;
    }
    outer.jumpTo(outer.position.maxScrollExtent);
    await tester.pumpAndSettle();
    checkHealthy('outer page scroll');
    expect(tester.getRect(apply), footer);
    await tap(find.text('预览与来源'));
    expect(text(expandedReviewSourceUrl), findsNothing);
    expect(tester.takeException(), isNull);
    await tap(find.text('预览与来源'));
    checkHealthy('reopened disclosure');
    for (var index = 0; index < values.length; index++) {
      expect(
        position(values[index]).pixels,
        offsets[['original', 'translation', 'current'][index]],
      );
    }
    expect(tester.getRect(apply), footer);
    final source = tester.getRect(text(expandedReviewSourceUrl));
    if (capture != null) {
      await capture(
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary,
      );
    }
    return {
      'logical_width': size.width,
      'logical_height': size.height,
      'source_height': source.height,
      'lyrics_scroll_offsets': offsets,
      'primary_action_fixed': true,
      'unexpected_errors': 0,
      'audio_writes': fixture.writer.writeCount,
      'fixture': 'Authored offline LRCLIB-shaped source with 100-line original, translation and current lyrics',
    };
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    fixture.controller.dispose();
  }
}
