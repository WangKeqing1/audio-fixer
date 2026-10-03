import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_folder.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void _phone(
  WidgetTester tester, {
  double scale = 1,
  Size size = const Size(390, 844),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

AudioTrack _track(
  String id, {
  int? duration = 60000,
  String folder = 'Music/Album',
}) => AudioTrack(
  id: id,
  fileName: '$id.mp3',
  title: '歌曲$id',
  sizeBytes: 1024,
  importedAt: DateTime(2026),
  durationMs: duration,
  volumeName: 'external_primary',
  relativePath: folder,
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'fixed selection toolbar survives long scrolling at text scale $scale',
      (tester) async {
        _phone(tester, scale: scale, size: const Size(320, 740));
        final controller = testController(
          completion: CompletionService(sources: [NoResultMetadataSource()]),
          store: MemoryStore(
            LibrarySnapshot(
              tracks: [for (var i = 0; i < 60; i++) _track('$i')],
            ),
          ),
        );
        await tester.pumpWidget(AudioFixerApp(controller: controller));
        await tester.pumpAndSettle();
        await _tap(
          tester,
          find.byKey(const ValueKey('toggle-library-selection')),
        );
        final toolbar = find.byKey(
          const ValueKey('fixed-library-selection-toolbar'),
        );
        final before = tester.getRect(toolbar);
        await tester.tap(find.byKey(const ValueKey('select-visible-tracks')));
        await tester.pumpAndSettle();
        expect(controller.selectedCount, 60);
        await tester.drag(
          find.byKey(const PageStorageKey('library-scroll-view')),
          const Offset(0, -1600),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(toolbar), before);
        expect(
          find.byKey(const ValueKey('select-visible-tracks')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('bulk-query-selected')).hitTestable(),
          findsOneWidget,
        );
        final list = tester.getRect(
          find.byKey(const PageStorageKey('library-scroll-view')),
        );
        expect(list.bottom, lessThanOrEqualTo(before.top));
        expect(list.height, greaterThan(150));
        await tester.tap(find.byKey(const ValueKey('bulk-query-selected')));
        await tester.pumpAndSettle();
        expect(find.text('查询 60 首歌曲？'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(controller.selectedCount, 60);
        await tester.tap(find.byKey(const ValueKey('clear-library-selection')));
        await tester.pumpAndSettle();
        expect(controller.selectedCount, 0);
        expect(toolbar, findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('toggle-library-selection')),
        );
        await tester.pumpAndSettle();
        expect(toolbar, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'short filter counts exclusions, preserves 60s and unknown, can reset all-hidden',
    (tester) async {
      _phone(tester);
      final store = MemoryStore(
        LibrarySnapshot(
          tracks: [
            _track('short', duration: 59999),
            _track('boundary'),
            _track('unknown', duration: null),
          ],
        ),
      );
      final controller = testController(store: store);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byKey(const ValueKey('library-exclusion-summary')),
      );
      await _tap(tester, find.byKey(const ValueKey('exclude-short-audio')));
      expect(controller.tracks.map((track) => track.id), [
        'boundary',
        'unknown',
      ]);
      expect(store.snapshot.settings.excludeShortAudio, isTrue);
      expect(find.textContaining('已排除 1 首'), findsOneWidget);
      expect(find.textContaining('1 首时长未知'), findsOneWidget);
      await _tap(
        tester,
        find.byKey(const ValueKey('reset-library-exclusions')),
      );
      expect(controller.tracks.length, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('folder choice covers descendants only and Back cancels draft', (
    tester,
  ) async {
    _phone(tester);
    final controller = testController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [
            _track('child', folder: 'Music/Podcasts/Episode'),
            _track('sibling', folder: 'Music/Podcasts-old'),
          ],
        ),
      ),
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('library-exclusion-summary')));
    await _tap(tester, find.byKey(const ValueKey('manage-excluded-folders')));
    const folder = AudioFolder(
      volumeName: 'external_primary',
      relativePath: 'Music/Podcasts',
    );
    await _tap(tester, find.byKey(ValueKey('exclude-folder-${folder.id}')));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(controller.settings.excludedFolders, isEmpty);
    await _tap(tester, find.byKey(const ValueKey('manage-excluded-folders')));
    await _tap(tester, find.byKey(ValueKey('exclude-folder-${folder.id}')));
    await _tap(tester, find.byKey(const ValueKey('apply-folder-exclusions')));
    expect(controller.tracks.single.id, 'sibling');
    expect(controller.allTracks.length, 2);
    expect(find.textContaining('已选择 1 个文件夹'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all-excluded library keeps rule controls reachable and saved settings persist',
    (tester) async {
      _phone(tester);
      final store = MemoryStore(
        LibrarySnapshot(
          tracks: [_track('short', duration: 1)],
          settings: const AppSettings(excludeShortAudio: true),
        ),
      );
      final controller = testController(store: store);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('系统音乐库中还没有歌曲'), findsNothing);
      expect(find.text('歌曲已被排除规则隐藏'), findsOneWidget);
      await _tap(tester, find.text('调整排除规则'));
      await _tap(
        tester,
        find.byKey(const ValueKey('reset-library-exclusions')),
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(controller.tracks.single.id, 'short');
      expect(store.snapshot.tracks.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'folder settings remain usable with large text and keyboard in short landscape',
    (tester) async {
      _phone(tester, scale: 2, size: const Size(640, 400));
      final controller = testController(
        store: MemoryStore(LibrarySnapshot(tracks: [_track('one')])),
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byKey(const ValueKey('library-exclusion-summary')),
      );
      await _tap(tester, find.byKey(const ValueKey('manage-excluded-folders')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('search-excluded-folders')),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 190);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
        find.byKey(const ValueKey('search-excluded-folders')),
        'Music',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('apply-folder-exclusions')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'folder persistence failure keeps draft open and original rows intact',
    (tester) async {
      _phone(tester);
      final store = MemoryStore(LibrarySnapshot(tracks: [_track('one')]));
      final controller = testController(store: store);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byKey(const ValueKey('library-exclusion-summary')),
      );
      await _tap(tester, find.byKey(const ValueKey('manage-excluded-folders')));
      const folder = AudioFolder(
        volumeName: 'external_primary',
        relativePath: 'Music/Album',
      );
      await _tap(tester, find.byKey(ValueKey('exclude-folder-${folder.id}')));
      store.failSave = true;
      await _tap(tester, find.byKey(const ValueKey('apply-folder-exclusions')));
      expect(find.byKey(const ValueKey('folder-filter-page')), findsOneWidget);
      expect(controller.settings.excludedFolders, isEmpty);
      expect(controller.allTracks.length, 1);
      store.failSave = false;
      await _tap(tester, find.byKey(const ValueKey('apply-folder-exclusions')));
      expect(find.byKey(const ValueKey('folder-filter-page')), findsNothing);
      expect(controller.tracks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
