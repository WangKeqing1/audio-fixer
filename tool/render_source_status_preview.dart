// Authored offline results, rendered through actual detail widgets.
// AUDIO_FIXER_PREVIEW_FONT=/path/to/CJK.ttc flutter test tool/render_source_status_preview.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/source_query_report.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fakes.dart';

class _PreviewSource implements MetadataSource {
  _PreviewSource(this.name, this.supportedFields);
  @override
  final String name;
  @override
  final Set<AudioField> supportedFields;
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async => [];
}

void main() {
  testWidgets('render per-provider recovery in light dark and large text', (
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
      id: 'offline-source-status',
      fileName: 'everytime you kissed me Emily Bindiger.mp3',
      title: 'everytime you kissed me Emily Bindiger',
      artist: 'Emily Bindiger',
      durationMs: 299000,
      localPath: '/offline/example.mp3',
      sizeBytes: 11953766,
      importedAt: DateTime(2026),
    );
    var page = 0;
    Future<void> capture(
      String name,
      Brightness brightness, {
      double scale = 1,
      bool partial = false,
    }) async {
      final task = CompletionTask(
        trackId: track.id,
        trackTitle: track.displayTitle,
        createdAt: DateTime.now(),
        status: partial ? TaskStatus.needsReview : TaskStatus.failed,
        message: '请查看各来源结果。已有资料保留。',
        isRepair: true,
        queriedFields: {AudioField.lyrics, AudioField.title, AudioField.artist},
        suggestions: partial
            ? const [
                FieldSuggestion(
                  field: AudioField.title,
                  value: 'everytime you kissed me',
                  source: '网易云音乐',
                ),
              ]
            : [],
        sourceReports: [
          SourceQueryReport(
            sourceName: '网易云音乐',
            outcome: partial
                ? SourceQueryOutcome.success
                : SourceQueryOutcome.noMatch,
            candidateCount: partial ? 1 : 0,
            message: partial ? '获得候选资料，等待确认。' : '查询完成，未找到可安全采用的同版本资料。',
            requestedFields: {
              AudioField.title,
              AudioField.artist,
              AudioField.lyrics,
            },
          ),
          SourceQueryReport(
            sourceName: 'LRCLIB',
            outcome: SourceQueryOutcome.failed,
            message: '连接超时，已暂停继续请求。',
            failureKind: SourceFailureKind.timeout,
            retryAt: DateTime.now().add(const Duration(seconds: 52)),
            isLocalCooldown: true,
            requestedFields: {AudioField.lyrics},
          ),
        ],
      );
      final controller = LibraryController(
        store: MemoryStore(LibrarySnapshot(tracks: [track], tasks: [task])),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(
          sources: [
            _PreviewSource('网易云音乐', {
              AudioField.title,
              AudioField.artist,
              AudioField.lyrics,
            }),
            _PreviewSource('LRCLIB', {AudioField.lyrics}),
          ],
        ),
      );
      await controller.initialize();
      tester.view.physicalSize = scale > 1
          ? const Size(320, 740)
          : const Size(390, 844);
      final key = GlobalKey();
      final theme = buildAppTheme(brightness);
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
            home: TrackDetailPage(track: track, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final target = find.byKey(const ValueKey('automatic-repair-result'));
      await tester.scrollUntilVisible(
        target,
        180,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 50,
      );
      await Scrollable.ensureVisible(
        tester.element(target),
        alignment: scale > 1 ? 0 : .35,
      );
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
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }

    await capture('source-status-dark', Brightness.dark);
    await capture('source-status-light', Brightness.light);
    await capture('source-status-large-text', Brightness.dark, scale: 2);
    await capture('source-status-partial', Brightness.dark, partial: true);
  });
}
