import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'system library loads automatically and details and completion work',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = FakeDeviceLibrary()..songs = [fixtureDeviceTrack()];
      final controller = testController(deviceLibrary: library);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      expect(library.requestCount, 1);
      expect(library.queryCount, 1);
      expect(find.text('导入音频'), findsNothing);
      expect(find.text('系统歌曲1'), findsOneWidget);
      await tester.tap(find.text('系统歌曲1'));
      await tester.pumpAndSettle();
      expect(find.text('歌曲资料'), findsOneWidget);
      expect(library.detailsCount, 1);
      expect(controller.tracks.single.lyrics, '文件内嵌歌词');
      await tester.ensureVisible(find.text('歌词'));
      await tester.tap(find.text('歌词'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('文件内嵌歌词'),
        350,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('文件内嵌歌词'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('automatic-repair')));
      await tester.pumpAndSettle();
      expect(controller.tasks, isEmpty);
      expect(controller.notice, contains('在线来源'));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('automatic-repair-result')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('automatic-repair')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补全任务'));
      await tester.pumpAndSettle();
      expect(find.text('等待接入在线数据源'), findsOneWidget);
      expect(controller.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(320, 740), const Size(900, 900)]) {
    testWidgets(
      'navigation and settings fit $size with enlarged text and dark theme',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.8;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final controller = testController(
          store: MemoryStore(
            LibrarySnapshot(
              tracks: [fixtureTrack(title: '这是一首用于验证长标题和大字体显示的测试歌曲')],
              settings: const AppSettings(theme: AppTheme.dark),
            ),
          ),
        );
        await tester.pumpWidget(AudioFixerApp(controller: controller));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        expect(find.text('音乐库排除规则'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
