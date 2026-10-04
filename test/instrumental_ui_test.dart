import 'dart:async';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/lyrics_translation_service.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _PendingTranslator implements LyricsTranslator {
  final inspected = Completer<TranslationModelStatus>();
  int inspections = 0;
  int downloads = 0;
  int translations = 0;
  @override
  Future<TranslationModelStatus> inspect(String original) {
    inspections++;
    return inspected.future;
  }

  @override
  Future<void> downloadModels(String sourceLanguage) async => downloads++;
  @override
  Future<LyricTranslation> translateIfReady(String original) async {
    translations++;
    return const LyricTranslation();
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _showControl(
  WidgetTester tester,
  String id, {
  Finder? scrollView,
}) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey('instrumental-$id')),
    250,
    scrollable: find
        .descendant(
          of: scrollView ?? find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'instrumental change during language inspection cancels stale translation flow',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final track = fixtureTrack();
      final task = CompletionTask(
        trackId: track.id,
        trackTitle: track.displayTitle,
        createdAt: DateTime(2026),
        status: TaskStatus.needsReview,
        message: 'Offline lyric candidate',
        queriedFields: {AudioField.lyrics},
        suggestions: const [
          FieldSuggestion(
            field: AudioField.lyrics,
            value: 'This is a synthetic lyric',
            source: 'Offline fixture',
          ),
        ],
      );
      final translator = _PendingTranslator();
      final controller = testController(
        store: MemoryStore(
          LibrarySnapshot(
            tracks: [track],
            tasks: [task],
            settings: const AppSettings(onDeviceTranslationEnabled: true),
          ),
        ),
        completion: CompletionService(translator: translator),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: CandidateReviewPage(task: task, controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('预览与来源').first,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('预览与来源').first);
      await tester.tap(find.text('预览与来源').first);
      await tester.pumpAndSettle();
      final action = find.text('使用 Google Translate 本机翻译');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pump();
      expect(translator.inspections, 1);
      await controller.setTrackInstrumental(track.id, true);
      translator.inspected.complete(
        const TranslationModelStatus(
          sourceLanguage: 'en',
          missingModels: ['en', 'zh'],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('下载本机翻译模型？'), findsNothing);
      expect(translator.downloads, 0);
      expect(translator.translations, 0);
      expect(controller.tracks.single.isInstrumental, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('details explains local-only mark, shows it and allows undo', (
    tester,
  ) async {
    _phone(tester);
    final track = fixtureTrack();
    final controller = testController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [track],
          tasks: [
            CompletionTask(
              trackId: track.id,
              trackTitle: track.displayTitle,
              createdAt: DateTime(2026),
              status: TaskStatus.noMatch,
              message: '没有找到可用歌词',
              queriedFields: {AudioField.lyrics},
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: TrackDetailPage(track: track, controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await _showControl(tester, track.id);
    expect(find.textContaining('检索不到歌词不一定是纯音乐'), findsOneWidget);
    await tester.tap(find.text('设为纯音乐'));
    await tester.pumpAndSettle();
    expect(controller.tracks.single.isInstrumental, isTrue);
    expect(controller.tracks.single.lyrics, isNull);
    expect(find.text('纯音乐（仅本应用）'), findsOneWidget);
    expect(find.textContaining('不修改音频文件或已有歌词'), findsOneWidget);
    expect(find.text('歌词已有'), findsNothing);
    await tester.tap(find.text('取消纯音乐标记'));
    await tester.pumpAndSettle();
    expect(controller.tracks.single.isInstrumental, isFalse);
    expect(controller.tracks.single.missingFields, contains(AudioField.lyrics));
    if (find
        .byKey(const ValueKey('mark-instrumental-option'))
        .evaluate()
        .isEmpty) {
      await tester.ensureVisible(find.text('其他修复方式'));
      await tester.tap(find.text('其他修复方式'));
      await tester.pumpAndSettle();
    }
    expect(
      find.byKey(const ValueKey('mark-instrumental-option')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no-match task offers explicit instrumental action', (
    tester,
  ) async {
    _phone(tester);
    final track = fixtureTrack();
    final task = CompletionTask(
      trackId: track.id,
      trackTitle: track.displayTitle,
      createdAt: DateTime(2026),
      status: TaskStatus.noMatch,
      message: '没有找到可用歌词',
      queriedFields: {AudioField.lyrics},
    );
    final controller = testController(
      store: MemoryStore(LibrarySnapshot(tracks: [track], tasks: [task])),
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('补全任务'));
    await tester.pumpAndSettle();
    await _showControl(
      tester,
      track.id,
      scrollView: find.byKey(const PageStorageKey('tasks')),
    );
    expect(controller.tracks.single.isInstrumental, isFalse);
    await tester.tap(find.text('设为纯音乐'));
    await tester.pumpAndSettle();
    expect(controller.tracks.single.isInstrumental, isTrue);
    expect(find.text('取消纯音乐标记'), findsOneWidget);
    await tester.tap(find.text('取消纯音乐标记'));
    await tester.pumpAndSettle();
    expect(controller.tracks.single.isInstrumental, isFalse);
    expect(controller.tasks.single.approvedSuggestions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'partial candidate can mark instrumental without approving metadata',
    (tester) async {
      _phone(tester);
      final track = fixtureTrack();
      final task = CompletionTask(
        trackId: track.id,
        trackTitle: track.displayTitle,
        createdAt: DateTime(2026),
        status: TaskStatus.needsReview,
        message: '仅找到专辑，歌词没有命中',
        queriedFields: {AudioField.album, AudioField.lyrics},
        suggestions: const [
          FieldSuggestion(
            field: AudioField.album,
            value: 'Offline album',
            source: 'Offline fixture',
          ),
        ],
      );
      final controller = testController(
        store: MemoryStore(LibrarySnapshot(tracks: [track], tasks: [task])),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: CandidateReviewPage(task: task, controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await _showControl(tester, track.id);
      await tester.tap(find.text('设为纯音乐'));
      await tester.pumpAndSettle();
      expect(controller.tracks.single.isInstrumental, isTrue);
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(
        controller.tasks.single.suggestions.single.field,
        AudioField.album,
      );
      expect(controller.isTaskCurrent(task), isFalse);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-original')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
