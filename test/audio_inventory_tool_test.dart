import 'dart:async';

import 'package:audio_fixer/core/services/audio_inventory_service.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/settings/audio_inventory_tool.dart';
import 'package:audio_fixer/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_audio_inventory.dart';
import 'support/fakes.dart';

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder.hitTestable());
  await tester.pump();
}

Future<LibraryController> _showTool(
  WidgetTester tester,
  FakeAudioInventoryBackend backend, {
  FakeDeviceLibrary? library,
  bool throughSettings = false,
}) async {
  final controller = testController(deviceLibrary: library);
  await controller.initialize();
  await tester.pumpWidget(
    MaterialApp(
      home: throughSettings
          ? Scaffold(
              body: SettingsPage(
                controller: controller,
                inventoryServiceFactory: () =>
                    AudioInventoryService(backend: backend),
              ),
            )
          : AudioInventoryToolPage(
              controller: controller,
              serviceFactory: () => AudioInventoryService(backend: backend),
            ),
    ),
  );
  await tester.pumpAndSettle();
  if (throughSettings) {
    await _tap(tester, 'open-audio-inventory');
    await tester.pumpAndSettle();
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await backend.events.close();
  });
  return controller;
}

void main() {
  testWidgets(
    'Settings opens the tool without starting work and retains existing controls',
    (tester) async {
      final backend = FakeAudioInventoryBackend();
      await _showTool(tester, backend, throughSettings: true);
      expect(
        find.byKey(const ValueKey('audio-inventory-page')),
        findsOneWidget,
      );
      expect(find.textContaining('原文件名、相对目录和存储卷'), findsOneWidget);
      expect(find.textContaining('被本应用排除的文件夹'), findsOneWidget);
      expect(find.textContaining('不会自动上传或分享'), findsOneWidget);
      expect(backend.requests, isEmpty);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('exclude-short-audio')),
        -300,
      );
      expect(find.byKey(const ValueKey('exclude-short-audio')), findsOneWidget);
      final translation = find.byKey(
        const ValueKey('include-chinese-translation'),
      );
      await tester.scrollUntilVisible(translation, 300);
      await tester.pumpAndSettle();
      expect(translation, findsOneWidget);
      expect(
        find.byKey(const ValueKey('on-device-translation')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing permission uses only the explicit library authorization button',
    (tester) async {
      final backend = FakeAudioInventoryBackend();
      final library = FakeDeviceLibrary()
        ..permission = AudioLibraryPermission.denied;
      await _showTool(tester, backend, library: library);
      expect(library.requestCount, 0);
      expect(backend.requests, isEmpty);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('start-audio-inventory')),
            )
            .onPressed,
        isNull,
      );
      await _tap(tester, 'authorize-audio-inventory');
      await tester.pumpAndSettle();
      expect(library.requestCount, 1);
      expect(library.permission, AudioLibraryPermission.granted);
      expect(backend.requests, isEmpty);
      await _tap(tester, 'start-audio-inventory');
      expect(backend.requests, hasLength(1));
      backend.requests.single.finish();
      await tester.pumpAndSettle();
      expect(find.text('TXT 已保存'), findsOneWidget);
    },
  );

  testWidgets(
    'blocked permission routes to system settings without a hidden export',
    (tester) async {
      final backend = FakeAudioInventoryBackend();
      final library = FakeDeviceLibrary()
        ..permission = AudioLibraryPermission.blocked;
      await _showTool(tester, backend, library: library);
      await _tap(tester, 'authorize-audio-inventory');
      await tester.pumpAndSettle();
      expect(library.settingsCount, 1);
      expect(library.requestCount, 0);
      expect(backend.requests, isEmpty);
      expect(find.text('TXT 已保存'), findsNothing);
    },
  );

  testWidgets(
    'progress shows raw scan counts and app operations wait until cancellation finishes',
    (tester) async {
      final backend = FakeAudioInventoryBackend();
      final library = FakeDeviceLibrary()
        ..permission = AudioLibraryPermission.granted;
      final controller = await _showTool(tester, backend, library: library);
      await _tap(tester, 'start-audio-inventory');
      final queries = library.queryCount;
      expect(controller.canOperate, isFalse);
      await controller.refreshLibrary();
      expect(library.queryCount, queries);
      backend.emit(scanned: 200, total: -1, readFailures: 4);
      await tester.pump();
      expect(find.textContaining('已读取 200 / 总数统计中'), findsOneWidget);
      expect(find.textContaining('文件标签读取失败 4 条'), findsOneWidget);
      await _tap(tester, 'start-audio-inventory');
      expect(backend.requests, hasLength(1));
      await _tap(tester, 'cancel-audio-inventory');
      expect(find.text('正在取消…'), findsOneWidget);
      expect(controller.canOperate, isFalse);
      backend.requests.single.finish(
        status: AudioInventoryStatus.cancelled,
        total: 200,
      );
      await tester.pumpAndSettle();
      expect(controller.canOperate, isTrue);
      expect(find.text('导出已取消'), findsOneWidget);
      expect(find.text('TXT 已保存'), findsNothing);
    },
  );

  testWidgets(
    'SAF cancel and save failure allow explicit retry without rescanning',
    (tester) async {
      final backend = FakeAudioInventoryBackend();
      await _showTool(tester, backend);
      await _tap(tester, 'start-audio-inventory');
      backend.emit(phase: AudioInventoryPhase.choosingDestination, scanned: 3);
      await tester.pump();
      expect(find.textContaining('系统窗口选择 TXT 保存位置'), findsOneWidget);
      backend.requests.last.finish(
        status: AudioInventoryStatus.cancelled,
        canRetrySave: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('TXT 已保存'), findsNothing);
      await _tap(tester, 'retry-audio-inventory-save');
      expect(backend.requests.last.method, 'retrySave');
      backend.requests.last.finish(
        status: AudioInventoryStatus.failed,
        canRetrySave: true,
        possiblePartialDocument: true,
        message: '保存窗口返回后写入失败。',
      );
      await tester.pumpAndSettle();
      expect(find.text('TXT 未能完整保存'), findsOneWidget);
      expect(find.textContaining('不完整的 TXT 文件'), findsOneWidget);
      expect(find.text('TXT 已保存'), findsNothing);
      await _tap(tester, 'retry-audio-inventory-save');
      backend.requests.last.finish(unreadable: 1);
      await tester.pumpAndSettle();
      expect(find.text('TXT 已保存'), findsOneWidget);
      expect(find.textContaining('文件标签不完整'), findsOneWidget);
      expect(backend.requests.map((request) => request.method), [
        'exportInventory',
        'retrySave',
        'retrySave',
      ]);
    },
  );

  testWidgets(
    'late permission loss and picker failures explain status without raw errors',
    (tester) async {
      final backend = FakeAudioInventoryBackend();
      final library = FakeDeviceLibrary()
        ..permission = AudioLibraryPermission.granted;
      await _showTool(tester, backend, library: library);
      await _tap(tester, 'start-audio-inventory');
      library.permission = AudioLibraryPermission.denied;
      backend.requests.last.completion.completeError(
        PlatformException(code: 'permission_denied', message: 'RAW STACK'),
      );
      await tester.pumpAndSettle();
      expect(find.text('音频权限不可用'), findsOneWidget);
      expect(find.textContaining('RAW STACK'), findsNothing);
      expect(find.text('TXT 已保存'), findsNothing);
      await _tap(tester, 'authorize-audio-inventory');
      await tester.pumpAndSettle();
      expect(library.requestCount, 1);
      await _tap(tester, 'start-audio-inventory');
      backend.requests.last.completion.completeError(
        PlatformException(code: 'picker_unavailable'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('无法打开系统保存窗口'), findsOneWidget);
      expect(find.text('TXT 已保存'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saved report explicitly labels incomplete volume coverage', (
    tester,
  ) async {
    final backend = FakeAudioInventoryBackend();
    await _showTool(tester, backend);
    await _tap(tester, 'start-audio-inventory');
    backend.requests.single.finish(volumeErrors: 2, coveragePartial: true);
    await tester.pumpAndSettle();
    expect(find.text('TXT 已保存'), findsOneWidget);
    expect(find.textContaining('2 个存储卷未能完整读取'), findsOneWidget);
    expect(find.textContaining('清单覆盖不完整'), findsOneWidget);
  });

  testWidgets(
    'leaving the route cancels generation and releases the app lock after native cleanup',
    (tester) async {
      final backend = FakeAudioInventoryBackend()..finishOnCancel = true;
      final controller = await _showTool(
        tester,
        backend,
        throughSettings: true,
      );
      await _tap(tester, 'start-audio-inventory');
      final oldId = backend.requests.single.operationId;
      expect(controller.canOperate, isFalse);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('audio-inventory-page')), findsNothing);
      expect(backend.cancellations, contains(oldId));
      expect(controller.canOperate, isTrue);
      await _tap(tester, 'open-audio-inventory');
      await tester.pumpAndSettle();
      await _tap(tester, 'start-audio-inventory');
      expect(backend.requests.last.operationId, greaterThan(oldId));
      backend.emit(operationId: oldId, scanned: 999);
      await tester.pump();
      expect(find.textContaining('已读取 999'), findsNothing);
      backend.requests.last.finish();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'small landscape and large text keep details and actions reachable',
    (tester) async {
      tester.view.physicalSize = const Size(640, 400);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final backend = FakeAudioInventoryBackend();
      await _showTool(tester, backend);
      await _tap(tester, 'start-audio-inventory');
      backend.emit(scanned: 1000, total: 8000, readFailures: 12);
      await tester.pump();
      await _tap(tester, 'cancel-audio-inventory');
      backend.requests.last.finish(
        status: AudioInventoryStatus.cancelled,
        total: 1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('导出已取消'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late complete TXT after route exit is discarded before unlocking the app',
    (tester) async {
      final backend = FakeAudioInventoryBackend();
      final controller = await _showTool(
        tester,
        backend,
        throughSettings: true,
      );
      await _tap(tester, 'start-audio-inventory');
      final id = backend.requests.single.operationId;
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('audio-inventory-page')), findsNothing);
      expect(controller.canOperate, isFalse);
      final initialCancels = backend.cancellations.length;
      expect(initialCancels, greaterThan(0));
      final cleanup = Completer<void>();
      backend.cancelBarrier = cleanup;
      backend.retainedOperationId = id;
      backend.requests.single.finish(
        status: AudioInventoryStatus.cancelled,
        canRetrySave: true,
      );
      await tester.pump();
      expect(backend.cancellations.length, initialCancels + 1);
      expect(backend.cancellations.last, id);
      expect(controller.canOperate, isFalse);
      expect(backend.retainedOperationId, id);
      cleanup.complete();
      await tester.pumpAndSettle();
      expect(controller.canOperate, isTrue);
      expect(backend.retainedOperationId, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
