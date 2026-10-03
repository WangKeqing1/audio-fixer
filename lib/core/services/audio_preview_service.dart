import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/audio_track.dart';

enum AudioPreviewStatus {
  idle,
  loading,
  playing,
  paused,
  completed,
  error,
  stopped,
}

class AudioPreviewException implements Exception {
  const AudioPreviewException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

@immutable
class AudioPreviewEvent {
  const AudioPreviewEvent({
    required this.requestId,
    required this.trackId,
    required this.status,
    this.positionMs = 0,
    this.durationMs = 0,
    this.errorCode,
  });

  final int requestId;
  final String? trackId;
  final AudioPreviewStatus status;
  final int positionMs;
  final int durationMs;
  final String? errorCode;

  factory AudioPreviewEvent.fromMap(Map<dynamic, dynamic> value) {
    final status = value['status'];
    return AudioPreviewEvent(
      requestId: (value['requestId'] as num?)?.toInt() ?? 0,
      trackId: value['trackId'] as String?,
      status: AudioPreviewStatus.values.firstWhere(
        (item) => item.name == status,
        orElse: () => throw FormatException('未知试听状态：$status'),
      ),
      positionMs: (value['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (value['durationMs'] as num?)?.toInt() ?? 0,
      errorCode: value['errorCode'] as String?,
    );
  }
}

abstract interface class AudioPreviewBackend {
  Stream<AudioPreviewEvent> get events;

  Future<void> play({
    required int requestId,
    required String trackId,
    required String uri,
  });
  Future<void> pause({required int requestId});
  Future<void> seek({required int requestId, required int positionMs});
  Future<void> stop();
  Future<AudioPreviewEvent?> getState();
}

class MethodChannelAudioPreviewBackend implements AudioPreviewBackend {
  MethodChannelAudioPreviewBackend({
    this.channel = const MethodChannel('audio_fixer/audio_preview'),
    this.eventChannel = const EventChannel('audio_fixer/audio_preview_events'),
  });

  final MethodChannel channel;
  final EventChannel eventChannel;
  Stream<AudioPreviewEvent>? _events;

  @override
  Stream<AudioPreviewEvent> get events => _events ??= eventChannel
      .receiveBroadcastStream()
      .map((value) => AudioPreviewEvent.fromMap(value as Map));

  @override
  Future<void> play({
    required int requestId,
    required String trackId,
    required String uri,
  }) => channel.invokeMethod<void>('play', {
    'requestId': requestId,
    'trackId': trackId,
    'uri': uri,
  });

  @override
  Future<void> pause({required int requestId}) =>
      channel.invokeMethod<void>('pause', {'requestId': requestId});

  @override
  Future<void> seek({required int requestId, required int positionMs}) =>
      channel.invokeMethod<void>('seek', {
        'requestId': requestId,
        'positionMs': positionMs,
      });

  @override
  Future<void> stop() => channel.invokeMethod<void>('stop');

  @override
  Future<AudioPreviewEvent?> getState() async {
    final value = await channel.invokeMapMethod<dynamic, dynamic>('getState');
    return value == null ? null : AudioPreviewEvent.fromMap(value);
  }
}

/// The platform has one player per channel, even when the library/controller is
/// recreated. Keep its queue, event listener and release obligation together.
class _AudioPreviewCoordinator {
  _AudioPreviewCoordinator(this.backend);

  static final _injected = Expando<_AudioPreviewCoordinator>();
  static final _platform = <String, _AudioPreviewCoordinator>{};

  static _AudioPreviewCoordinator forBackend(AudioPreviewBackend backend) {
    if (backend is MethodChannelAudioPreviewBackend) {
      return _platform.putIfAbsent(
        backend.channel.name,
        () => _AudioPreviewCoordinator(backend),
      );
    }
    return _injected[backend] ??= _AudioPreviewCoordinator(backend);
  }

  final AudioPreviewBackend backend;
  final controllers = <AudioPreviewController>{};
  StreamSubscription<AudioPreviewEvent>? _subscription;
  Future<void>? _pending;
  AudioPreviewController? currentController;
  AudioPreviewController? nativeOwner;
  int? nativeRequestId;
  int nextRequestId = 0;
  int writeLocks = 0;
  bool backendMayBeActive = false;
  bool get hasPendingWork => _pending != null;

  Future<void> enqueue(Future<void> Function() action) {
    // Create the first Future in the caller's zone, not during construction.
    final previous = _pending;
    final result = previous == null
        ? Future<void>.sync(action)
        : previous.then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending = tail;
    unawaited(
      tail.then((_) {
        if (identical(_pending, tail)) _pending = null;
      }),
    );
    return result;
  }

  void claim(AudioPreviewController controller) {
    if (currentController != controller) {
      final previous = currentController;
      currentController = controller;
      previous?._clearPreview();
    }
  }

  void notifyLockChanged() {
    if (writeLocks > 0) {
      final previous = currentController;
      currentController = null;
      previous?._clearPreview();
    }
    for (final controller in controllers.toList()) {
      controller._notify();
    }
  }

  Future<void> release({
    AudioPreviewController? onlyOwner,
    int? throughRequestId,
  }) async {
    if (!backendMayBeActive ||
        (onlyOwner != null && nativeOwner != onlyOwner) ||
        (throughRequestId != null &&
            nativeRequestId != null &&
            nativeRequestId! > throughRequestId)) {
      return;
    }
    await backend.stop();
    backendMayBeActive = false;
    nativeOwner = null;
    nativeRequestId = null;
  }

  Future<void> ensureListening() async {
    if (_subscription != null) return;
    // Probe method availability first: EventChannel reports a missing plugin
    // during listener setup outside stream.onError.
    await backend.getState();
    if (controllers.isEmpty) return;
    _subscription = backend.events.listen(
      (event) {
        for (final controller in controllers.toList()) {
          controller._onEvent(event);
        }
      },
      onError: (Object error) {
        for (final controller in controllers.toList()) {
          controller._onStreamError(error);
        }
      },
    );
  }

  Future<void> closeIfUnused() async {
    if (controllers.isNotEmpty) return;
    await release();
    // Cancellation is serialized with future subscriptions and playback. A
    // native EventChannel's onCancel can itself stop the global player.
    if (controllers.isNotEmpty) return;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }
}

/// Owns a single local preview, independently of library selection.
///
/// Commands are serialized, while changing track or blocking writes invalidates
/// the UI state immediately. Native events can only affect their own request.
class AudioPreviewController extends ChangeNotifier {
  AudioPreviewController({AudioPreviewBackend? backend})
    : _coordinator = _AudioPreviewCoordinator.forBackend(
        backend ?? MethodChannelAudioPreviewBackend(),
      ) {
    _coordinator.controllers.add(this);
  }

  final _AudioPreviewCoordinator _coordinator;
  AudioPreviewBackend get _backend => _coordinator.backend;
  AudioTrack? _track;
  AudioPreviewStatus _status = AudioPreviewStatus.idle;
  int _positionMs = 0;
  int _durationMs = 0;
  String? _errorMessage;
  int? _requestId;
  int _commandRevision = 0;
  int _seekRevision = 0;
  int _writeLocks = 0;
  bool _acceptPlaybackEvents = false;
  bool _disposed = false;

  AudioTrack? get track => _track;
  int? get sessionId => _requestId;
  AudioPreviewStatus get status => _status;
  int get positionMs => _positionMs;
  int get durationMs => _durationMs;
  String? get errorMessage => _errorMessage;
  bool get isBlocked => _coordinator.writeLocks > 0;
  bool get isPlaying => _status == AudioPreviewStatus.playing;
  bool get isLoading => _status == AudioPreviewStatus.loading;
  bool get canSeek =>
      !_disposed &&
      !isBlocked &&
      _coordinator.nativeOwner == this &&
      _coordinator.nativeRequestId == _requestId &&
      _coordinator.backendMayBeActive &&
      _durationMs > 0 &&
      (_status == AudioPreviewStatus.playing ||
          _status == AudioPreviewStatus.paused ||
          _status == AudioPreviewStatus.completed);

  Future<void> toggle(AudioTrack track) =>
      _track?.id == track.id && (isPlaying || isLoading)
      ? pause()
      : play(track);

  Future<void> play(AudioTrack track) {
    if (_disposed || isBlocked) return Future<void>.value();
    if (_track?.id == track.id && (isPlaying || isLoading)) {
      return Future<void>.value();
    }
    final resume =
        _track?.id == track.id && _status == AudioPreviewStatus.paused;
    _coordinator.claim(this);
    if (_coordinator.currentController != this) return Future<void>.value();
    final requestId = resume ? _requestId! : ++_coordinator.nextRequestId;
    final revision = ++_commandRevision;
    _requestId = requestId;
    _acceptPlaybackEvents = true;
    _track = track;
    _status = AudioPreviewStatus.loading;
    _errorMessage = null;
    if (!resume) {
      _positionMs = 0;
      _durationMs = _nonNegative(track.durationMs ?? 0);
    }
    _notify();

    return _enqueue(() async {
      if (!_isCurrent(requestId, revision)) return;
      try {
        if (!resume) await _stopBackend();
        if (!_isCurrent(requestId, revision)) return;
        final uri = _localUri(track);
        await _coordinator.ensureListening();
        if (!_isCurrent(requestId, revision)) return;
        // A failed platform call can still have created a player. Keep the
        // release obligation until stop explicitly acknowledges success.
        _coordinator.backendMayBeActive = true;
        _coordinator.nativeOwner = this;
        _coordinator.nativeRequestId = requestId;
        await _backend.play(requestId: requestId, trackId: track.id, uri: uri);
      } catch (error) {
        if (_isCurrent(requestId, revision)) _setError(error);
        await _releaseAfterPlaybackFailure();
      }
    });
  }

  Future<void> pause() {
    if (_disposed || isBlocked || (!isPlaying && !isLoading)) {
      return Future<void>.value();
    }
    final requestId = _requestId!;
    final revision = ++_commandRevision;
    _acceptPlaybackEvents = false;
    _status = AudioPreviewStatus.paused;
    _notify();
    return _enqueue(() async {
      if (!_isCurrent(requestId, revision) ||
          !_coordinator.backendMayBeActive) {
        return;
      }
      try {
        if (_coordinator.nativeOwner == this &&
            _coordinator.nativeRequestId == requestId) {
          await _backend.pause(requestId: requestId);
        } else {
          // A newly selected track can be paused before its queued play begins.
          // Its predecessor still needs to stop, although it has a different ID.
          await _stopBackend();
        }
      } catch (error) {
        if (_isCurrent(requestId, revision)) _setError(error);
        await _releaseAfterPlaybackFailure();
      }
    });
  }

  Future<void> seek(int positionMs) {
    if (!canSeek || _requestId == null) return Future<void>.value();
    final requestId = _requestId!;
    final revision = ++_seekRevision;
    final target = positionMs.clamp(0, _durationMs);
    _positionMs = target;
    if (_status == AudioPreviewStatus.completed) {
      _status = AudioPreviewStatus.paused;
    }
    _notify();
    return _enqueue(() async {
      if (!_isCurrent(requestId) || revision != _seekRevision) return;
      try {
        await _backend.seek(requestId: requestId, positionMs: target);
      } catch (error) {
        if (_isCurrent(requestId) && revision == _seekRevision) {
          _setError(error);
        }
        await _releaseAfterPlaybackFailure();
      }
    });
  }

  /// Clears the visible preview immediately; completion means release finished.
  /// UI stop errors are presented through [errorMessage]. Write barriers use the
  /// strict variant below so a failed release can never permit an unsafe write.
  Future<void> stop() => _stop(propagateErrors: false);

  /// Blocks new playback synchronously, then waits for the player to release.
  ///
  /// Locks nest. Always call [releaseWriteLock] in a finally block that includes
  /// this await: a failed acquisition remains blocked until explicitly released.
  Future<void> acquireWriteLock() {
    if (_disposed) {
      return Future<void>.error(
        const AudioPreviewException('试听已关闭，暂未开始保存。请重新打开音乐库后重试。'),
      );
    }
    _writeLocks++;
    _coordinator.writeLocks++;
    _coordinator.notifyLockChanged();
    return _stop(propagateErrors: true);
  }

  void releaseWriteLock() {
    if (_writeLocks == 0) return;
    _writeLocks--;
    _coordinator.writeLocks--;
    _coordinator.notifyLockChanged();
  }

  Future<T> withWriteLock<T>(Future<T> Function() action) async {
    if (_disposed) {
      throw const AudioPreviewException('试听已关闭，暂未开始保存。请重新打开音乐库后重试。');
    }
    try {
      await acquireWriteLock();
      return await action();
    } finally {
      releaseWriteLock();
    }
  }

  Future<void> _stop({required bool propagateErrors}) {
    if (_disposed) return Future<void>.value();
    final wasCurrent = _coordinator.currentController == this;
    final throughRequestId = _coordinator.nextRequestId;
    if (wasCurrent) {
      _coordinator.currentController = null;
    }
    final revision = _clearPreview();
    if (!_coordinator.backendMayBeActive && !_coordinator.hasPendingWork) {
      return Future<void>.value();
    }
    return _enqueue(() async {
      try {
        await _coordinator.release(
          onlyOwner: propagateErrors || wasCurrent ? null : this,
          throughRequestId: propagateErrors ? null : throughRequestId,
        );
      } catch (error) {
        final failure = AudioPreviewException(
          propagateErrors ? '试听未能安全停止，暂未开始保存。请关闭试听后重试。' : '试听未能停止，请重试关闭试听。',
          cause: error,
        );
        if (!_disposed && revision == _commandRevision) _setError(failure);
        if (propagateErrors) throw failure;
      }
    });
  }

  int _clearPreview() {
    final revision = ++_commandRevision;
    _requestId = null;
    _acceptPlaybackEvents = false;
    _track = null;
    _status = AudioPreviewStatus.idle;
    _positionMs = 0;
    _durationMs = 0;
    _errorMessage = null;
    _notify();
    return revision;
  }

  Future<void> _stopBackend() => _coordinator.release();

  Future<void> _releaseAfterPlaybackFailure() async {
    try {
      await _stopBackend();
    } catch (_) {
      // Keep the release obligation so a later write must retry successfully.
    }
  }

  void _onStreamError(Object error) {
    if (_disposed || _requestId == null || isBlocked) return;
    final requestId = _requestId!;
    _setError(error);
    unawaited(
      _enqueue(() async {
        if (_isCurrent(requestId) && _status == AudioPreviewStatus.error) {
          await _releaseAfterPlaybackFailure();
        }
      }),
    );
  }

  void _onEvent(AudioPreviewEvent event) {
    if (_disposed ||
        isBlocked ||
        _coordinator.currentController != this ||
        event.requestId != _requestId ||
        event.trackId != _track?.id) {
      return;
    }
    if (_status == AudioPreviewStatus.error &&
        event.status != AudioPreviewStatus.error) {
      return;
    }
    // A delayed tick from the same player must not undo an explicit pause or
    // revive a completed/failed session before another play request.
    if (!_acceptPlaybackEvents &&
        (event.status == AudioPreviewStatus.playing ||
            event.status == AudioPreviewStatus.loading)) {
      return;
    }
    _status = event.status;
    if (event.status == AudioPreviewStatus.completed ||
        event.status == AudioPreviewStatus.error ||
        event.status == AudioPreviewStatus.stopped) {
      _acceptPlaybackEvents = false;
    }
    if (event.durationMs > 0) _durationMs = event.durationMs;
    _positionMs = _durationMs > 0
        ? event.positionMs.clamp(0, _durationMs)
        : _nonNegative(event.positionMs);
    if (event.status == AudioPreviewStatus.completed && _durationMs > 0) {
      _positionMs = _durationMs;
    }
    _errorMessage = event.status == AudioPreviewStatus.error
        ? _messageForCode(event.errorCode)
        : null;
    _notify();
  }

  bool _isCurrent(int requestId, [int? revision]) =>
      !_disposed &&
      !isBlocked &&
      _coordinator.currentController == this &&
      _requestId == requestId &&
      (revision == null || revision == _commandRevision);

  Future<void> _enqueue(Future<void> Function() action) =>
      _coordinator.enqueue(action);

  void _setError(Object error) {
    _status = AudioPreviewStatus.error;
    _acceptPlaybackEvents = false;
    _errorMessage = error is AudioPreviewException
        ? error.message
        : error is MissingPluginException
        ? '当前设备暂不支持音频试听。'
        : error is PlatformException
        ? _messageForCode(error.code)
        : error is FormatException
        ? '只能试听本机音频，请刷新音乐库后重试。'
        : '无法试听此音频，请重试或选择其他文件。';
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    final wasCurrent = _coordinator.currentController == this;
    _disposed = true;
    _commandRevision++;
    _requestId = null;
    _coordinator.controllers.remove(this);
    if (_coordinator.currentController == this) {
      _coordinator.currentController = null;
    }
    unawaited(
      _enqueue(() async {
        await _coordinator.release(onlyOwner: wasCurrent ? null : this);
        await _coordinator.closeIfUnused();
      }).catchError((Object _) {}),
    );
    super.dispose();
  }
}

int _nonNegative(int value) => value < 0 ? 0 : value;

String _localUri(AudioTrack track) {
  final contentUri = track.contentUri;
  if (contentUri != null && contentUri.trim().isNotEmpty) {
    final uri = Uri.tryParse(contentUri);
    if (uri == null || uri.scheme != 'content' || uri.host.isEmpty) {
      throw const FormatException('无效的本地音频地址');
    }
    return uri.toString();
  }
  final path = track.localPath;
  if (path.startsWith('/') && !path.startsWith('//')) {
    return Uri.file(path).toString();
  }
  final uri = Uri.tryParse(path);
  if (uri != null &&
      uri.scheme == 'file' &&
      uri.host.isEmpty &&
      uri.path.startsWith('/')) {
    return uri.toString();
  }
  throw const FormatException('无效的本地音频地址');
}

String _messageForCode(String? code) => switch (code) {
  'permission_denied' => '没有读取此音频的权限，请重新授权音乐库后重试。',
  'unsupported_format' => '系统暂不支持此音频格式，请尝试其他文件。',
  'source_unavailable' => '音频已移动、删除或无法读取，请刷新音乐库后重试。',
  'invalid_source' || 'invalid_argument' => '只能试听本机音频，请刷新音乐库后重试。',
  'audio_focus_denied' => '暂时无法播放，其他应用正在使用音频，请稍后重试。',
  'preparation_timeout' => '音频加载超时，请重试或选择其他文件。',
  'backgrounded' => '试听已停止，返回音乐库后可重新播放。',
  'disposed' => '试听已结束，请重新打开音乐库后重试。',
  'release_failed' => '试听未能安全停止，请关闭试听后重试。',
  _ => '无法试听此音频，请重试或选择其他文件。',
};
