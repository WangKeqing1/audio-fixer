// Real Flutter previews with authored offline records. No native I/O or network.
// AUDIO_FIXER_PREVIEW_FONT=/path/to/CJK.ttf flutter test tool/render_repair_preview.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/library/metadata_editor_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:audio_fixer/features/settings/audio_inventory_tool.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fakes.dart';

class _Source implements MetadataSource {
  _Source(this.cover);
  final String cover;
  @override
  String get name => '离线示例';
  @override
  Set<AudioField> get supportedFields =>
      AudioField.values.toSet()..remove(AudioField.comment);
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async => [
    FieldSuggestion(
      field: AudioField.artwork,
      value: cover,
      source: 'Cover Art Archive（离线示例）',
      sourceUrl: 'https://coverartarchive.org/',
      matchDescription: '歌名、歌手、专辑一致；图片为本机绘制的测试素材。',
    ),
    const FieldSuggestion(
      field: AudioField.title,
      value: '示例曲目',
      source: 'MusicBrainz（离线示例）',
      matchDescription: '歌名、歌手与时长匹配，仅用于界面验证。',
    ),
  ];
}

class _Writer implements AudioCopyExporter, AudioOriginalSaver {
  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => throw StateError('No preview writes');
  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => throw StateError('No preview writes');
}

void main() {
  testWidgets('render full repair and inventory screens', (tester) async {
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
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<File> cover(String name, Color color, String label) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(color, BlendMode.src);
      canvas.drawCircle(
        const Offset(128, 95),
        64,
        Paint()..color = Colors.white.withValues(alpha: .2),
      );
      canvas.drawCircle(
        const Offset(128, 95),
        25,
        Paint()..color = Colors.white.withValues(alpha: .85),
      );
      final labelPainter = TextPainter(
        text: TextSpan(
          text: '$label\n离线测试',
          style: const TextStyle(
            fontFamily: 'Preview CJK',
            color: Colors.white,
            fontSize: 24,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(minWidth: 256, maxWidth: 256);
      labelPainter.paint(canvas, const Offset(0, 173));
      labelPainter.dispose();
      final picture = recorder.endRecording();
      final image = await picture.toImage(256, 256);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/previews/$name.png').absolute;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
      return file;
    }

    final currentCover = await tester.runAsync(
      () => cover('fixture-current-cover', const Color(0xFF485D87), '当前封面'),
    );
    final nextCover = await tester.runAsync(
      () => cover('fixture-next-cover', const Color(0xFF006B5E), '候选封面'),
    );
    // Decode authored assets before mounting Image.file in the fake-async tree.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final imageContext = tester.element(find.byType(SizedBox).last);
    await tester.runAsync(() async {
      await Future.wait([
        for (final file in [currentCover!, nextCover!])
          precacheImage(FileImage(file), imageContext),
        for (final width in [120, 160])
          precacheImage(
            ResizeImage(FileImage(currentCover), width: width),
            imageContext,
          ),
      ]);
    });
    final track = AudioTrack(
      id: 'sample',
      fileName: '示例歌手 - 示例曲目 [320kbps].mp3',
      localPath: '/fixture/sample.mp3',
      sizeBytes: 7000000,
      importedAt: DateTime(2026),
      title: '示例歌手 - 示例曲目 [320kbps]',
      artist: '示例歌手',
      album: '原专辑',
      albumArtist: '示例歌手',
      year: 2020,
      genre: '流行',
      trackNumber: 2,
      trackTotal: 10,
      discNumber: 1,
      discTotal: 1,
      composer: '示例作曲',
      comment: '离线示例，仅用于界面验证',
      durationMs: 186000,
      lyrics: '离线示例歌词',
      artworkPath: currentCover!.path,
    );
    final controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [track])),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(
        sources: [_Source(nextCover!.uri.toString())],
      ),
      exporter: _Writer(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final key = GlobalKey();
    var page = 0;
    Future<void> capture(
      Widget home,
      String name, {
      Finder? scrollTo,
      double textScale = 1,
    }) async {
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
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: home,
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (scrollTo != null) {
        await tester.scrollUntilVisible(
          scrollTo,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(tester.element(scrollTo), alignment: 0);
      }
      await tester.pumpAndSettle();
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

    await capture(
      TrackDetailPage(track: track, controller: controller),
      'repair-detail',
    );
    await capture(
      TrackDetailPage(track: track, controller: controller),
      'repair-detail-large-text',
      textScale: 2,
    );
    await capture(
      MetadataEditorPage(track: track, controller: controller),
      'repair-editor',
    );
    await capture(
      MetadataEditorPage(track: track, controller: controller, queryOnly: true),
      'repair-search',
    );
    await capture(
      MetadataEditorPage(track: track, controller: controller, queryOnly: true),
      'repair-search-fields',
      scrollTo: find.text('要查询的项目'),
    );
    await controller.queryAutomaticRepair(track: track);
    await capture(
      CandidateReviewPage(
        task: controller.tasks.single,
        controller: controller,
      ),
      'repair-cover-review',
      scrollTo: find.text('封面'),
    );
    final task = (await controller.createManualRepair(track.id, {
      AudioField.title: '示例曲目',
      AudioField.album: '修正后的专辑',
      AudioField.year: '2021',
    }))!;
    await capture(
      CandidateReviewPage(task: task, controller: controller),
      'repair-review',
    );
    await capture(
      AudioInventoryToolPage(controller: controller),
      'audio-inventory-tool',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
