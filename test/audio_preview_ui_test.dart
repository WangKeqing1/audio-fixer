import 'dart:async';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/audio_preview_service.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/device_music_library.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/library/library_page.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _PreviewBackend implements AudioPreviewBackend {
  final _events = StreamController<AudioPreviewEvent>.broadcast(sync: true);
  final plays = <({int requestId, String trackId, String uri})>[];
  final seeks = <int>[];
  int pauses = 0;
  int stops = 0;
  bool autoStart = true;
  bool failStop = false;
  Completer<void>? stopBarrier;
  AudioPreviewEvent? current;

  @override
  Stream<AudioPreviewEvent> get events => _events.stream;

  void emit(
    AudioPreviewStatus status, {
    int? requestId,
    String? trackId,
    int positionMs = 0,
    int durationMs = 120000,
    String? errorCode,
  }) {
    current = AudioPreviewEvent(
      requestId: requestId ?? plays.last.requestId,
      trackId: trackId ?? plays.last.trackId,
      status: status,
      positionMs: positionMs,
      durationMs: durationMs,
      errorCode: errorCode,
    );
    _events.add(current!);
  }

  @override
  Future<void> play({
    required int requestId,
    required String trackId,
    required String uri,
  }) async {
    plays.add((requestId: requestId, trackId: trackId, uri: uri));
    if (autoStart) emit(AudioPreviewStatus.playing);
  }

  @override
  Future<void> pause({required int requestId}) async {
    pauses++;
    emit(AudioPreviewStatus.paused, positionMs: current?.positionMs ?? 0);
  }

  @override
  Future<void> seek({required int requestId, required int positionMs}) async {
    seeks.add(positionMs);
    emit(current!.status, positionMs: positionMs);
  }

  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('release failed');
    if (stopBarrier != null) await stopBarrier!.future;
    current = null;
  }

  @override
  Future<AudioPreviewEvent?> getState() async => current;
}

LibraryController _controller(
  _PreviewBackend backend, {
  List<AudioTrack>? tracks,
  FakeDeviceLibrary? device,
}) => LibraryController(
  store: MemoryStore(
    LibrarySnapshot(
      tracks:
          tracks ??
          [fixtureTrack(id: 'a'), fixtureTrack(id: 'b', title: '第二首')],
    ),
  ),
  picker: FakePicker(),
  importer: FakeImporter(),
  completion: CompletionService(),
  deviceLibrary: device,
  preview: AudioPreviewController(backend: backend),
);

void _phone(
  WidgetTester tester, {
  Size size = const Size(390, 1000),
  double scale = 1,
  double bottomInset = 0,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(bottom: bottomInset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    160,
    scrollable: find
        .descendant(
          of: find.byKey(const PageStorageKey('library-scroll-view')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('checkbox never plays and explicit preview preserves selection', (
    tester,
  ) async {
    _phone(tester);
    final backend = _PreviewBackend();
    final controller = _controller(backend);
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await _tap(tester, _key('toggle-library-selection'));
    await _show(tester, _key('select-track-a'));
    await _tap(tester, _key('select-track-a'));
    expect(controller.selectedTrackIds, {'a'});
    expect(backend.plays, isEmpty);
    await _tap(tester, _key('preview-track-a'));
    expect(backend.plays.single.trackId, 'a');
    expect(controller.selectedTrackIds, {'a'});
    expect(controller.preview.isPlaying, isTrue);
    expect(_key('audio-preview-player'), findsOneWidget);
    await _tap(tester, _key('select-track-a'));
    expect(controller.selectedTrackIds, isEmpty);
    expect(controller.preview.isPlaying, isTrue);
    await _tap(tester, _key('preview-track-a'));
    expect(backend.pauses, 1);
    expect(controller.preview.status, AudioPreviewStatus.paused);
    expect(find.byType(TrackDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid taps keep the newest song and loading can be cancelled', (
    tester,
  ) async {
    _phone(tester, size: const Size(390, 1400));
    final backend = _PreviewBackend()..autoStart = false;
    final controller = _controller(backend);
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(_key('preview-track-a'));
    await tester.pump();
    await tester.tap(_key('preview-track-b'));
    await tester.pump();
    expect(backend.plays, hasLength(2));
    backend.emit(
      AudioPreviewStatus.playing,
      requestId: backend.plays.first.requestId,
      trackId: 'a',
    );
    await tester.pump();
    expect(controller.preview.track?.id, 'b');
    expect(controller.preview.isLoading, isTrue);
    expect(tester.widget<Text>(_key('audio-preview-title')).data, '第二首');
    await tester.tap(_key('audio-preview-toggle'));
    await tester.pumpAndSettle();
    expect(controller.preview.track, isNull);
    backend.emit(AudioPreviewStatus.playing);
    await tester.pumpAndSettle();
    expect(_key('audio-preview-player'), findsNothing);
    expect(controller.selectedTrackIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('progress is local, seek works, errors retry and close clears', (
    tester,
  ) async {
    _phone(tester);
    final backend = _PreviewBackend();
    final controller = _controller(backend);
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await _tap(tester, _key('preview-track-a'));
    final artwork = tester.widget(_key('library-artwork-a'));
    var libraryNotifications = 0;
    controller.addListener(() => libraryNotifications++);
    backend.emit(AudioPreviewStatus.playing, positionMs: 15000);
    await tester.pump();
    expect(
      tester.widget<Text>(_key('audio-preview-position')).data,
      '0:15 / 2:00',
    );
    expect(libraryNotifications, 0);
    expect(
      identical(tester.widget(_key('library-artwork-a')), artwork),
      isTrue,
    );
    final slider = _key('audio-preview-seek');
    await tester.tapAt(tester.getCenter(slider) + const Offset(35, 0));
    await tester.pumpAndSettle();
    expect(backend.seeks, isNotEmpty);
    expect(backend.seeks.last, greaterThan(60000));
    await _tap(tester, _key('audio-preview-toggle'));
    expect(controller.preview.status, AudioPreviewStatus.paused);
    await _tap(tester, _key('audio-preview-toggle'));
    expect(controller.preview.isPlaying, isTrue);
    backend.emit(AudioPreviewStatus.error, errorCode: 'unsupported');
    await tester.pumpAndSettle();
    expect(find.byTooltip('重试试听'), findsOneWidget);
    expect(tester.widget<Slider>(slider).onChanged, isNull);
    final beforeRetry = backend.plays.length;
    await _tap(tester, _key('audio-preview-toggle'));
    expect(backend.plays.length, beforeRetry + 1);
    expect(controller.preview.isPlaying, isTrue);
    backend.emit(AudioPreviewStatus.completed, positionMs: 120000);
    await tester.pumpAndSettle();
    expect(find.byTooltip('重新试听'), findsOneWidget);
    await _tap(tester, _key('audio-preview-toggle'));
    expect(controller.preview.isPlaying, isTrue);
    await _tap(tester, _key('audio-preview-close'));
    expect(_key('audio-preview-player'), findsNothing);
    expect(controller.preview.track, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a seek interrupted by changing tracks does not seek the new song',
    (tester) async {
      _phone(tester);
      final backend = _PreviewBackend();
      final controller = _controller(backend);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(tester, _key('preview-track-a'));
      final slider = tester.widget<Slider>(_key('audio-preview-seek'));
      slider.onChangeStart!(30000);
      slider.onChanged!(45000);
      await controller.preview.play(controller.tracks.last);
      await tester.pumpAndSettle();
      slider.onChangeEnd!(45000);
      await tester.pumpAndSettle();
      expect(controller.preview.track?.id, 'b');
      expect(backend.seeks, isEmpty);
      expect(
        tester.widget<Text>(_key('audio-preview-position')).data,
        '0:00 / 2:00',
      );
    },
  );

  testWidgets(
    'failed stop stays visible and can be retried before navigation',
    (tester) async {
      _phone(tester);
      final backend = _PreviewBackend();
      final controller = _controller(backend);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(tester, _key('preview-track-a'));
      backend.failStop = true;
      await _tap(tester, find.text('测试歌曲').first);
      expect(find.byType(TrackDetailPage), findsNothing);
      expect(controller.preview.track, isNull);
      expect(_key('audio-preview-player'), findsOneWidget);
      expect(find.text('重试关闭试听'), findsOneWidget);
      backend.failStop = false;
      await _tap(tester, _key('audio-preview-close'));
      expect(_key('audio-preview-player'), findsNothing);
      await _tap(tester, find.text('测试歌曲').first);
      expect(find.byType(TrackDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing filters or exclusions stops the hidden song', (
    tester,
  ) async {
    _phone(tester);
    final backend = _PreviewBackend();
    final controller = _controller(
      backend,
      tracks: [
        AudioTrack.fromJson({
          ...fixtureTrack(id: 'a').toJson(),
          'durationMs': 30000,
        }),
        fixtureTrack(id: 'b', title: '第二首'),
      ],
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await _tap(tester, _key('preview-track-a'));
    await _tap(tester, find.text('待检查 0'));
    expect(controller.preview.track, isNull);
    await _tap(tester, find.text('全部 2'));
    await _tap(tester, _key('preview-track-a'));
    await tester.enterText(find.byType(TextField), '第二首');
    await tester.pumpAndSettle();
    expect(controller.preview.track, isNull);
    expect(_key('audio-preview-player'), findsNothing);
    await _tap(tester, find.byTooltip('清除搜索'));
    await _tap(tester, _key('preview-track-a'));
    await controller.updateSettings(const AppSettings(excludeShortAudio: true));
    await tester.pumpAndSettle();
    expect(controller.preview.track, isNull);
    expect(_key('preview-track-a'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail navigation and switching tabs stop the preview', (
    tester,
  ) async {
    _phone(tester);
    final backend = _PreviewBackend();
    final controller = _controller(backend);
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await _tap(tester, _key('preview-track-a'));
    await _tap(tester, find.text('测试歌曲').first);
    expect(find.byType(TrackDetailPage), findsOneWidget);
    expect(controller.preview.track, isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('audio-preview-player'), findsNothing);
    await _tap(tester, _key('preview-track-a'));
    await _tap(tester, find.text('设置'));
    expect(controller.preview.track, isNull);
    await _tap(tester, find.text('音乐库').last);
    expect(_key('audio-preview-player'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission loss hides and stops the player', (tester) async {
    _phone(tester);
    final backend = _PreviewBackend();
    final device = FakeDeviceLibrary()
      ..permission = AudioLibraryPermission.granted
      ..songs = [fixtureDeviceTrack()];
    final controller = _controller(backend, device: device);
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await _tap(tester, _key('preview-track-media:external_primary:1'));
    device.permission = AudioLibraryPermission.blocked;
    await controller.refreshLibrary();
    await tester.pumpAndSettle();
    expect(controller.preview.track, isNull);
    expect(_key('audio-preview-player'), findsNothing);
    expect(find.text('前往设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('write lock disables row playback', (tester) async {
    _phone(tester);
    final backend = _PreviewBackend();
    final controller = _controller(backend);
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await _tap(tester, _key('preview-track-a'));
    await controller.preview.acquireWriteLock();
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(_key('preview-track-a')).onPressed,
      isNull,
    );
    expect(_key('audio-preview-player'), findsNothing);
    controller.preview.releaseWriteLock();
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(_key('preview-track-a')).onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'player and bulk toolbar fit narrow large text with bottom safe area',
    (tester) async {
      _phone(tester, size: const Size(320, 740), scale: 2, bottomInset: 34);
      final backend = _PreviewBackend();
      final controller = _controller(
        backend,
        tracks: [for (var i = 0; i < 40; i++) fixtureTrack(id: '$i')],
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(tester, _key('toggle-library-selection'));
      await _show(tester, _key('preview-track-0'));
      await _tap(tester, _key('select-track-0'));
      await _tap(tester, _key('preview-track-0'));
      expect(tester.takeException(), isNull);
      final pinned = _key('fixed-library-bottom-controls');
      final bounds = tester.getRect(pinned);
      final list = tester.getRect(
        find.byKey(const PageStorageKey('library-scroll-view')),
      );
      expect(list.height, greaterThan(120));
      expect(list.bottom, lessThanOrEqualTo(bounds.top));
      await tester.drag(
        find.byKey(const PageStorageKey('library-scroll-view')),
        const Offset(0, -1000),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(pinned), bounds);
      await _tap(tester, _key('bulk-query-selected'));
      expect(find.text('查询 1 首歌曲？'), findsOneWidget);
      await _tap(tester, find.text('取消'));
      expect(controller.selectedTrackIds, {'0'});
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(320, 460);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _tap(tester, _key('audio-preview-close'));
      expect(_key('audio-preview-player'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposing the library releases playback', (tester) async {
    _phone(tester);
    final backend = _PreviewBackend();
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LibraryPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, _key('preview-track-a'));
    final stops = backend.stops;
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(backend.stops, greaterThan(stops));
    expect(controller.preview.track, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'interrupted seek cannot pin progress or seek a replay of the same song',
    (tester) async {
      _phone(tester);
      final backend = _PreviewBackend();
      final controller = _controller(backend);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(tester, _key('preview-track-a'));
      final oldSlider = tester.widget<Slider>(_key('audio-preview-seek'));
      oldSlider.onChangeStart!(40000);
      oldSlider.onChanged!(70000);
      await tester.pump();
      await controller.preview.stop();
      await tester.pump();
      await controller.preview.play(controller.tracks.first);
      backend.emit(AudioPreviewStatus.playing, positionMs: 6000);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(_key('audio-preview-position')).data,
        '0:06 / 2:00',
      );
      oldSlider.onChangeEnd!(70000);
      await tester.pump();
      expect(backend.seeks, isEmpty);
      backend.emit(AudioPreviewStatus.playing, positionMs: 8000);
      await tester.pump();
      expect(
        tester.widget<Text>(_key('audio-preview-position')).data,
        '0:08 / 2:00',
      );
    },
  );

  testWidgets(
    'changing tabs cancels pending detail navigation even after returning',
    (tester) async {
      _phone(tester);
      final backend = _PreviewBackend();
      final controller = _controller(backend);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(tester, _key('preview-track-a'));
      backend.stopBarrier = Completer<void>();
      await _tap(tester, find.text('测试歌曲').first);
      expect(find.byType(TrackDetailPage), findsNothing);
      await _tap(tester, find.text('设置'));
      await _tap(tester, find.text('音乐库').last);
      backend.stopBarrier!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(TrackDetailPage), findsNothing);
      expect(controller.preview.track, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tab intent synchronously cancels pending navigation and held play controls',
    (tester) async {
      _phone(tester);
      final backend = _PreviewBackend();
      final controller = _controller(backend);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(tester, _key('preview-track-a'));
      final heldPlay = tester
          .widget<IconButton>(_key('preview-track-b'))
          .onPressed!;
      backend.stopBarrier = Completer<void>();
      await _tap(tester, find.text('测试歌曲').first);
      final navigation = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      navigation.onDestinationSelected!(2);
      heldPlay();
      backend.stopBarrier!.complete();
      // Deliberately flush commands before the pending tab rebuild.
      await tester.idle();
      await tester.pumpAndSettle();
      expect(find.byType(TrackDetailPage), findsNothing);
      expect(backend.plays.map((play) => play.trackId), ['a']);
      expect(controller.preview.track, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
