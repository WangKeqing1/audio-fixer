import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void phoneSize(WidgetTester tester, {double textScale = 1}) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  testWidgets('refresh failure keeps cached music visible and can retry', (
    tester,
  ) async {
    phoneSize(tester);
    final device = FakeDeviceLibrary()..songs = [fixtureDeviceTrack()];
    final controller = testController(deviceLibrary: device);
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();

    device.failQuery = true;
    await controller.refreshLibrary();
    await tester.pumpAndSettle();
    expect(find.text('刷新未完成，已保留上次的音乐库'), findsOneWidget);
    expect(controller.tracks, hasLength(1));
    await tester.scrollUntilVisible(
      find.text('系统歌曲1'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('系统歌曲1'), findsOneWidget);

    device.failQuery = false;
    await tester.scrollUntilVisible(
      find.text('重试刷新'),
      -200,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('重试刷新'));
    await tester.pumpAndSettle();
    expect(find.text('刷新未完成，已保留上次的音乐库'), findsNothing);
    expect(device.queryCount, 3);
    expect(controller.libraryError, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh failure without cached music offers an explicit retry', (
    tester,
  ) async {
    phoneSize(tester);
    final device = FakeDeviceLibrary()..failQuery = true;
    final controller = testController(deviceLibrary: device);
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('音乐库刷新失败'), findsOneWidget);
    expect(find.text('系统音乐库中还没有歌曲'), findsNothing);
    device.failQuery = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('系统音乐库中还没有歌曲'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library actions have labels and Android-sized tap targets', (
    tester,
  ) async {
    phoneSize(tester);
    final semantics = tester.ensureSemantics();
    final controller = testController(
      store: MemoryStore(LibrarySnapshot(tracks: [fixtureTrack()])),
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });

  testWidgets('unchecked tracks and confirmed missing fields are separate', (
    tester,
  ) async {
    phoneSize(tester);
    final controller = testController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [
            fixtureDeviceTrack(id: 'pending'),
            fixtureTrack(id: 'missing', title: '确认缺失的歌曲'),
            fixtureTrack(id: 'error', title: '读取失败的歌曲', readError: '读取失败'),
            AudioTrack(
              id: 'complete',
              fileName: 'complete.mp3',
              sizeBytes: 1024,
              importedAt: DateTime(2026),
              title: '完整歌曲',
              artist: '歌手',
              album: '专辑',
              lyrics: '歌词',
              artworkPath: '/fixture/cover.jpg',
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('全部 4'), findsOneWidget);
    expect(find.text('待检查 1'), findsOneWidget);
    expect(find.text('待补全 1'), findsOneWidget);
    expect(find.text('读取异常 1'), findsOneWidget);
    expect(find.text('已检查 3 首'), findsOneWidget);
    expect(find.text('资料完整 1 首'), findsOneWidget);

    await tester.tap(find.text('待补全 1'));
    await tester.pumpAndSettle();
    expect(find.text('确认缺失的歌曲'), findsOneWidget);
    expect(find.text('系统歌曲pending'), findsNothing);
    expect(find.text('读取失败的歌曲'), findsNothing);
    expect(find.text('完整歌曲'), findsNothing);

    await tester.tap(find.text('待检查 1'));
    await tester.pumpAndSettle();
    expect(find.text('系统歌曲pending'), findsOneWidget);
    expect(find.text('确认缺失的歌曲'), findsNothing);
    expect(find.textContaining('待检查不代表资料缺失'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album search, clearing and empty results are recoverable', (
    tester,
  ) async {
    phoneSize(tester);
    final controller = testController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [
            AudioTrack(
              id: 'search',
              fileName: 'afternoon.flac',
              sizeBytes: 1024,
              importedAt: DateTime(2026),
              title: '午后散步',
              artist: '示例歌手',
              album: '城市漫游',
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '城市漫游');
    await tester.pumpAndSettle();
    expect(find.text('午后散步'), findsOneWidget);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );

    await tester.enterText(find.byType(TextField), '不存在的音乐');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的歌曲'), findsOneWidget);
    await tester.ensureVisible(find.text('查看全部歌曲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看全部歌曲').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('午后散步'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text keeps status filters and settings usable', (
    tester,
  ) async {
    phoneSize(tester, textScale: 2);
    tester.view.physicalSize = const Size(320, 740);
    final controller = testController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [fixtureDeviceTrack()],
          settings: const AppSettings(theme: AppTheme.dark),
        ),
      ),
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('读取异常 0').hitTestable());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查看全部歌曲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看全部歌曲').hitTestable());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('音乐库排除规则'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('关于 Audio Fixer'),
      350,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('settings')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('关于 Audio Fixer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
