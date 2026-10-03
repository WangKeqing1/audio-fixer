// Authored offline records; no native I/O, network, playback or tag writes.
// AUDIO_FIXER_PREVIEW_FONT=/path/to/CJK.ttc flutter test tool/render_recording_choice_preview.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/recording_candidate.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/tasks/recording_choice_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fakes.dart';

void main() {
  testWidgets('render recording choice at mobile and large text sizes', (
    tester,
  ) async {
    final font = Platform.environment['AUDIO_FIXER_PREVIEW_FONT'];
    if (font == null) throw StateError('Set AUDIO_FIXER_PREVIEW_FONT');
    await tester.runAsync(() async {
      await (FontLoader(
        'Preview CJK',
      )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final track = AudioTrack(
      id: 'offline-recording-choice',
      fileName: '極楽浄土.mp3',
      localPath: '/offline/recording-choice.mp3',
      sizeBytes: 123,
      importedAt: DateTime(2026),
      durationMs: 218828,
    );
    final task = CompletionTask(
      trackId: track.id,
      trackTitle: track.fileName,
      createdAt: DateTime(2026),
      status: TaskStatus.needsReview,
      message: '发现多个相近录音，请先确认版本。',
      isRepair: true,
      recordingCandidates: const [
        RecordingCandidate(
          sourceName: '网易云音乐（离线界面示例）',
          sourceId: 'netease:example1',
          sourceUrl: 'https://music.163.com/song?id=example1',
          title: '極楽浄土',
          artist: 'GARNiDELiA',
          album: '約束 -Promise code-',
          durationMs: 218826,
          matchDescription: '歌名相同，时长相近；缺少本地歌手线索，需确认录音与专辑版本。',
        ),
        RecordingCandidate(
          sourceName: '网易云音乐（离线界面示例）',
          sourceId: 'netease:example2',
          sourceUrl: 'https://music.163.com/song?id=example2',
          title: '極楽浄土',
          artist: 'GARNiDELiA',
          album: 'Violet Cry',
          durationMs: 219066,
          matchDescription: '歌名相同，时长相近；另一张专辑中的版本，需由你确认。',
        ),
      ],
    );
    final controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [track], tasks: [task])),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
    );
    await controller.initialize();
    var page = 0;
    Future<void> capture(
      String name, {
      Size size = const Size(390, 844),
      double scale = 1,
      Finder? scrollTo,
    }) async {
      tester.view.physicalSize = size;
      final key = GlobalKey();
      final theme = buildAppTheme(Brightness.light);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            key: ValueKey(page++),
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Preview CJK'),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: RecordingChoicePage(task: task, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (scrollTo != null) {
        await tester.scrollUntilVisible(
          scrollTo,
          200,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 50,
        );
        await Scrollable.ensureVisible(tester.element(scrollTo), alignment: 0);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/previews/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('recording-choice-mobile');
    await capture(
      'recording-choice-candidates',
      scrollTo: find.byKey(
        const ValueKey('recording-网易云音乐（离线界面示例）-netease:example1'),
      ),
    );
    await capture(
      'recording-choice-large-text',
      size: const Size(320, 740),
      scale: 2,
    );
    await capture(
      'recording-choice-large-text-action',
      size: const Size(320, 740),
      scale: 2,
      scrollTo: find.byKey(
        const ValueKey('choose-recording-网易云音乐（离线界面示例）-netease:example1'),
      ),
    );
  });
}
