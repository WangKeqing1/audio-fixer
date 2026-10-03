// Render real Flutter UI with synthetic playback state; no decoder or files play.
// AUDIO_FIXER_PREVIEW_FONT=/path/to/CJK.ttf flutter test tool/render_audio_preview.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/app_shell.dart';
import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/audio_preview_service.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fakes.dart';

class _SyntheticPreview implements AudioPreviewBackend {
  final updates = StreamController<AudioPreviewEvent>.broadcast(sync: true);
  @override
  Stream<AudioPreviewEvent> get events => updates.stream;
  @override
  Future<AudioPreviewEvent?> getState() async => null;
  @override
  Future<void> pause({required int requestId}) async {}
  @override
  Future<void> seek({required int requestId, required int positionMs}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> play({
    required int requestId,
    required String trackId,
    required String uri,
  }) async {
    updates.add(
      AudioPreviewEvent(
        requestId: requestId,
        trackId: trackId,
        status: AudioPreviewStatus.playing,
        positionMs: 37000,
        durationMs: 186000,
      ),
    );
  }
}

void main() {
  testWidgets('render local preview and selection controls', (tester) async {
    final fontPath = Platform.environment['AUDIO_FIXER_PREVIEW_FONT'];
    if (fontPath == null) throw StateError('Set AUDIO_FIXER_PREVIEW_FONT.');
    await tester.runAsync(() async {
      await (FontLoader('Preview CJK')
            ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView)))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final backend = _SyntheticPreview();
    final controller = LibraryController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [
            for (var i = 1; i <= 12; i++)
              AudioTrack(
                id: 'sample-$i',
                fileName: 'sample-$i.mp3',
                localPath: '/fixture/$i.mp3',
                sizeBytes: 8000000,
                importedAt: DateTime(2026),
                title: '示例音频 · ${i == 1 ? '午后散步' : '城市夜晚 $i'}',
                artist: '示例歌手',
                durationMs: 186000,
                detailsLoaded: false,
              ),
          ],
        ),
      ),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
      preview: AudioPreviewController(backend: backend),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.selectTracks(['sample-1', 'sample-2']);
    final captureKey = GlobalKey();
    Future<void> show(Brightness brightness) async {
      final theme = buildAppTheme(brightness);
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => MaterialApp(
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
        ),
      );
      await tester.pumpAndSettle();
    }

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

    await show(Brightness.light);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -340));
    await tester.pumpAndSettle();
    await controller.preview.play(controller.tracks.first);
    await tester.pumpAndSettle();
    await capture('audio-preview-selection');
    tester.view.physicalSize = const Size(320, 740);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    await show(Brightness.dark);
    await capture('audio-preview-large-text');
    await tester.pumpWidget(const SizedBox.shrink());
    await backend.updates.close();
  });
}
