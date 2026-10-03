import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum AudioInventoryPhase {
  idle,
  querying,
  scanning,
  choosingDestination,
  saving,
  cancelling,
  complete,
  cancelled,
  failed,
}

enum AudioInventoryStatus { saved, cancelled, failed, permissionDenied, busy }

@immutable
class AudioInventoryProgress {
  const AudioInventoryProgress({
    required this.operationId,
    required this.phase,
    required this.scanned,
    required this.total,
    required this.readFailures,
  });

  final int operationId;
  final AudioInventoryPhase phase;
  final int scanned;
  final int total;
  final int readFailures;

  factory AudioInventoryProgress.fromMap(Map<dynamic, dynamic> value) =>
      AudioInventoryProgress(
        operationId: (value['operationId'] as num).toInt(),
        phase: AudioInventoryPhase.values.byName(value['phase'] as String),
        scanned: _count(value['scanned']),
        total: value['total'] is num && (value['total'] as num) >= 0
            ? (value['total'] as num).toInt()
            : -1,
        readFailures: _count(value['readFailures']),
      );
}

@immutable
class AudioInventoryResult {
  const AudioInventoryResult({
    required this.operationId,
    required this.status,
    this.fileName,
    this.totalIndexed = 0,
    this.scanned = 0,
    this.metadataSuccess = 0,
    this.unreadable = 0,
    this.volumeErrors = 0,
    this.coveragePartial = false,
    this.canRetrySave = false,
    this.possiblePartialDocument = false,
    this.message,
  });

  final int operationId;
  final AudioInventoryStatus status;
  final String? fileName;
  final int totalIndexed;
  final int scanned;
  final int metadataSuccess;
  final int unreadable;
  final int volumeErrors;
  final bool coveragePartial;
  final bool canRetrySave;
  final bool possiblePartialDocument;
  final String? message;

  bool get isSaved => status == AudioInventoryStatus.saved;

  factory AudioInventoryResult.fromMap(Map<dynamic, dynamic> value) {
    final status = AudioInventoryStatus.values.byName(
      value['status'] as String,
    );
    final fileName = value['fileName'] as String?;
    final possiblePartialDocument = value['possiblePartialDocument'] == true;
    if (status == AudioInventoryStatus.saved &&
        (fileName == null || fileName.isEmpty || possiblePartialDocument)) {
      throw const FormatException('清单保存结果不完整');
    }
    return AudioInventoryResult(
      operationId: (value['operationId'] as num).toInt(),
      status: status,
      fileName: fileName,
      totalIndexed: _count(value['totalIndexed']),
      scanned: _count(value['scanned']),
      metadataSuccess: _count(value['metadataSuccess']),
      unreadable: _count(value['unreadable']),
      volumeErrors: _count(value['volumeErrors']),
      coveragePartial: value['coveragePartial'] == true,
      canRetrySave:
          value['canRetrySave'] == true &&
          status != AudioInventoryStatus.saved &&
          status != AudioInventoryStatus.permissionDenied &&
          status != AudioInventoryStatus.busy,
      possiblePartialDocument: possiblePartialDocument,
      message: value['message'] as String?,
    );
  }
}

int _count(Object? value) => value is num && value >= 0 ? value.toInt() : 0;

abstract interface class AudioInventoryBackend {
  Stream<AudioInventoryProgress> get progress;
  Future<AudioInventoryResult> exportInventory({required int operationId});
  Future<AudioInventoryResult> retrySave({required int operationId});
  Future<bool> cancelExport({required int operationId});
}

class MethodChannelAudioInventoryBackend implements AudioInventoryBackend {
  MethodChannelAudioInventoryBackend({
    this.channel = const MethodChannel('audio_fixer/audio_inventory'),
    this.eventChannel = const EventChannel(
      'audio_fixer/audio_inventory_progress',
    ),
  });

  final MethodChannel channel;
  final EventChannel eventChannel;
  Stream<AudioInventoryProgress>? _progress;

  @override
  Stream<AudioInventoryProgress> get progress => _progress ??= eventChannel
      .receiveBroadcastStream()
      .map((event) => AudioInventoryProgress.fromMap(event as Map));

  Future<AudioInventoryResult> _run(String method, int operationId) async {
    final value = await channel.invokeMapMethod<dynamic, dynamic>(method, {
      'operationId': operationId,
    });
    if (value == null) throw const FormatException('未收到清单保存结果');
    final result = AudioInventoryResult.fromMap(value);
    if (result.operationId != operationId) {
      throw const FormatException('清单操作已变化');
    }
    return result;
  }

  @override
  Future<AudioInventoryResult> exportInventory({required int operationId}) =>
      _run('exportInventory', operationId);

  @override
  Future<AudioInventoryResult> retrySave({required int operationId}) =>
      _run('retrySave', operationId);

  @override
  Future<bool> cancelExport({required int operationId}) async =>
      await channel.invokeMethod<bool>('cancelExport', {
        'operationId': operationId,
      }) ??
      false;
}

/// Owns one report session. Native code streams the report and retains it only
/// while this page can retry a cancelled or failed document save.
class AudioInventoryService extends ChangeNotifier {
  AudioInventoryService({AudioInventoryBackend? backend})
    : _backend = backend ?? MethodChannelAudioInventoryBackend();

  // Page replacement must not reuse an ID while old platform events are queued.
  static int _nextOperationId = 0;
  final AudioInventoryBackend _backend;
  StreamSubscription<AudioInventoryProgress>? _subscription;
  int? _operationId;
  int? _nativeOperationId;
  bool _disposed = false;
  bool _running = false;
  bool _cancelRequested = false;
  Future<void>? _cancelling;

  AudioInventoryPhase phase = AudioInventoryPhase.idle;
  int scanned = 0;
  int total = -1;
  int readFailures = 0;
  AudioInventoryResult? result;
  String? progressWarning;

  bool get isRunning => _running;
  bool get isCancelling => _cancelRequested;
  bool get canRetrySave => !_running && result?.canRetrySave == true;

  Future<AudioInventoryResult?> exportInventory() => _run(retry: false);

  Future<AudioInventoryResult?> retrySave() async {
    if (!canRetrySave) return null;
    return _run(retry: true);
  }

  Future<AudioInventoryResult?> _run({required bool retry}) async {
    if (_disposed || _running) return null;
    final operationId = ++_nextOperationId;
    _operationId = operationId;
    _running = true;
    _cancelRequested = false;
    _cancelling = null;
    result = null;
    progressWarning = null;
    phase = retry
        ? AudioInventoryPhase.choosingDestination
        : AudioInventoryPhase.querying;
    if (!retry) {
      scanned = 0;
      total = -1;
      readFailures = 0;
    }
    _notify();

    AudioInventoryResult outcome;
    try {
      if (!_disposed && !_cancelRequested) {
        _subscription ??= _backend.progress.listen(
          _onProgress,
          onError: (Object _) {
            if (!_disposed && _running) {
              progressWarning = '进度暂时无法更新，正在等待系统返回最终保存结果。';
              _notify();
            }
          },
        );
      }
      // A synchronous listener can dispose or cancel before native work starts.
      if (_disposed || _cancelRequested) {
        outcome = AudioInventoryResult(
          operationId: operationId,
          status: AudioInventoryStatus.cancelled,
          message: '已取消生成，未保存清单。',
        );
      } else {
        _nativeOperationId = operationId;
        outcome = await (retry
            ? _backend.retrySave(operationId: operationId)
            : _backend.exportInventory(operationId: operationId));
        if (outcome.operationId != operationId ||
            (outcome.isSaved &&
                (outcome.possiblePartialDocument ||
                    outcome.fileName == null ||
                    outcome.fileName!.isEmpty))) {
          throw const FormatException('清单保存结果不匹配');
        }
      }
    } catch (error) {
      outcome = AudioInventoryResult(
        operationId: operationId,
        status: error is PlatformException && error.code == 'permission_denied'
            ? AudioInventoryStatus.permissionDenied
            : AudioInventoryStatus.failed,
        scanned: scanned,
        totalIndexed: total < 0 ? scanned : total,
        unreadable: readFailures,
        message: _failureMessage(error),
      );
    }
    if (_disposed && _nativeOperationId == operationId) {
      // The first disposal cancellation can race native generation finishing
      // and retaining a complete report. Clear that newly staged TXT too, and
      // keep the caller's operation lock until this cleanup is acknowledged.
      await _cancelNative(operationId);
    }
    _running = false;
    _cancelRequested = false;
    if (!_disposed) {
      result = outcome;
      scanned = outcome.scanned;
      total = outcome.totalIndexed;
      readFailures = outcome.unreadable;
      phase = switch (outcome.status) {
        AudioInventoryStatus.saved => AudioInventoryPhase.complete,
        AudioInventoryStatus.cancelled => AudioInventoryPhase.cancelled,
        _ => AudioInventoryPhase.failed,
      };
      _notify();
    }
    return outcome;
  }

  void _onProgress(AudioInventoryProgress event) {
    if (_disposed || !_running || event.operationId != _operationId) return;
    scanned = event.scanned;
    total = event.total;
    readFailures = event.readFailures;
    if (!_cancelRequested) {
      // A progress event never establishes that the document was saved. Only
      // the completed method call can move the UI into its success state.
      phase = switch (event.phase) {
        AudioInventoryPhase.complete => AudioInventoryPhase.saving,
        AudioInventoryPhase.cancelled || AudioInventoryPhase.failed => phase,
        _ => event.phase,
      };
    }
    _notify();
  }

  Future<void> cancel() {
    if (_disposed || !_running || _operationId == null) {
      return Future<void>.value();
    }
    if (_cancelling != null) return _cancelling!;
    _cancelRequested = true;
    phase = AudioInventoryPhase.cancelling;
    _notify();
    final nativeId = _nativeOperationId;
    return _cancelling = nativeId == null
        ? Future<void>.value()
        : _cancelNative(nativeId);
  }

  Future<void> _cancelNative(int operationId) async {
    try {
      await _backend.cancelExport(operationId: operationId);
    } catch (_) {
      if (!_disposed && _running && _operationId == operationId) {
        progressWarning = '取消请求暂未确认，请等待系统结束；保存窗口中也可点返回取消。';
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final id = _nativeOperationId;
    // An idle session may still own a complete temporary TXT for retrySave.
    if (id != null) unawaited(_cancelNative(id));
    unawaited(_subscription?.cancel());
    _subscription = null;
    super.dispose();
  }
}

String _failureMessage(Object error) {
  if (error is MissingPluginException) {
    return '当前平台暂不支持音频清单导出，请在更新后的 Android 应用中使用。';
  }
  if (error is PlatformException) {
    return switch (error.code) {
      'permission_denied' => '音频读取权限不可用，请点击授权后重试。未保存清单。',
      'busy' => '系统正在处理另一个清单操作，请稍后重试。',
      'picker_unavailable' => '无法打开系统保存窗口，请确认设备有可用的文件管理器后重试。',
      'save_failed' => '清单未能完整保存，请检查目标位置权限和可用空间后重试。目标位置可能留下不完整的 TXT，请核对后删除。',
      _ => '清单导出未完成，请检查音频读取权限、保存位置和可用空间后重试。',
    };
  }
  return '未能确认清单已完整保存，请重试并核对目标位置中的 TXT 文件。';
}
