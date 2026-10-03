import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/app_shell.dart';
import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/shared/widgets/translation_privacy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fakes.dart';

void main() {
  testWidgets('render real machine translation candidate', (tester) async {
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
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final candidate = const FieldSuggestion(
      field: AudioField.lyrics,
      value: '[00:01.000]This is a synthetic example.',
      source: '测试歌词来源',
      originalLyrics: '[00:01.000]This is a synthetic example.\n[00:04.000]A second example line.',
      chineseTranslation: '[00:01.000]这是一句合成示例。\n[00:04.000]第二句示例文本。',
      machineTranslated: true,
    ).withChineseTranslation(true);
    final task = CompletionTask(
      trackId: 'fixture',
      trackTitle: 'Synthetic song',
      createdAt: DateTime(2026),
      status: TaskStatus.needsReview,
      message: '原文与机器译文分开预览，确认后才保存。',
      suggestions: [candidate],
    );
    final controller = LibraryController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [fixtureTrack()],
          tasks: [task],
          settings: const AppSettings(onDeviceTranslationEnabled: true),
        ),
      ),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    final key = GlobalKey();
    final theme = buildAppTheme(Brightness.light);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
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
    await tester.tap(find.text('补全任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认 1 项候选'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(GoogleTranslationAttribution));
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/google_translate/greyscale_regular_3x.png'),
        key.currentContext!,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/audiofixer-machine-preview.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
