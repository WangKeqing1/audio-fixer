import 'dart:async';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/shared/widgets/pane_entrance.dart';
import 'package:audio_fixer/shared/widgets/instrumental_control.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _PendingSource implements MetadataSource {
  final pending = Completer<List<FieldSuggestion>>();
  int calls = 0;
  @override
  String get name => 'Offline responsive fixture';
  @override
  Set<AudioField> get supportedFields => {AudioField.album};
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) {
    calls++;
    return pending.future;
  }
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets(
    'desktop uses a library and song pane, phone keeps one pane and state',
    (tester) async {
      _size(tester, const Size(1440, 1000));
      final controller = testController(
        store: MemoryStore(
          LibrarySnapshot(
            tracks: List.generate(
              30,
              (index) => fixtureTrack(id: 'song-$index', title: '我的歌曲 $index'),
            ),
          ),
        ),
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('让每一首歌更完整'), findsOneWidget);
      final list = find.byKey(const PageStorageKey('library-scroll-view'));
      expect(tester.getSize(list).width, greaterThan(480));
      await tester.enterText(find.byType(TextField), '我的歌曲');
      await tester.pumpAndSettle();
      final searchController = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('song-tile-song-8')),
        150,
        scrollable: find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(find.byKey(const ValueKey('song-tile-song-8')));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(TrackDetailPage));
      final listController = tester.widget<CustomScrollView>(list).controller!;
      final offset = listController.offset;
      expect(offset, greaterThan(0));
      final detailRect = tester.getRect(find.byType(TrackDetailPage));
      expect(detailRect.width, greaterThan(650));
      expect(detailRect.left, greaterThan(tester.getRect(list).left));
      expect(find.byKey(const ValueKey('song-next-step')), findsOneWidget);
      expect(find.text('文件名'), findsNothing);

      await _resize(tester, const Size(390, 844));
      expect(find.byType(CustomScrollView), findsNothing);
      expect(tester.state(find.byType(TrackDetailPage)), same(state));
      expect(find.byKey(const ValueKey('automatic-repair')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _resize(tester, const Size(844, 900));
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(tester.state(find.byType(TrackDetailPage)), same(state));
      expect(searchController.text, '我的歌曲');
      expect(listController.offset, closeTo(offset, 1));
      expect(tester.takeException(), isNull);

      await _resize(tester, const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('close-selected-song')));
      await tester.pumpAndSettle();
      expect(find.byType(TrackDetailPage), findsNothing);
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(searchController.text, '我的歌曲');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('query and inline review survive phone fold and desktop resize', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    final source = _PendingSource();
    final track = fixtureTrack();
    final controller = testController(
      store: MemoryStore(LibrarySnapshot(tracks: [track])),
      completion: CompletionService(sources: [source]),
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('song-tile-${track.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('automatic-repair')));
    await tester.pump();
    final state = tester.state(find.byType(TrackDetailPage));
    expect(source.calls, 1);
    await _resize(tester, const Size(844, 900));
    expect(tester.state(find.byType(TrackDetailPage)), same(state));
    expect(controller.isCompleting, isTrue);
    await _resize(tester, const Size(1440, 1000));
    expect(tester.state(find.byType(TrackDetailPage)), same(state));
    source.pending.complete(const [
      FieldSuggestion(
        field: AudioField.album,
        value: '找到的专辑',
        source: 'Offline responsive fixture',
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(CandidateReviewPage), findsOneWidget);
    expect(
      tester
          .widget<CandidateReviewPage>(find.byType(CandidateReviewPage))
          .embedded,
      isTrue,
    );
    final reviewState = tester.state(find.byType(CandidateReviewPage));
    await _resize(tester, const Size(390, 844));
    expect(tester.state(find.byType(CandidateReviewPage)), same(reviewState));
    expect(source.calls, 1);
    expect(controller.tracks.single.album, isNull);
    expect(controller.tasks.single.status, TaskStatus.needsReview);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings reflow keeps changed preferences and narrow order', (
    tester,
  ) async {
    _size(tester, const Size(1440, 1000));
    final controller = testController(
      store: MemoryStore(LibrarySnapshot(tracks: [fixtureTrack()])),
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('settings-library-completion'));
    final second = find.byKey(const ValueKey('settings-appearance-sources'));
    expect(
      tester.getTopLeft(first).dy,
      closeTo(tester.getTopLeft(second).dy, 1),
    );
    expect(
      tester.getTopLeft(second).dx,
      greaterThan(tester.getTopLeft(first).dx + 400),
    );
    final translation = find.byKey(
      const ValueKey('include-chinese-translation'),
    );
    await tester.ensureVisible(translation);
    await tester.tap(translation);
    await tester.pumpAndSettle();
    expect(controller.settings.includeChineseTranslation, isFalse);
    await _resize(tester, const Size(390, 844));
    expect(
      tester.getTopLeft(second).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
    expect(controller.settings.includeChineseTranslation, isFalse);
    await _resize(tester, const Size(1440, 1000));
    expect(tester.widget<SwitchListTile>(translation).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion shows selected song immediately without a lyrics prompt',
    (tester) async {
      _size(tester, const Size(390, 844));
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final controller = testController(
        store: MemoryStore(LibrarySnapshot(tracks: [fixtureTrack()])),
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('song-tile-fixture')));
      await tester.pump();
      await tester.pump();
      final entrance = find.byType(PaneEntrance);
      expect(entrance, findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find
                  .descendant(of: entrance, matching: find.byType(Opacity))
                  .first,
            )
            .opacity,
        1,
      );
      expect(find.byType(InstrumentalControl), findsNothing);
      await tester.ensureVisible(find.text('其他修复方式'));
      await tester.tap(find.text('其他修复方式'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mark-instrumental-option')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 740),
    const Size(844, 900),
    const Size(1920, 1080),
  ]) {
    testWidgets('compact details and fixed action fit $size with large text', (
      tester,
    ) async {
      _size(tester, size);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final controller = testController(
        store: MemoryStore(LibrarySnapshot(tracks: [fixtureTrack()])),
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('song-tile-fixture')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('song-tile-fixture')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('song-tile-fixture')));
      await tester.pumpAndSettle();
      final primary = find.byKey(const ValueKey('automatic-repair'));
      expect(tester.getRect(primary).bottom, lessThan(size.height));
      expect(tester.getRect(primary).width, lessThanOrEqualTo(size.width));
      expect(find.text('文件名'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
