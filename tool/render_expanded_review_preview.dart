// Real Flutter-rendered regression evidence for the expanded review bug.
// source ../toolchains/flutter-env.sh
// flutter test --no-pub tool/render_expanded_review_preview.dart
// All records and lyrics are synthetic; no online request or audio write occurs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/expanded_review_fixture.dart';

Finder _text(String value) => find.byWidgetPredicate(
  (widget) => widget is SelectableText && widget.data == value,
);

void main() {
  testWidgets(
    'capture expanded LRCLIB source in dark desktop and phone layouts',
    (tester) async {
      final font = Platform.environment['AUDIO_FIXER_PREVIEW_FONT'];
      if (font == null) {
        throw StateError('Set AUDIO_FIXER_PREVIEW_FONT to a local CJK font.');
      }
      await tester.runAsync(() async {
        await (FontLoader(
          'Preview CJK',
        )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        await Directory('build/previews').create(recursive: true);
      });
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final (size, brightness, withExisting) in [
        (const Size(2048, 1376), Brightness.dark, false),
        (const Size(390, 844), Brightness.dark, false),
        (const Size(390, 844), Brightness.light, false),
        (const Size(2048, 1376), Brightness.dark, true),
      ]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        final fixture = ExpandedReviewFixture(
          withExisting: withExisting,
          translated: withExisting,
        );
        await fixture.controller.initialize();
        final captureKey = GlobalKey();
        tester.view.physicalSize = size;
        final theme = buildAppTheme(brightness);
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'Preview CJK'),
                platform: size.width >= 900
                    ? TargetPlatform.windows
                    : TargetPlatform.android,
              ),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: CandidateReviewPage(
                task: fixture.task,
                controller: fixture.controller,
                embedded: true,
                onBack: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('预览与来源'));
        await tester.tap(find.text('预览与来源').hitTestable());
        await tester.pumpAndSettle();
        if (size.width < 900) {
          await tester.ensureVisible(_text(expandedReviewSourceUrl));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        expect(find.byType(ErrorWidget), findsNothing);
        final sourceSize = tester.getSize(_text(expandedReviewSourceUrl));
        expect(sourceSize.height, lessThan(140));
        expect(sourceSize.width.isFinite, isTrue);
        expect(
          find.byKey(const ValueKey('save-original')).hitTestable(),
          findsOneWidget,
        );
        final name =
            'consumer-expanded-${size.width.toInt()}-${brightness.name}${withExisting ? '-replacement-translated' : ''}';
        await tester.runAsync(() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('build/previews/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(fixture.writer.writeCount, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        fixture.controller.dispose();
      }
      debugDisableShadows = true;
    },
  );
}
