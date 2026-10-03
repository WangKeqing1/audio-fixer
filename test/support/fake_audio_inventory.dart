import 'dart:async';

import 'package:audio_fixer/core/services/audio_inventory_service.dart';

class FakeInventoryRequest {
  FakeInventoryRequest(this.method, this.operationId);
  final String method;
  final int operationId;
  final completion = Completer<AudioInventoryResult>();

  void finish({
    AudioInventoryStatus status = AudioInventoryStatus.saved,
    int total = 3,
    int unreadable = 0,
    bool canRetrySave = false,
    bool possiblePartialDocument = false,
    int volumeErrors = 0,
    bool coveragePartial = false,
    String? message,
  }) => completion.complete(
    AudioInventoryResult(
      operationId: operationId,
      status: status,
      fileName: status == AudioInventoryStatus.saved ? '音频清单.txt' : null,
      totalIndexed: total,
      scanned: total,
      metadataSuccess: total - unreadable,
      unreadable: unreadable,
      canRetrySave: canRetrySave,
      possiblePartialDocument: possiblePartialDocument,
      volumeErrors: volumeErrors,
      coveragePartial: coveragePartial,
      message: message,
    ),
  );
}

class FakeAudioInventoryBackend implements AudioInventoryBackend {
  final events = StreamController<AudioInventoryProgress>.broadcast(sync: true);
  final requests = <FakeInventoryRequest>[];
  final cancellations = <int>[];
  Object? cancelError;
  Completer<void>? cancelBarrier;
  int? retainedOperationId;
  bool finishOnCancel = false;

  @override
  Stream<AudioInventoryProgress> get progress => events.stream;

  Future<AudioInventoryResult> _start(String method, int operationId) {
    final request = FakeInventoryRequest(method, operationId);
    requests.add(request);
    return request.completion.future;
  }

  @override
  Future<AudioInventoryResult> exportInventory({required int operationId}) =>
      _start('exportInventory', operationId);

  @override
  Future<AudioInventoryResult> retrySave({required int operationId}) =>
      _start('retrySave', operationId);

  @override
  Future<bool> cancelExport({required int operationId}) async {
    cancellations.add(operationId);
    if (cancelError != null) throw cancelError!;
    if (cancelBarrier case final barrier?) await barrier.future;
    if (retainedOperationId == operationId) retainedOperationId = null;
    if (finishOnCancel) {
      for (final request in requests) {
        if (request.operationId == operationId &&
            !request.completion.isCompleted) {
          request.finish(status: AudioInventoryStatus.cancelled, total: 0);
        }
      }
    }
    return true;
  }

  void emit({
    int? operationId,
    AudioInventoryPhase phase = AudioInventoryPhase.scanning,
    int scanned = 2,
    int total = 3,
    int readFailures = 0,
  }) => events.add(
    AudioInventoryProgress(
      operationId: operationId ?? requests.last.operationId,
      phase: phase,
      scanned: scanned,
      total: total,
      readFailures: readFailures,
    ),
  );
}
