// Real Flutter widget pixels with authored, synthetic offline music records.
// No online query, playback, native file I/O, or audio writes are performed.
// source ../toolchains/flutter-env.sh
// flutter test --no-pub tool/render_consumer_preview.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/app_shell.dart';
import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fakes.dart';

class _PreviewWriter implements AudioCopyExporter, AudioOriginalSaver {
  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => null;
  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => null;
}

Future<String> _cover(int index) async {
  final palettes = [
    [const Color(0xff1d4c52), const Color(0xffe8c680)],
    [const Color(0xff33325d), const Color(0xffe0a0a4)],
    [const Color(0xffcc805c), const Color(0xfff5dec0)],
  ];
  final palette = palettes[index];
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 512, 512),
    Paint()..color = palette[0],
  );
  canvas.drawCircle(const Offset(352, 143), 86, Paint()..color = palette[1]);
  for (var i = 0; i < 8; i++) {
    final path = Path()
      ..moveTo(-50, 290.0 + i * 24)
      ..cubicTo(120, 110.0 + i * 24, 280, 590.0 - i * 20, 562, 250.0 + i * 30);
    canvas.drawPath(
      path,
      Paint()
        ..color = palette[1].withValues(alpha: .22 + i * .07)
        ..strokeWidth = 8
        ..style = PaintingStyle.stroke,
    );
  }
  final paragraph =
      (ui.ParagraphBuilder(
              ui.ParagraphStyle(fontFamily: 'Preview CJK', fontSize: 32),
            )
            ..pushStyle(ui.TextStyle(color: palette[1], letterSpacing: 8))
            ..addText(['树影与风', '城市夜晚', '日落以后'][index]))
          .build()
        ..layout(const ui.ParagraphConstraints(width: 420));
  canvas.drawParagraph(paragraph, const Offset(42, 422));
  final picture = recorder.endRecording();
  final image = await picture.toImage(512, 512);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('build/previews/consumer-fixture-cover-$index.png')
      .absolute;
  await file.parent.create(recursive: true);
  await file.writeAsBytes(data!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return file.path;
}

void main() {
  testWidgets(
    'render consumer library detail and repair preview across sizes',
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
      });
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final covers = await tester.runAsync(
        () async => [for (var i = 0; i < 3; i++) await _cover(i)],
      );
      // Precache the exact resized Image.file keys before mounting the music
      // UI so every screenshot includes the first decoded frame, not a blank
      // asynchronous placeholder from Flutter's fake test clock.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final imageContext = tester.element(find.byType(SizedBox).first);
      await tester.runAsync(() async {
        for (final cover in covers!) {
          for (final width in [52, 56, 72, 88, 160]) {
            await precacheImage(
              ResizeImage(FileImage(File(cover)), width: width),
              imageContext,
            );
          }
        }
      });
      final titles = [
        '午后散步',
        '城市夜晚',
        '等风来',
        '穿过山谷',
        '有你的晴天',
        '慢一点',
        '日落以后',
        '远方的灯',
        '清晨电台',
      ];
      final artists = ['林间来信', '白昼旅人', '海岸线'];
      final tracks = [
        for (var i = 0; i < titles.length; i++)
          AudioTrack(
            id: 'offline-$i',
            fileName: '${titles[i]}.${i.isEven ? 'flac' : 'mp3'}',
            localPath:
                '/offline-synthetic/${titles[i]}.${i.isEven ? 'flac' : 'mp3'}',
            sizeBytes: i.isEven ? 25800000 : 8800000,
            importedAt: DateTime(2026, 10, 4),
            title: titles[i],
            artist: artists[i % 3],
            album: i % 3 == 0 ? null : ['树影与风', '城市夜晚', '日落以后'][i % 3],
            durationMs: 192000 + i * 7000,
            lyrics: i % 3 == 0 ? null : '[00:00.00] 本段为界面验证创作的离线示例歌词',
            artworkPath: covers![i % 3],
            artworkValidated: true,
          ),
      ];
      final task = CompletionTask(
        trackId: tracks.first.id,
        trackTitle: tracks.first.displayTitle,
        createdAt: DateTime(2026, 10, 4, 12),
        status: TaskStatus.needsReview,
        message: '此页面使用自行创作的离线示例资料，不代表在线匹配结果。',
        isRepair: true,
        queriedFields: AudioField.coreFields,
        suggestions: const [
          FieldSuggestion(
            field: AudioField.album,
            value: '树影与风',
            source: '离线示例资料',
            provenance: SuggestionProvenance.verifiedRecording,
            matchDescription: '离线测试：同一录音与发行版本已核对。',
          ),
          FieldSuggestion(
            field: AudioField.lyrics,
            value: '[00:00.00] 沿着树荫慢慢走\n[00:05.00] 把午后的风留在身后\n[00:10.00] 远处传来轻轻的脚步\n[00:15.00] 阳光落在安静的路口',
            source: '离线示例资料',
            provenance: SuggestionProvenance.verifiedRecording,
            matchDescription: '为本次界面验证创作的歌词。',
          ),
          FieldSuggestion(
            field: AudioField.genre,
            value: '独立民谣',
            source: '离线示例资料',
            provenance: SuggestionProvenance.verifiedRecording,
          ),
          FieldSuggestion(
            field: AudioField.title,
            value: '午后散步（现场版）',
            source: '离线示例资料',
            replaceExisting: true,
            provenance: SuggestionProvenance.verifiedRecording,
          ),
          FieldSuggestion(
            field: AudioField.year,
            value: '2025',
            source: '离线来源 A',
            provenance: SuggestionProvenance.verifiedRecording,
          ),
          FieldSuggestion(
            field: AudioField.year,
            value: '2026',
            source: '离线来源 B',
            provenance: SuggestionProvenance.verifiedRecording,
          ),
        ],
      );
      final controller = LibraryController(
        store: MemoryStore(LibrarySnapshot(tracks: tracks, tasks: [task])),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: [NoResultMetadataSource()]),
        exporter: _PreviewWriter(),
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      var sequence = 0;
      GlobalKey captureKey = GlobalKey();
      Future<void> show(
        Widget Function() buildPage, {
        double scale = 1,
        Brightness brightness = Brightness.light,
      }) async {
        // Fully detach the previous synthetic app before reusing its controller
        // in another capture; overlapping app roots are not a user navigation.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        captureKey = GlobalKey();
        final pageKey = ValueKey(sequence++);
        final theme = buildAppTheme(brightness);
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => MaterialApp(
                key: pageKey,
                debugShowCheckedModeBanner: false,
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                theme: theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: 'Preview CJK'),
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: buildPage(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Give locally decoded authored cover images a real asynchronous frame.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull, reason: name);
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
      }

      for (final size in [
        const Size(390, 844),
        const Size(900, 900),
        const Size(1440, 960),
      ]) {
        tester.view.physicalSize = size;
        final width = size.width.toInt();
        await show(() => AppShell(controller: controller));
        await capture('consumer-library-$width');
        final song = find.byKey(const ValueKey('song-tile-offline-0'));
        if (song.hitTestable().evaluate().isEmpty) {
          await tester.ensureVisible(song);
        }
        await tester.tap(song.hitTestable());
        await tester.pumpAndSettle();
        await capture('consumer-detail-$width');
        final review = find.byKey(const ValueKey('review-song-result'));
        await tester.ensureVisible(review);
        await tester.tap(review.hitTestable());
        await tester.pumpAndSettle();
        await capture('consumer-workspace-review-$width');
        await show(
          () => CandidateReviewPage(
            task: task,
            controller: controller,
            embedded: true,
            onBack: () {},
          ),
        );
        await capture('consumer-preview-$width');
      }
      tester.view.physicalSize = const Size(1440, 960);
      await show(
        () => AppShell(controller: controller),
        brightness: Brightness.dark,
      );
      await tester.tap(
        find.byKey(const ValueKey('song-tile-offline-0')).hitTestable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('review-song-result')).hitTestable(),
      );
      await tester.pumpAndSettle();
      await capture('consumer-workspace-review-1440-dark');
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      await capture('consumer-settings-1440-dark');
      await show(() => AppShell(controller: controller));
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      await capture('consumer-settings-1440');

      tester.view.physicalSize = const Size(390, 844);
      await show(
        () => CandidateReviewPage(
          task: task,
          controller: controller,
          embedded: true,
          onBack: () {},
        ),
        scale: 2,
      );
      await capture('consumer-preview-390-large-text');
      await tester.drag(find.byType(ListView), const Offset(0, -1300));
      await tester.pumpAndSettle();
      await capture('consumer-preview-390-large-text-scrolled');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDisableShadows = true;
    },
  );
}
