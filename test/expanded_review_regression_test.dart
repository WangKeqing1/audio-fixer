import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/expanded_review_fixture.dart';

Finder _text(String value) => find.byWidgetPredicate(
  (widget) => widget is SelectableText && widget.data == value,
);
Finder _scroller(String value) => find
    .ancestor(of: _text(value), matching: find.byType(SingleChildScrollView))
    .first;
final _apply = find.byKey(const ValueKey('save-original'));

ScrollPosition _position(WidgetTester tester, String value) => tester
    .state<ScrollableState>(
      find
          .descendant(of: _scroller(value), matching: find.byType(Scrollable))
          .first,
    )
    .position;

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target.hitTestable());
  await tester.pumpAndSettle();
}

Future<void> _show(
  WidgetTester tester,
  ExpandedReviewFixture fixture,
  Brightness brightness, {
  double scale = 1,
}) async {
  await fixture.controller.initialize();
  addTearDown(fixture.controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness).copyWith(
        platform: tester.view.physicalSize.width >= 900
            ? TargetPlatform.windows
            : TargetPlatform.android,
      ),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => CandidateReviewPage(
                    task: fixture.task,
                    controller: fixture.controller,
                  ),
                ),
              ),
              child: const Text('打开预览'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, find.text('打开预览'));
}

void _healthy(WidgetTester tester, {required String reason}) {
  expect(tester.takeException(), isNull, reason: reason);
  expect(find.byType(ErrorWidget), findsNothing, reason: reason);
  final sourceSize = tester.getSize(_text(expandedReviewSourceUrl));
  expect(
    sourceSize.width.isFinite && sourceSize.height.isFinite,
    isTrue,
    reason: reason,
  );
  expect(sourceSize.height, lessThan(140), reason: reason);
  expect(
    tester.getSize(_scroller(expandedReviewLyrics)).height,
    lessThanOrEqualTo(220),
    reason: reason,
  );
  expect(_apply.hitTestable(), findsOneWidget, reason: reason);
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  // Previously every first expansion with a non-null URL threw:
  // type 'bool' is not a subtype of type 'double?' in type cast.
  // ExpansionTile's bool and SelectableText's inner Scrollable had the same
  // PageStorage identity. In release the ErrorWidget became a 100000px gray box.
  for (final size in [
    const Size(390, 844),
    const Size(900, 900),
    const Size(2048, 1376),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'LRCLIB source and long lyrics survive expand/scroll/reopen ${size.width.toInt()} ${brightness.name}',
        (tester) async {
          _size(tester, size);
          final fixture = ExpandedReviewFixture();
          await _show(tester, fixture, brightness);
          await _tap(tester, find.text('预览与来源'));
          _healthy(tester, reason: 'first expansion');
          expect(tester.widget<FilledButton>(_apply).onPressed, isNotNull);
          final footerBefore = tester.getRect(_apply);
          await tester.ensureVisible(_scroller(expandedReviewLyrics));
          await tester.drag(
            _scroller(expandedReviewLyrics),
            const Offset(0, -180),
          );
          await tester.pumpAndSettle();
          _healthy(tester, reason: 'lyrics scrolling');
          final lyricOffset = _position(tester, expandedReviewLyrics).pixels;
          expect(lyricOffset, greaterThan(0));
          expect(tester.getRect(_apply), footerBefore);
          final pageScroll = tester
              .widget<ListView>(find.byType(ListView))
              .controller!;
          pageScroll.jumpTo(pageScroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
          _healthy(tester, reason: 'page scrolling');
          expect(tester.getRect(_apply), footerBefore);
          await _tap(tester, find.text('预览与来源'));
          expect(_text(expandedReviewSourceUrl), findsNothing);
          expect(tester.takeException(), isNull);
          await _tap(tester, find.text('预览与来源'));
          _healthy(tester, reason: 'collapse and reopen');
          expect(_position(tester, expandedReviewLyrics).pixels, lyricOffset);
          // The same page crosses both layout branches with a populated bucket.
          tester.view.physicalSize = size.width < 900
              ? const Size(2048, 1376)
              : const Size(390, 844);
          await tester.pumpAndSettle();
          _healthy(tester, reason: 'responsive resize');
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          _healthy(tester, reason: 'resize back');
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          await _tap(tester, find.text('打开预览'));
          await _tap(tester, find.text('预览与来源'));
          _healthy(tester, reason: 'leave and reopen review route');
          expect(fixture.writer.writeCount, 0);
        },
      );
    }
  }

  testWidgets(
    'Windows mouse wheel scrolls lyrics independently from the page',
    (tester) async {
      _size(tester, const Size(2048, 1376));
      final fixture = ExpandedReviewFixture();
      await _show(tester, fixture, Brightness.dark);
      await _tap(tester, find.text('预览与来源'));
      final outer = tester.widget<ListView>(find.byType(ListView)).controller!;
      final outerOffset = outer.offset;
      final footer = tester.getRect(_apply);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(tester.getCenter(_scroller(expandedReviewLyrics)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 160)));
      await tester.pumpAndSettle();
      _healthy(tester, reason: 'Windows mouse wheel');
      expect(_position(tester, expandedReviewLyrics).pixels, greaterThan(0));
      expect(outer.offset, outerOffset);
      expect(tester.getRect(_apply), footer);
      expect(fixture.writer.writeCount, 0);
    },
  );

  testWidgets('expanded source remains usable at 2x phone text scale', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    final fixture = ExpandedReviewFixture();
    await _show(tester, fixture, Brightness.dark, scale: 2);
    await _tap(tester, find.text('预览与来源'));
    _healthy(tester, reason: 'large text');
    await tester.ensureVisible(_text(expandedReviewSourceUrl));
    await tester.pumpAndSettle();
    _healthy(tester, reason: 'large text source visible');
    expect(_text(expandedReviewSourceUrl).hitTestable(), findsOneWidget);
    expect(tester.widget<FilledButton>(_apply).onPressed, isNotNull);
    expect(fixture.writer.writeCount, 0);
  });

  for (final size in [const Size(390, 844), const Size(2048, 1376)]) {
    testWidgets(
      'existing long lyrics and translation keep separate offsets ${size.width.toInt()}',
      (tester) async {
        _size(tester, size);
        final fixture = ExpandedReviewFixture(
          withExisting: true,
          translated: true,
        );
        await _show(tester, fixture, Brightness.dark);
        await _tap(tester, find.text('预览与来源'));
        _healthy(tester, reason: 'existing-value disclosure expansion');
        final existing = _scroller(expandedReviewOldLyrics);
        expect(tester.getSize(existing).height, lessThanOrEqualTo(140));
        final translated = _scroller(expandedReviewTranslation);
        expect(tester.getSize(translated).height, lessThanOrEqualTo(220));
        final values = [
          expandedReviewLyrics,
          expandedReviewTranslation,
          expandedReviewOldLyrics,
        ];
        for (final value in values) {
          await tester.ensureVisible(_scroller(value));
          await tester.pumpAndSettle();
          final before = {
            for (final text in values) text: _position(tester, text).pixels,
          };
          await tester.drag(_scroller(value), const Offset(0, -100));
          await tester.pumpAndSettle();
          _healthy(tester, reason: 'independent nested scroll');
          expect(_position(tester, value).pixels, greaterThan(before[value]!));
          for (final other in values.where((text) => text != value)) {
            expect(_position(tester, other).pixels, before[other]);
          }
        }
        await _tap(tester, find.text('附加中文翻译'));
        expect(_text(expandedReviewTranslation), findsNothing);
        await _tap(tester, find.text('附加中文翻译'));
        _healthy(tester, reason: 'translation remount');
        await _tap(tester, find.text('预览与来源'));
        await _tap(tester, find.text('预览与来源'));
        _healthy(tester, reason: 'existing and translated lyrics reopen');
        expect(fixture.writer.writeCount, 0);
      },
    );
  }
}
