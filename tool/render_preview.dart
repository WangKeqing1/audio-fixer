// Headless previews of the real Flutter widgets, using explicitly labeled
// synthetic tracks. Requires a local CJK font; no font is redistributed.
// flutter test tool/render_preview.dart --no-pub
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/app_shell.dart';
import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fakes.dart';

void main() {
  testWidgets('render phone and tablet previews', (tester) async {
    final fontPath = Platform.environment['AUDIO_FIXER_PREVIEW_FONT'];
    if (fontPath == null) {
      throw StateError('Set AUDIO_FIXER_PREVIEW_FONT to a local CJK font.');
    }
    await tester.runAsync(() async {
      final font = FontLoader('Preview CJK')
        ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = testController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [
            fixtureTrack(id: 'sample-1', title: '示例音频 · 午后散步'),
            AudioTrack(
              id: 'sample-2',
              fileName: '示例音频.flac',
              localPath: '/fixture/sample.flac',
              sizeBytes: 24000000,
              importedAt: DateTime(2026, 1, 1),
              title: '示例音频 · 城市夜晚',
              artist: '示例歌手',
              album: '示例专辑',
              durationMs: 204000,
              lyrics: '[00:00.00] 用于界面验证的示例歌词',
            ),
            fixtureTrack(
              id: 'sample-3',
              title: '示例音频 · 标签异常',
              readError: '示例读取异常',
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.complete();
    final captureKey = GlobalKey();
    final theme = buildAppTheme(Brightness.light);
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'Preview CJK'),
          ),
          home: AppShell(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/previews/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('library');
    await tester.tap(find.text('补全任务'));
    await tester.pumpAndSettle();
    await capture('tasks');
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await capture('settings');
    tester.view.physicalSize = const Size(900, 900);
    await tester.pumpAndSettle();
    await tester.tap(find.text('音乐库'));
    await tester.pumpAndSettle();
    await capture('tablet');
    debugDisableShadows = true;
  });
}
