import 'dart:async';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/audio_preview_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

AudioTrack track(String id, {String? contentUri, String? localPath}) =>
    AudioTrack(
      id: id,
      fileName: '$id.mp3',
      localPath: localPath ?? '/music/$id.mp3',
      contentUri: contentUri,
      title: '标题 $id',
      sizeBytes: 128,
      durationMs: 10000,
      importedAt: DateTime(2026),
    );

class FakePreviewBackend implements AudioPreviewBackend {
  FakePreviewBackend() {
    controller = StreamController<AudioPreviewEvent>.broadcast(
      sync: true,
      onListen: () => listens++,
      onCancel: () => cancellations++,
    );
  }

  late final StreamController<AudioPreviewEvent> controller;
  final commands = <String>[];
  final plays = <({int requestId, String trackId, String uri})>[];
  final seeks = <int>[];
  Completer<void>? playBarrier;
  Completer<void>? pauseBarrier;
  Completer<void>? stopBarrier;
  Object? playError;
  Object? stopError;
  Object? stateError;
  int stateCalls = 0;
  int listens = 0;
  int cancellations = 0;

  @override
  Stream<AudioPreviewEvent> get events => controller.stream;

  @override
  Future<AudioPreviewEvent?> getState() async {
    stateCalls++;
    if (stateError case final error?) throw error;
    return null;
  }

  @override
  Future<void> play({
    required int requestId,
    required String trackId,
    required String uri,
  }) async {
    commands.add('play:$trackId');
    plays.add((requestId: requestId, trackId: trackId, uri: uri));
    if (playBarrier case final barrier?) await barrier.future;
    if (playError case final error?) throw error;
  }

  @override
  Future<void> pause({required int requestId}) async {
    commands.add('pause:$requestId');
    if (pauseBarrier case final barrier?) await barrier.future;
  }

  @override
  Future<void> seek({required int requestId, required int positionMs}) async {
    commands.add('seek:$requestId:$positionMs');
    seeks.add(positionMs);
  }

  @override
  Future<void> stop() async {
    commands.add('stop');
    if (stopBarrier case final barrier?) await barrier.future;
    if (stopError case final error?) throw error;
  }

  void emit(
    AudioPreviewStatus status, {
    int? requestId,
    String? trackId,
    int positionMs = 0,
    int durationMs = 10000,
    String? errorCode,
  }) {
    controller.add(
      AudioPreviewEvent(
        requestId: requestId ?? plays.last.requestId,
        trackId: trackId ?? plays.last.trackId,
        status: status,
        positionMs: positionMs,
        durationMs: durationMs,
        errorCode: errorCode,
      ),
    );
  }
}

Future<void> flushCommands() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePreviewBackend backend;
  late AudioPreviewController preview;

  setUp(() {
    backend = FakePreviewBackend();
    preview = AudioPreviewController(backend: backend);
  });

  tearDown(() async {
    preview.dispose();
    backend.playBarrier?.complete();
    backend.playBarrier = null;
    backend.pauseBarrier?.complete();
    backend.pauseBarrier = null;
    backend.stopBarrier?.complete();
    backend.stopBarrier = null;
    await flushCommands();
    await backend.controller.close();
  });

  test(
    'starts idle and never touches platform until explicitly played',
    () async {
      expect(preview.track, isNull);
      expect(preview.status, AudioPreviewStatus.idle);
      await preview.stop();
      await preview.withWriteLock(() async {});
      expect(backend.commands, isEmpty);
      expect(backend.stateCalls, 0);
    },
  );

  test(
    'uses content URI first and retains track title and known duration',
    () async {
      final song = track(
        'device',
        contentUri: 'content://media/external/audio/12',
      );
      final operation = preview.play(song);
      expect(preview.track, same(song));
      expect(preview.track!.displayTitle, '标题 device');
      expect(preview.isLoading, isTrue);
      expect(preview.durationMs, 10000);
      await operation;
      expect(backend.plays.single.uri, song.contentUri);
      backend.emit(
        AudioPreviewStatus.playing,
        positionMs: 800,
        durationMs: 12000,
      );
      expect(preview.isPlaying, isTrue);
      expect(preview.positionMs, 800);
      expect(preview.durationMs, 12000);
    },
  );

  test(
    'encodes local file paths and accepts only local content or file URIs',
    () async {
      await preview.play(track('local', localPath: '/music/a #1.mp3'));
      expect(backend.plays.single.uri, 'file:///music/a%20%231.mp3');
      await preview.play(track('file', localPath: 'file:///music/file.mp3'));
      expect(backend.plays.last.uri, 'file:///music/file.mp3');
      for (final path in [
        'https://example.org/song.mp3',
        '//server/song.mp3',
        'relative.mp3',
      ]) {
        await preview.play(track('bad', localPath: path));
        expect(preview.status, AudioPreviewStatus.error);
        expect(preview.errorMessage, contains('本机音频'));
      }
      await preview.play(
        track('bad-content', contentUri: 'https://example.org/song.mp3'),
      );
      expect(preview.status, AudioPreviewStatus.error);
      expect(backend.plays, hasLength(2));
      expect(backend.commands.where((item) => item == 'stop'), hasLength(2));
    },
  );

  test(
    'switching releases old player before starting new and drops stale events',
    () async {
      await preview.play(track('a'));
      final old = backend.plays.single;
      backend.emit(AudioPreviewStatus.playing, positionMs: 900);
      await preview.play(track('b'));
      expect(backend.commands, ['play:a', 'stop', 'play:b']);
      backend.emit(AudioPreviewStatus.playing, positionMs: 220);
      backend.emit(
        AudioPreviewStatus.error,
        requestId: old.requestId,
        trackId: old.trackId,
        errorCode: 'permission_denied',
      );
      expect(preview.track!.id, 'b');
      expect(preview.status, AudioPreviewStatus.playing);
      expect(preview.positionMs, 220);
      expect(preview.errorMessage, isNull);
      backend.emit(AudioPreviewStatus.error, trackId: 'a');
      expect(preview.status, AudioPreviewStatus.playing);
    },
  );

  test('rapid switching skips superseded queued play commands', () async {
    backend.playBarrier = Completer<void>();
    final first = preview.play(track('a'));
    await flushCommands();
    final second = preview.play(track('b'));
    final third = preview.play(track('c'));
    backend.playBarrier!.complete();
    backend.playBarrier = null;
    await Future.wait([first, second, third]);
    expect(backend.commands, ['play:a', 'stop', 'play:c']);
    expect(preview.track!.id, 'c');
  });

  test(
    'pause ignores delayed playing ticks and toggle resumes same request',
    () async {
      await preview.play(track('a'));
      final requestId = backend.plays.single.requestId;
      backend.emit(AudioPreviewStatus.playing, positionMs: 1250);
      final pause = preview.pause();
      expect(preview.status, AudioPreviewStatus.paused);
      backend.emit(AudioPreviewStatus.playing, positionMs: 1300);
      expect(preview.status, AudioPreviewStatus.paused);
      expect(preview.positionMs, 1250);
      await pause;
      await preview.toggle(track('a'));
      expect(backend.plays.last.requestId, requestId);
      expect(backend.commands, ['play:a', 'pause:$requestId', 'play:a']);
      backend.emit(AudioPreviewStatus.playing, positionMs: 1250);
      expect(preview.isPlaying, isTrue);
    },
  );

  test('pause before queued preparation prevents any autoplay', () async {
    final play = preview.play(track('a'));
    final pause = preview.pause();
    await Future.wait([play, pause]);
    expect(backend.plays, isEmpty);
    expect(preview.status, AudioPreviewStatus.paused);
    expect(preview.canSeek, isFalse);
    await preview.seek(4000);
    expect(backend.seeks, isEmpty);
    expect(preview.positionMs, 0);
    await preview.toggle(track('a'));
    expect(backend.plays, hasLength(1));
  });

  test('seeking clamps to actual duration and keeps paused status', () async {
    await preview.play(track('a'));
    backend.emit(AudioPreviewStatus.playing, durationMs: 3500);
    await preview.pause();
    await preview.seek(-900);
    await preview.seek(1000000);
    expect(backend.seeks, [0, 3500]);
    expect(preview.positionMs, 3500);
    expect(preview.status, AudioPreviewStatus.paused);
    backend.emit(
      AudioPreviewStatus.paused,
      positionMs: 999999,
      durationMs: 3500,
    );
    expect(preview.positionMs, 3500);
    backend.emit(AudioPreviewStatus.paused, positionMs: -20, durationMs: 3500);
    expect(preview.positionMs, 0);
  });

  test(
    'completed and failed sources can explicitly replay using fresh IDs',
    () async {
      await preview.play(track('a'));
      final firstId = backend.plays.single.requestId;
      backend.emit(AudioPreviewStatus.completed, positionMs: 9900);
      expect(preview.positionMs, 10000);
      backend.emit(AudioPreviewStatus.playing);
      expect(preview.status, AudioPreviewStatus.completed);
      await preview.toggle(track('a'));
      expect(backend.plays.last.requestId, greaterThan(firstId));
      expect(preview.positionMs, 0);
      backend.emit(AudioPreviewStatus.error, errorCode: 'unsupported_format');
      expect(preview.errorMessage, contains('不支持此音频格式'));
      final failedId = backend.plays.last.requestId;
      await preview.toggle(track('a'));
      expect(backend.plays.last.requestId, greaterThan(failedId));
      expect(preview.errorMessage, isNull);
    },
  );

  test('permission and platform errors are visible without throwing', () async {
    backend.playError = PlatformException(code: 'permission_denied');
    await preview.play(track('a'));
    expect(preview.status, AudioPreviewStatus.error);
    expect(preview.errorMessage, contains('权限'));
    expect(backend.commands, ['play:a', 'stop']);
    backend.playError = null;
    await preview.play(track('b'));
    backend.emit(AudioPreviewStatus.error, errorCode: 'source_unavailable');
    expect(preview.errorMessage, contains('移动、删除'));
    await preview.play(track('b'));
    backend.controller.addError(PlatformException(code: 'unsupported_format'));
    expect(preview.status, AudioPreviewStatus.error);
    expect(preview.errorMessage, contains('不支持此音频格式'));
    await flushCommands();
    expect(backend.commands.last, 'stop');
    backend.emit(AudioPreviewStatus.stopped);
    expect(preview.status, AudioPreviewStatus.error);
    expect(preview.errorMessage, contains('不支持此音频格式'));
  });

  test(
    'seeking a completed track resumes from the selected position',
    () async {
      await preview.play(track('a'));
      final requestId = backend.plays.single.requestId;
      backend.emit(AudioPreviewStatus.completed);
      final seeking = preview.seek(4500);
      expect(preview.status, AudioPreviewStatus.paused);
      final replay = preview.toggle(track('a'));
      await Future.wait([seeking, replay]);
      expect(backend.commands, ['play:a', 'seek:$requestId:4500', 'play:a']);
      expect(backend.plays.last.requestId, requestId);
      expect(preview.positionMs, 4500);
    },
  );

  test(
    'write barrier blocks synchronously and waits for release before work',
    () async {
      await preview.play(track('a'));
      final old = backend.plays.single;
      backend.stopBarrier = Completer<void>();
      var wrote = false;
      final operation = preview.withWriteLock(() async {
        wrote = true;
        expect(preview.isBlocked, isTrue);
        return 42;
      });
      expect(preview.isBlocked, isTrue);
      expect(preview.track, isNull);
      await preview.play(track('b'));
      backend.emit(
        AudioPreviewStatus.playing,
        requestId: old.requestId,
        trackId: old.trackId,
      );
      await flushCommands();
      expect(wrote, isFalse);
      expect(preview.track, isNull);
      expect(backend.plays, hasLength(1));
      backend.stopBarrier!.complete();
      backend.stopBarrier = null;
      expect(await operation, 42);
      expect(wrote, isTrue);
      expect(preview.isBlocked, isFalse);
      expect(preview.status, AudioPreviewStatus.idle);
      expect(backend.plays, hasLength(1));
    },
  );

  test(
    'nested write locks stay blocked and preserve action failures',
    () async {
      final failure = StateError('write failed');
      await expectLater(
        preview.withWriteLock(() async {
          expect(preview.isBlocked, isTrue);
          await preview.withWriteLock(() async {
            expect(preview.isBlocked, isTrue);
          });
          expect(preview.isBlocked, isTrue);
          throw failure;
        }),
        throwsA(same(failure)),
      );
      expect(preview.isBlocked, isFalse);
      expect(backend.commands, isEmpty);
    },
  );

  test(
    'failed release aborts write and a retry still requires successful release',
    () async {
      await preview.play(track('a'));
      backend.stopError = PlatformException(code: 'release_failed');
      var wrote = false;
      await expectLater(
        preview.withWriteLock(() async {
          wrote = true;
        }),
        throwsA(
          isA<AudioPreviewException>().having(
            (e) => e.message,
            'message',
            contains('未能安全停止'),
          ),
        ),
      );
      expect(wrote, isFalse);
      expect(preview.isBlocked, isFalse);
      expect(preview.errorMessage, contains('未能安全停止'));
      backend.stopError = null;
      await preview.withWriteLock(() async {
        wrote = true;
      });
      expect(wrote, isTrue);
      expect(backend.commands, ['play:a', 'stop', 'stop']);
    },
  );

  test(
    'losing the plugin after playback cannot bypass a write barrier',
    () async {
      await preview.play(track('a'));
      backend.stopError = MissingPluginException();
      var wrote = false;
      await expectLater(
        preview.withWriteLock(() async {
          wrote = true;
        }),
        throwsA(isA<AudioPreviewException>()),
      );
      expect(wrote, isFalse);
      expect(preview.isBlocked, isFalse);
      backend.stopError = null;
      await preview.withWriteLock(() async {
        wrote = true;
      });
      expect(wrote, isTrue);
    },
  );

  test(
    'a write invalidates queued play and stop clears UI before release',
    () async {
      final pendingPlay = preview.play(track('a'));
      final lock = preview.acquireWriteLock();
      await Future.wait([pendingPlay, lock]);
      expect(backend.plays, isEmpty);
      preview.releaseWriteLock();
      await preview.play(track('b'));
      backend.stopBarrier = Completer<void>();
      final stopping = preview.stop();
      expect(preview.track, isNull);
      expect(preview.positionMs, 0);
      expect(preview.status, AudioPreviewStatus.idle);
      backend.stopBarrier!.complete();
      backend.stopBarrier = null;
      await stopping;
    },
  );

  test(
    'native lifecycle stop stays stopped and allows explicit retry',
    () async {
      await preview.play(track('a'));
      backend.emit(AudioPreviewStatus.playing);
      backend.emit(AudioPreviewStatus.stopped, durationMs: 0);
      expect(preview.status, AudioPreviewStatus.stopped);
      expect(preview.isPlaying, isFalse);
      backend.emit(AudioPreviewStatus.playing);
      expect(preview.status, AudioPreviewStatus.stopped);
      final requestId = backend.plays.last.requestId;
      await preview.toggle(track('a'));
      expect(backend.plays.last.requestId, greaterThan(requestId));
    },
  );

  test(
    'dispose releases player and ignores outstanding events and commands',
    () async {
      await preview.play(track('a'));
      var changes = 0;
      preview.addListener(() => changes++);
      preview.dispose();
      backend.emit(AudioPreviewStatus.playing);
      await preview.play(track('b'));
      await flushCommands();
      expect(backend.commands, ['play:a', 'stop']);
      expect(changes, 0);
    },
  );

  test(
    'missing platform plugin is graceful and unused preview does not call it',
    () async {
      final native = AudioPreviewController();
      await native.withWriteLock(() async {});
      await native.play(track('a'));
      expect(native.status, AudioPreviewStatus.error);
      expect(native.errorMessage, contains('暂不支持音频试听'));
      await native.withWriteLock(() async {});
      native.dispose();
    },
  );

  test(
    'replacement controller write waits for its predecessor to release',
    () async {
      await preview.play(track('a'));
      backend.emit(AudioPreviewStatus.playing);
      backend.pauseBarrier = Completer<void>();
      final pausing = preview.pause();
      await flushCommands();
      preview.dispose();
      final replacement = AudioPreviewController(backend: backend);
      backend.stopBarrier = Completer<void>();
      var wrote = false;
      final writing = replacement.withWriteLock(() async {
        wrote = true;
      });
      expect(replacement.isBlocked, isTrue);
      await flushCommands();
      expect(wrote, isFalse);
      backend.pauseBarrier!.complete();
      backend.pauseBarrier = null;
      await pausing;
      await flushCommands();
      expect(backend.commands.last, 'stop');
      expect(wrote, isFalse);
      backend.stopBarrier!.complete();
      backend.stopBarrier = null;
      await writing;
      expect(wrote, isTrue);
      expect(replacement.isBlocked, isFalse);
      replacement.dispose();
    },
  );

  test(
    'old disposal cannot stop replacement playback or cancel its events',
    () async {
      await preview.play(track('a'));
      final firstId = preview.sessionId!;
      backend.emit(AudioPreviewStatus.playing);
      backend.pauseBarrier = Completer<void>();
      final pausing = preview.pause();
      await flushCommands();
      final replacement = AudioPreviewController(backend: backend);
      final playing = replacement.play(track('b'));
      preview.dispose();
      backend.pauseBarrier!.complete();
      backend.pauseBarrier = null;
      await Future.wait([pausing, playing]);
      await flushCommands();
      expect(backend.commands, ['play:a', 'pause:$firstId', 'stop', 'play:b']);
      expect(replacement.sessionId, greaterThan(firstId));
      expect(backend.listens, 1);
      expect(backend.cancellations, 0);
      backend.emit(AudioPreviewStatus.playing, positionMs: 650);
      expect(replacement.isPlaying, isTrue);
      expect(replacement.positionMs, 650);
      replacement.dispose();
      await flushCommands();
      expect(backend.cancellations, 1);
    },
  );

  test(
    'shared write locks block both owners and disposed owners cannot unlock',
    () async {
      final replacement = AudioPreviewController(backend: backend);
      await preview.acquireWriteLock();
      expect(replacement.isBlocked, isTrue);
      await replacement.play(track('b'));
      expect(backend.plays, isEmpty);
      await replacement.acquireWriteLock();
      preview.releaseWriteLock();
      expect(preview.isBlocked, isTrue);
      preview.dispose();
      await expectLater(
        preview.withWriteLock(() async {}),
        throwsA(isA<AudioPreviewException>()),
      );
      expect(replacement.isBlocked, isTrue);
      replacement.releaseWriteLock();
      expect(replacement.isBlocked, isFalse);
      await replacement.play(track('b'));
      expect(backend.plays.single.trackId, 'b');
      replacement.dispose();
    },
  );

  test(
    'replacement controller retains an earlier failed release obligation',
    () async {
      await preview.play(track('a'));
      backend.stopError = PlatformException(code: 'release_failed');
      preview.dispose();
      final replacement = AudioPreviewController(backend: backend);
      var wrote = false;
      await expectLater(
        replacement.withWriteLock(() async {
          wrote = true;
        }),
        throwsA(isA<AudioPreviewException>()),
      );
      expect(wrote, isFalse);
      backend.stopError = null;
      await replacement.withWriteLock(() async {
        wrote = true;
      });
      expect(wrote, isTrue);
      replacement.dispose();
    },
  );

  test(
    'cancelling a queued replacement also stops its still-playing predecessor',
    () async {
      await preview.play(track('a'));
      backend.emit(AudioPreviewStatus.playing);
      final replacement = AudioPreviewController(backend: backend);
      final replacing = replacement.play(track('b'));
      final stopping = replacement.stop();
      await Future.wait([replacing, stopping]);
      expect(backend.commands, ['play:a', 'stop']);
      expect(preview.track, isNull);
      expect(replacement.track, isNull);
      replacement.dispose();
    },
  );

  test(
    'pausing a queued same-controller replacement stops the old request',
    () async {
      backend.playBarrier = Completer<void>();
      final first = preview.play(track('a'));
      await flushCommands();
      backend.emit(AudioPreviewStatus.playing);
      final second = preview.play(track('b'));
      final pause = preview.pause();
      backend.playBarrier!.complete();
      backend.playBarrier = null;
      await Future.wait([first, second, pause]);
      expect(backend.commands, ['play:a', 'stop']);
      expect(preview.track!.id, 'b');
      expect(preview.status, AudioPreviewStatus.paused);
      await preview.toggle(track('b'));
      expect(backend.commands.last, 'play:b');
    },
  );

  test(
    'a stop listener may start a new session without the old stop killing it',
    () async {
      await preview.play(track('a'));
      Future<void>? replacement;
      var requested = false;
      preview.addListener(() {
        if (!requested && preview.track == null) {
          requested = true;
          replacement = preview.play(track('b'));
        }
      });
      await preview.stop();
      await replacement;
      expect(backend.commands, ['play:a', 'stop', 'play:b']);
      expect(preview.track!.id, 'b');
      backend.emit(AudioPreviewStatus.playing);
      expect(preview.isPlaying, isTrue);
    },
  );

  test(
    'different injected backends keep independent queues and locks',
    () async {
      final independentBackend = FakePreviewBackend();
      final independent = AudioPreviewController(backend: independentBackend);
      await preview.acquireWriteLock();
      expect(independent.isBlocked, isFalse);
      await independent.play(track('independent'));
      expect(independentBackend.plays.single.trackId, 'independent');
      preview.releaseWriteLock();
      independent.dispose();
      await flushCommands();
      await independentBackend.controller.close();
    },
  );

  test(
    'same platform channel shares one listener across backend instances',
    () async {
      const method = MethodChannel('audio_fixer/shared_preview_test');
      const events = EventChannel('audio_fixer/shared_preview_events_test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      var listens = 0;
      var cancellations = 0;
      messenger.setMockMethodCallHandler(method, (call) async {
        calls.add(call);
        return call.method == 'getState'
            ? {'requestId': 0, 'trackId': null, 'status': 'stopped'}
            : null;
      });
      messenger.setMockMethodCallHandler(MethodChannel(events.name), (
        call,
      ) async {
        if (call.method == 'listen') listens++;
        if (call.method == 'cancel') cancellations++;
        return null;
      });
      final first = AudioPreviewController(
        backend: MethodChannelAudioPreviewBackend(
          channel: method,
          eventChannel: events,
        ),
      );
      final second = AudioPreviewController(
        backend: MethodChannelAudioPreviewBackend(
          channel: method,
          eventChannel: events,
        ),
      );
      try {
        await first.play(track('a'));
        final firstId = first.sessionId!;
        first.dispose();
        await second.play(track('b'));
        await flushCommands();
        expect(second.sessionId, greaterThan(firstId));
        expect(listens, 1);
        expect(cancellations, 0);
        expect(calls.where((call) => call.method == 'getState'), hasLength(1));
        expect(calls.map((call) => call.method), [
          'getState',
          'play',
          'stop',
          'play',
        ]);
        second.dispose();
        await flushCommands();
        expect(cancellations, 1);
      } finally {
        first.dispose();
        second.dispose();
        await flushCommands();
        messenger.setMockMethodCallHandler(method, null);
        messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
      }
    },
  );

  test('method channel serializes protocol and parses state', () async {
    const channel = MethodChannel('audio_fixer/audio_preview_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getState') {
        return {
          'requestId': 3,
          'trackId': 'a',
          'status': 'paused',
          'positionMs': 500,
          'durationMs': 900,
        };
      }
      return null;
    });
    final platform = MethodChannelAudioPreviewBackend(channel: channel);
    try {
      await platform.play(
        requestId: 3,
        trackId: 'a',
        uri: 'file:///music/a.mp3',
      );
      await platform.pause(requestId: 3);
      await platform.seek(requestId: 3, positionMs: 500);
      final state = await platform.getState();
      await platform.stop();
      expect(calls.map((item) => item.method), [
        'play',
        'pause',
        'seek',
        'getState',
        'stop',
      ]);
      expect(calls[0].arguments, {
        'requestId': 3,
        'trackId': 'a',
        'uri': 'file:///music/a.mp3',
      });
      expect(calls[2].arguments, {'requestId': 3, 'positionMs': 500});
      expect(state!.status, AudioPreviewStatus.paused);
      expect(state.positionMs, 500);
      expect(state.durationMs, 900);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
