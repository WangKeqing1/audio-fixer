// Headless previews of real Flutter widgets with explicitly synthetic data.
// No online source is contacted and no audio file is exported.
// AUDIO_FIXER_PREVIEW_FONT=/path/to/local/CJK.ttf flutter test tool/render_preview.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/app_shell.dart';
import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fakes.dart';

void main() {
  testWidgets('render real phone, tablet, review and recovery screens', (
    tester,
  ) async {
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
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final createdAt = DateTime(2026, 10, 1, 10, 30);
    final reviewTask = CompletionTask(
      trackId: 'sample-1',
      trackTitle: '示例音频 · 午后散步',
      createdAt: createdAt,
      status: TaskStatus.needsReview,
      message: '已找到 2 项示例候选，请确认版本后保存到原文件，或选择导出副本。',
      suggestions: const [
        FieldSuggestion(
          field: AudioField.album,
          value: '示例专辑 · 慢一点',
          source: 'MusicBrainz（离线示例）',
          matchDescription: '示例匹配说明：歌名、歌手与时长一致。',
        ),
        FieldSuggestion(
          field: AudioField.lyrics,
          value:
              '[00:00.00] 示例歌词，仅用于界面验证\n'
              '[00:05.00] 沿着树荫慢慢走\n'
              '[00:10.00] 把午后的风留在身后\n'
              '[00:15.00] 远处传来轻轻的脚步\n'
              '[00:20.00] 阳光落在安静的路口\n'
              '[00:25.00] 不必急着寻找答案\n'
              '[00:30.00] 今天就慢一点走',
          source: 'LRCLIB（离线示例）',
          matchDescription: '示例同步歌词，不来自实际歌曲。',
        ),
      ],
    );
    final controller = LibraryController(
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
            AudioTrack(
              id: 'sample-3',
              fileName: '示例待检查.mp3',
              sizeBytes: 8000000,
              importedAt: DateTime(2026, 1, 1),
              title: '示例音频 · 还未检查',
              artist: '示例歌手',
              durationMs: 186000,
              detailsLoaded: false,
            ),
            fixtureTrack(
              id: 'sample-4',
              title: '示例音频 · 标签异常',
              readError: '示例读取异常',
            ),
          ],
          tasks: [
            reviewTask,
            CompletionTask(
              trackId: 'sample-2',
              trackTitle: '示例音频 · 城市夜晚',
              createdAt: createdAt,
              status: TaskStatus.noMatch,
              message: '没有找到此版本的封面，可以稍后重新查询。',
            ),
          ],
        ),
      ),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(
        sources: [
          _PreviewSource('MusicBrainz（示例）', {
            AudioField.title,
            AudioField.artist,
            AudioField.album,
          }),
          _PreviewSource('LRCLIB（示例）', {AudioField.lyrics}),
          _PreviewSource('Cover Art Archive（示例）', {AudioField.artwork}),
        ],
      ),
      exporter: _PreviewExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final captureKey = GlobalKey();

    Future<void> showApp({Brightness brightness = Brightness.light}) async {
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
      expect(tester.takeException(), isNull, reason: name);
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

    await showApp();
    await capture('library');
    await tester.ensureVisible(
      find.byKey(const ValueKey('toggle-library-selection')),
    );
    await tester.tap(
      find.byKey(const ValueKey('toggle-library-selection')).hitTestable(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-visible-tracks')));
    await tester.pumpAndSettle();
    await capture('library-selection-fixed');
    await tester.tap(find.byKey(const ValueKey('toggle-library-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('补全任务'));
    await tester.pumpAndSettle();
    await capture('tasks');
    await tester.tap(find.text('确认 2 项候选'));
    await tester.pumpAndSettle();
    await capture('candidate-review');
    final reviewScroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    reviewScroll.position.jumpTo(reviewScroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await capture('candidate-review-lyrics');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await capture('settings');
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    await capture('settings-sources');

    tester.view.physicalSize = const Size(900, 900);
    await tester.pumpAndSettle();
    await tester.tap(find.text('音乐库'));
    await tester.pumpAndSettle();
    await capture('tablet');

    tester.view.physicalSize = const Size(390, 844);
    controller.libraryError = '示例：系统音乐库暂时不可用，请稍后刷新重试。';
    await showApp();
    await capture('library-refresh-error');
    controller.libraryError = null;
    tester.view.physicalSize = const Size(320, 740);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    await showApp(brightness: Brightness.dark);
    await capture('library-dark-large-text');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -480));
    await tester.pumpAndSettle();
    await capture('library-dark-large-text-scrolled');
    await tester.ensureVisible(
      find.byKey(const ValueKey('toggle-library-selection')),
    );
    await tester.tap(
      find.byKey(const ValueKey('toggle-library-selection')).hitTestable(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-visible-tracks')));
    await tester.pumpAndSettle();
    await capture('library-selection-large-text');
    await tester.tap(find.byKey(const ValueKey('toggle-library-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    // Settings has its own saved scroll position; reset it for the overview.
    final settingsScrollable = find.descendant(
      of: find.byKey(const PageStorageKey('settings')),
      matching: find.byType(Scrollable),
    );
    final settingsPosition = tester
        .state<ScrollableState>(settingsScrollable.first)
        .position;
    settingsPosition.jumpTo(0);
    await tester.pumpAndSettle();
    // Text scaling can correct the extent of previously cached sliver children
    // during the first layout. Reset again after those children are measured.
    settingsPosition.jumpTo(0);
    await tester.pumpAndSettle();
    expect(
      settingsPosition.pixels,
      0,
      reason: 'Settings overview starts at top',
    );
    expect(find.text('音乐库排除规则').hitTestable(), findsOneWidget);
    await capture('settings-dark-large-text');
    await tester.tap(find.text('补全任务'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认 2 项候选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认 2 项候选').hitTestable());
    await tester.pumpAndSettle();
    await capture('candidate-review-dark-large-text');
    debugDisableShadows = true;
  });
}

class _PreviewSource implements MetadataSource {
  _PreviewSource(this.name, this.supportedFields);
  @override
  final String name;
  @override
  final Set<AudioField> supportedFields;

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async => [];
}

class _PreviewExporter implements AudioCopyExporter, AudioOriginalSaver {
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => throw StateError("Preview rendering must never save originals.");
  @override
  bool supports(AudioTrack track) => true;

  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => throw StateError('Preview rendering must never export files.');
}
