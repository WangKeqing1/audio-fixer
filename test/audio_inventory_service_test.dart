import 'dart:async';

import 'package:audio_fixer/core/services/audio_inventory_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_audio_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAudioInventoryBackend backend;
  late AudioInventoryService service;

  setUp(() {
    backend = FakeAudioInventoryBackend();
    service = AudioInventoryService(backend: backend);
  });
  tearDown(() async {
    service.dispose();
    await backend.events.close();
  });

  test(
    'reports unknown totals and failures until the final save result',
    () async {
      final exporting = service.exportInventory();
      expect(service.isRunning, isTrue);
      backend.emit(scanned: 7, total: -1, readFailures: 2);
      expect(service.scanned, 7);
      expect(service.total, -1);
      expect(service.readFailures, 2);
      backend.emit(phase: AudioInventoryPhase.complete, scanned: 12, total: 12);
      expect(service.result, isNull);
      expect(service.phase, AudioInventoryPhase.saving);
      expect(service.isRunning, isTrue);
      backend.requests.single.finish(total: 12, unreadable: 2);
      final result = await exporting;
      expect(result!.isSaved, isTrue);
      expect(service.phase, AudioInventoryPhase.complete);
      expect(service.scanned, 12);
      expect(service.readFailures, 2);
      expect(service.result!.metadataSuccess, 10);
    },
  );

  test(
    'double starts and cancel keep the operation occupied until native exits',
    () async {
      final exporting = service.exportInventory();
      final id = backend.requests.single.operationId;
      expect(await service.exportInventory(), isNull);
      await Future.wait([service.cancel(), service.cancel()]);
      expect(backend.cancellations, [id]);
      expect(service.isRunning, isTrue);
      expect(service.phase, AudioInventoryPhase.cancelling);
      backend.emit(phase: AudioInventoryPhase.scanning, scanned: 3);
      expect(service.phase, AudioInventoryPhase.cancelling);
      expect(await service.exportInventory(), isNull);
      backend.requests.single.finish(status: AudioInventoryStatus.cancelled);
      expect((await exporting)!.status, AudioInventoryStatus.cancelled);
      expect(service.isRunning, isFalse);
      expect(service.canRetrySave, isFalse);
    },
  );

  test(
    'SAF cancellation can retry only saving, using a new event identity',
    () async {
      final exporting = service.exportInventory();
      final original = backend.requests.single;
      original.finish(
        status: AudioInventoryStatus.cancelled,
        canRetrySave: true,
      );
      await exporting;
      expect(service.canRetrySave, isTrue);
      final retrying = service.retrySave();
      final retry = backend.requests.last;
      expect(retry.method, 'retrySave');
      expect(retry.operationId, greaterThan(original.operationId));
      expect(await service.retrySave(), isNull);
      backend.emit(
        operationId: original.operationId,
        scanned: 500,
        readFailures: 30,
      );
      expect(service.scanned, 3);
      expect(service.readFailures, 0);
      retry.finish();
      await retrying;
      expect(service.canRetrySave, isFalse);
      expect(await service.retrySave(), isNull);
      expect(backend.requests.map((item) => item.method), [
        'exportInventory',
        'retrySave',
      ]);
    },
  );

  test(
    'partial write is a failure with retained retry, never saved success',
    () async {
      final exporting = service.exportInventory();
      backend.requests.single.finish(
        status: AudioInventoryStatus.failed,
        canRetrySave: true,
        possiblePartialDocument: true,
        message: '写入失败，完整清单暂时保留。',
      );
      final result = await exporting;
      expect(result!.isSaved, isFalse);
      expect(result.possiblePartialDocument, isTrue);
      expect(service.phase, AudioInventoryPhase.failed);
      expect(service.canRetrySave, isTrue);
    },
  );

  test('permission and picker errors are readable and do not expose raw exceptions', () async {
    for (final entry in [
      ('permission_denied', '权限'),
      ('picker_unavailable', '保存窗口'),
      ('save_failed', '不完整'),
    ]) {
      final exporting = service.exportInventory();
      backend.requests.last.completion.completeError(
        PlatformException(code: entry.$1, message: 'RAW PRIVATE STACK TRACE'),
      );
      final result = await exporting;
      expect(result!.isSaved, isFalse);
      expect(result.message, contains(entry.$2));
      expect(result.message, isNot(contains('RAW PRIVATE')));
      expect(
        result.status,
        entry.$1 == 'permission_denied'
            ? AudioInventoryStatus.permissionDenied
            : AudioInventoryStatus.failed,
      );
      expect(service.canRetrySave, isFalse);
    }
  });

  test('stream errors do not invent terminal success and final outcome is still used', () async {
    final exporting = service.exportInventory();
    backend.events.addError(const FormatException('bad event'));
    expect(service.progressWarning, contains('最终保存结果'));
    expect(service.result, isNull);
    expect(service.isRunning, isTrue);
    backend.requests.single.finish(status: AudioInventoryStatus.failed);
    await exporting;
    expect(service.phase, AudioInventoryPhase.failed);
  });

  test(
    'dispose cancels its native owner and ignores late events/results',
    () async {
      final exporting = service.exportInventory();
      final id = backend.requests.single.operationId;
      var changes = 0;
      service.addListener(() => changes++);
      service.dispose();
      backend.emit(scanned: 20);
      backend.requests.single.finish(status: AudioInventoryStatus.cancelled);
      await exporting;
      expect(backend.cancellations, [id, id]);
      expect(changes, 0);
      expect(await service.exportInventory(), isNull);
      final replacement = AudioInventoryService(backend: backend);
      final nextExport = replacement.exportInventory();
      final next = backend.requests.last;
      expect(next.operationId, greaterThan(id));
      backend.emit(operationId: id, scanned: 999);
      expect(replacement.scanned, 0);
      next.finish();
      await nextExport;
      replacement.dispose();
    },
  );

  test(
    'disposing idle retry session discards its retained native TXT',
    () async {
      final exporting = service.exportInventory();
      backend.requests.single.finish(
        status: AudioInventoryStatus.cancelled,
        canRetrySave: true,
      );
      await exporting;
      service.dispose();
      expect(backend.cancellations, [backend.requests.single.operationId]);
    },
  );

  test(
    'cancelling from the first notification never starts native generation',
    () async {
      var requested = false;
      service.addListener(() {
        if (requested) return;
        requested = true;
        unawaited(service.cancel());
      });
      expect(
        (await service.exportInventory())!.status,
        AudioInventoryStatus.cancelled,
      );
      expect(backend.requests, isEmpty);
    },
  );

  test('disposed terminal retry report is discarded before the operation completes', () async {
    final exporting = service.exportInventory();
    final id = backend.requests.single.operationId;
    var returned = false;
    unawaited(exporting.then((_) => returned = true));
    service.dispose();
    expect(backend.cancellations, [id]);
    final cleanup = Completer<void>();
    backend.cancelBarrier = cleanup;
    backend.retainedOperationId = id;
    backend.requests.single.finish(
      status: AudioInventoryStatus.cancelled,
      canRetrySave: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.cancellations, [id, id]);
    expect(returned, isFalse);
    expect(service.isRunning, isTrue);
    expect(backend.retainedOperationId, id);
    cleanup.complete();
    await exporting;
    expect(returned, isTrue);
    expect(service.isRunning, isFalse);
    expect(backend.retainedOperationId, isNull);
  });

  test('cancel errors remain pending and show a safe action instead of claiming cancellation', () async {
    final exporting = service.exportInventory();
    backend.cancelError = StateError('private stack');
    await service.cancel();
    expect(service.progressWarning, contains('取消请求暂未确认'));
    expect(service.isRunning, isTrue);
    expect(service.result, isNull);
    backend.requests.single.finish(status: AudioInventoryStatus.cancelled);
    await exporting;
    expect(service.phase, AudioInventoryPhase.cancelled);
  });

  test('wrong operation result and contradictory partial success cannot report saved', () async {
    var exporting = service.exportInventory();
    backend.requests.last.completion.complete(
      const AudioInventoryResult(
        operationId: -1,
        status: AudioInventoryStatus.saved,
        fileName: 'wrong.txt',
      ),
    );
    expect((await exporting)!.status, AudioInventoryStatus.failed);
    exporting = service.exportInventory();
    backend.requests.last.finish(possiblePartialDocument: true);
    expect((await exporting)!.status, AudioInventoryStatus.failed);
  });

  test(
    'method channel serializes IDs and safely parses platform output',
    () async {
      const channel = MethodChannel('audio_fixer/inventory_test');
      const events = EventChannel('audio_fixer/inventory_events_test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'cancelExport') return true;
        return {
          'operationId': (call.arguments as Map)['operationId'],
          'status': 'saved',
          'fileName': '中文🎵清单.txt',
          'totalIndexed': 5,
          'scanned': 5,
          'metadataSuccess': 4,
          'unreadable': 1,
          'canRetrySave': false,
          'possiblePartialDocument': false,
        };
      });
      messenger.setMockMethodCallHandler(
        MethodChannel(events.name),
        (_) async => null,
      );
      final platform = MethodChannelAudioInventoryBackend(
        channel: channel,
        eventChannel: events,
      );
      final progress = <AudioInventoryProgress>[];
      final subscription = platform.progress.listen(progress.add);
      try {
        final result = await platform.exportInventory(operationId: 42);
        await messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'operationId': 42,
            'phase': 'scanning',
            'scanned': 3,
            'total': -1,
            'readFailures': 1,
          }),
          (_) {},
        );
        expect(progress.single.operationId, 42);
        expect(progress.single.total, -1);
        expect(progress.single.readFailures, 1);
        expect(result.fileName, '中文🎵清单.txt');
        expect(result.unreadable, 1);
        await platform.retrySave(operationId: 43);
        expect(await platform.cancelExport(operationId: 43), isTrue);
        expect(calls.map((call) => call.method), [
          'exportInventory',
          'retrySave',
          'cancelExport',
        ]);
        expect(calls.map((call) => call.arguments), [
          {'operationId': 42},
          {'operationId': 43},
          {'operationId': 43},
        ]);
      } finally {
        await subscription.cancel();
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
      }
    },
  );

  test('native map rejects unknown statuses and unsafe saved responses', () {
    expect(
      () => AudioInventoryResult.fromMap({'status': 'unknown'}),
      throwsArgumentError,
    );
    expect(
      () => AudioInventoryResult.fromMap({
        'operationId': 1,
        'status': 'saved',
        'fileName': 'a.txt',
        'possiblePartialDocument': true,
      }),
      throwsFormatException,
    );
    final denied = AudioInventoryResult.fromMap({
      'operationId': 1,
      'status': 'permissionDenied',
      'canRetrySave': true,
    });
    expect(denied.canRetrySave, isFalse);
  });
}
