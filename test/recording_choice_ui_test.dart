import 'dart:async';
import 'dart:convert';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/source_query_report.dart';
import 'package:audio_fixer/core/models/recording_candidate.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/library/metadata_editor_page.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:audio_fixer/features/tasks/recording_choice_page.dart';
import 'package:audio_fixer/shared/widgets/instrumental_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _recordings = [
  RecordingCandidate(
    sourceName: '离线录音源',
    sourceId: 'test:one',
    sourceUrl: 'https://example.org/song/one',
    title: '極楽浄土',
    artist: 'GARNiDELiA',
    album: '約束 -Promise code-',
    durationMs: 218826,
    matchDescription: '歌名相同，时长相近；歌手与发行版本尚未确认。',
  ),
  RecordingCandidate(
    sourceName: '离线录音源',
    sourceId: 'test:two',
    sourceUrl: 'https://example.org/song/two',
    title: '極楽浄土',
    artist: 'GARNiDELiA',
    album: 'Violet Cry',
    durationMs: 219066,
    matchDescription: '歌名相同，时长相近；另一张专辑中的版本。',
  ),
];

AudioTrack _track() => AudioTrack(
  id: 'title-only',
  fileName: '極楽浄土.mp3',
  localPath: '/fixture/title-only.mp3',
  sizeBytes: 123,
  importedAt: DateTime(2026),
  durationMs: 218828,
);

class _Source implements RecordingDiscoverySource {
  int discoveries = 0;
  final discoveredTracks = <AudioTrack>[];
  int broadLookups = 0;
  final confirmed = <RecordingCandidate>[];
  Completer<void>? pending;
  bool fail = false;
  bool empty = false;

  @override
  String get name => '离线录音源';

  @override
  Set<AudioField> get supportedFields => {
    AudioField.title,
    AudioField.artist,
    AudioField.album,
    AudioField.lyrics,
  };

  @override
  Future<DiscoveryResult> discover(AudioTrack track) async {
    discoveries++;
    discoveredTracks.add(track);
    return DiscoveryResult(candidates: _recordings);
  }

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async {
    broadLookups++;
    return [];
  }

  @override
  Future<List<FieldSuggestion>> lookupConfirmed(
    AudioTrack track,
    RecordingCandidate recording,
    Set<AudioField> fields,
  ) async {
    confirmed.add(recording);
    await pending?.future;
    if (fail) throw StateError('offline lookup failed');
    if (empty) return [];
    return [
      for (final field in fields)
        FieldSuggestion(
          field: field,
          value: switch (field) {
            AudioField.title => recording.title,
            AudioField.artist => recording.artist,
            AudioField.album => recording.album,
            _ => '所选录音歌词 ${recording.sourceId}',
          },
          source: recording.sourceName,
          sourceUrl: recording.sourceUrl,
          matchDescription: '已按所选歌曲 ID 核对',
        ),
    ];
  }
}

class _NonDiscoverySource implements MetadataSource {
  @override
  String get name => '其他歌词来源';
  @override
  Set<AudioField> get supportedFields => {AudioField.lyrics};
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async => [];
}

LibraryController _controller(
  _Source source, {
  List<CompletionTask> tasks = const [],
}) => LibraryController(
  store: MemoryStore(LibrarySnapshot(tracks: [_track()], tasks: tasks)),
  picker: FakePicker(),
  importer: FakeImporter(),
  completion: CompletionService(sources: [source]),
);

Future<void> _show(
  WidgetTester tester,
  Finder target, {
  double delta = 200,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 100,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Finder _choose(int index) => find.byKey(
  ValueKey(
    'choose-recording-${_recordings[index].sourceName}-${_recordings[index].sourceId}',
  ),
);

Future<void> _openChoice(
  WidgetTester tester,
  LibraryController controller,
) async {
  await tester.pumpWidget(AudioFixerApp(controller: controller));
  await tester.pumpAndSettle();
  await _show(tester, find.text('極楽浄土.mp3'));
  await tester.tap(find.text('極楽浄土.mp3'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('automatic-repair')));
  await tester.pumpAndSettle();
  expect(find.byType(RecordingChoicePage), findsOneWidget);
}

CompletionTask _persistedChoiceTask() => CompletionTask.fromJson(
  jsonDecode(
    jsonEncode(
      CompletionTask(
        trackId: _track().id,
        trackTitle: '極楽浄土',
        createdAt: DateTime(2026),
        status: TaskStatus.needsReview,
        message: '请选择对应的录音版本。',
        isRepair: true,
        queriedFields: {
          AudioField.title,
          AudioField.artist,
          AudioField.album,
          AudioField.lyrics,
        },
        recordingCandidates: _recordings,
      ).toJson(),
    ),
  ) as Map<String, dynamic>,
);

void main() {
  testWidgets(
    'title-only discovery requires explicit version then unchecked fields',
    (tester) async {
      final source = _Source();
      final controller = _controller(source);
      await _openChoice(tester, controller);
      expect(source.discoveries, 1);
      expect(source.broadLookups, 0);
      expect(source.confirmed, isEmpty);
      expect(controller.tasks.single.suggestions, isEmpty);
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(find.byType(CandidateReviewPage), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.textContaining('本地歌手缺失'), findsOneWidget);
      expect(find.textContaining('218.828'), findsOneWidget);
      await _show(tester, _choose(0));
      expect(find.textContaining('短 0.002 秒'), findsOneWidget);
      await _show(tester, _choose(1));
      expect(find.textContaining('长 0.238 秒'), findsOneWidget);
      await tester.tap(_choose(1));
      await tester.pumpAndSettle();
      expect(source.confirmed.single.sameAs(_recordings[1]), isTrue);
      expect(source.broadLookups, 0);
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      expect(find.byType(RecordingChoicePage), findsNothing);
      final task = controller.tasks.single;
      expect(task.confirmedRecording?.sameAs(_recordings[1]), isTrue);
      expect(task.approvedSuggestions, isEmpty);
      expect(
        task.suggestions
            .singleWhere((item) => item.field == AudioField.album)
            .value,
        'Violet Cry',
      );
      expect(
        task.suggestions.every(
          (item) => item.sourceUrl == _recordings[1].sourceUrl,
        ),
        isTrue,
      );
      await _show(tester, find.byType(Checkbox).first);
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((item) => item.value == false),
        isTrue,
      );
      expect(controller.tracks.single.title, isNull);
      expect(controller.tracks.single.artist, isNull);
      expect(controller.tracks.single.album, isNull);
      expect(controller.tracks.single.lyrics, isNull);
      expect(controller.preview.track, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancel performs no detail fetch and detail can reopen version review',
    (tester) async {
      final source = _Source();
      final controller = _controller(source);
      await _openChoice(tester, controller);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(TrackDetailPage), findsOneWidget);
      expect(source.confirmed, isEmpty);
      await _show(
        tester,
        find.byKey(const ValueKey('review-recording-choices')),
      );
      expect(find.byType(InstrumentalControl), findsNothing);
      await tester.tap(find.byKey(const ValueKey('review-recording-choices')));
      await tester.pumpAndSettle();
      expect(find.byType(RecordingChoicePage), findsOneWidget);
      expect(source.discoveries, 1);
      expect(source.confirmed, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'persisted choices reopen from task card without approving or fetching',
    (tester) async {
      final source = _Source();
      final controller = _controller(source, tasks: [_persistedChoiceTask()]);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补全任务'));
      await tester.pumpAndSettle();
      expect(find.byType(InstrumentalControl), findsNothing);
      await _show(
        tester,
        find.byKey(const ValueKey('review-recordings-title-only')),
      );
      await tester.tap(
        find.byKey(const ValueKey('review-recordings-title-only')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RecordingChoicePage), findsOneWidget);
      expect(controller.tasks.single.recordingCandidates.length, 2);
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(source.discoveries, 0);
      expect(source.confirmed, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adjusted title-only query opens choices and rediscovery preserves scope',
    (tester) async {
      final source = _Source();
      final controller = _controller(source);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: MetadataEditorPage(
            track: controller.tracks.single,
            controller: controller,
            queryOnly: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final title = find.byKey(const ValueKey('search-title'));
      await _show(tester, title);
      await tester.enterText(title, '自定义歌名');
      final artist = find.byKey(const ValueKey('search-artist'));
      await _show(tester, artist);
      await tester.enterText(artist, '');
      final album = find.byKey(const ValueKey('search-album'));
      await _show(tester, album);
      await tester.enterText(album, '指定专辑');
      for (final field in [
        AudioField.title,
        AudioField.artist,
        AudioField.lyrics,
      ]) {
        final choice = find.byKey(ValueKey('query-${field.name}'));
        await _show(tester, choice);
        await tester.tap(choice);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('review-metadata-changes')));
      await tester.pumpAndSettle();
      expect(find.byType(RecordingChoicePage), findsOneWidget);
      expect(find.byType(MetadataEditorPage), findsNothing);
      expect(source.discoveries, 1);
      expect(source.confirmed, isEmpty);
      expect(controller.tasks.single.queriedFields, {AudioField.album});
      await _show(tester, find.byKey(const ValueKey('rediscover-recordings')));
      await tester.tap(find.byKey(const ValueKey('rediscover-recordings')));
      await tester.pumpAndSettle();
      expect(find.byType(RecordingChoicePage), findsOneWidget);
      expect(source.discoveries, 2);
      expect(
        source.discoveredTracks.every(
          (track) =>
              track.title == '自定义歌名' &&
              track.artist == '' &&
              track.album == '指定专辑',
        ),
        isTrue,
      );
      expect(controller.tasks.single.queriedFields, {AudioField.album});
      expect(controller.tasks.single.searchMetadata, {
        'title': '自定义歌名',
        'artist': '',
        'album': '指定专辑',
      });
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('busy choice blocks repeated taps and late navigation', (
    tester,
  ) async {
    final source = _Source()..pending = Completer<void>();
    final controller = _controller(source);
    await _openChoice(tester, controller);
    await _show(tester, _choose(0));
    final action = tester.widget<FilledButton>(_choose(0)).onPressed!;
    action();
    action();
    await tester.pump();
    expect(source.confirmed.length, 1);
    expect(tester.widget<FilledButton>(_choose(0)).onPressed, isNull);
    Navigator.of(tester.element(find.byType(RecordingChoicePage))).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('新的页面')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    source.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.text('新的页面'), findsOneWidget);
    expect(find.byType(CandidateReviewPage), findsNothing);
    expect(controller.tasks.single.suggestions, isNotEmpty);
    expect(source.confirmed.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'task retry keeps the confirmed recording after a failed lookup',
    (tester) async {
      final source = _Source();
      final previous = CompletionTask(
        trackId: _track().id,
        trackTitle: '極楽浄土',
        createdAt: DateTime(2026),
        status: TaskStatus.failed,
        message: '所选录音检索失败。',
        isRepair: true,
        queriedFields: {AudioField.album, AudioField.lyrics},
        confirmedRecording: _recordings[1],
      );
      final controller = _controller(source, tasks: [previous]);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补全任务'));
      await tester.pumpAndSettle();
      final retry = find.byKey(const ValueKey('retry-task-title-only'));
      await _show(tester, retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(source.discoveries, 0);
      expect(source.broadLookups, 0);
      expect(source.confirmed.single.sameAs(_recordings[1]), isTrue);
      expect(
        controller.tasks.single.confirmedRecording?.sameAs(_recordings[1]),
        isTrue,
      );
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(
        controller.tasks.single.suggestions
            .singleWhere((item) => item.field == AudioField.album)
            .value,
        'Violet Cry',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'choosing a visible version shows immediate local and fixed feedback $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = _Source()..pending = Completer<void>();
        final controller = _controller(source);
        await _openChoice(tester, controller);
        await _show(tester, _choose(1));
        await tester.tap(_choose(1));
        await tester.pump();
        expect(source.confirmed.length, 1);
        expect(find.text('正在获取这个版本…').hitTestable(), findsOneWidget);
        final status = find.byKey(const ValueKey('recording-fixed-status'));
        expect(status.hitTestable(), findsOneWidget);
        expect(tester.getRect(status).bottom, lessThanOrEqualTo(900));
        expect(tester.widget<Text>(status).data, contains('正在获取'));
        expect(tester.widget<FilledButton>(_choose(1)).onPressed, isNull);
        await tester.tap(_choose(1));
        await tester.pump();
        expect(source.confirmed.length, 1);
        source.pending!.complete();
        await tester.pumpAndSettle();
        expect(find.byType(CandidateReviewPage), findsOneWidget);
        expect(
          controller.tasks.single.confirmedRecording!.sameAs(_recordings[1]),
          isTrue,
        );
        expect(controller.tasks.single.approvedSuggestions, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('leaving pending choice does not navigate when lookup finishes', (
    tester,
  ) async {
    final source = _Source()..pending = Completer<void>();
    final controller = _controller(source);
    await _openChoice(tester, controller);
    await _show(tester, _choose(0));
    await tester.tap(_choose(0));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(milliseconds: 400));
    source.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TrackDetailPage), findsOneWidget);
    expect(find.byType(CandidateReviewPage), findsNothing);
    expect(find.byType(RecordingChoicePage), findsNothing);
    expect(source.confirmed.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stale version callback cannot start a lookup', (tester) async {
    final source = _Source();
    final controller = _controller(source);
    await _openChoice(tester, controller);
    await _show(tester, _choose(0));
    final action = tester.widget<FilledButton>(_choose(0)).onPressed!;
    await controller.queryAutomaticRepair(track: controller.tracks.single);
    await tester.pumpAndSettle();
    action();
    await tester.pumpAndSettle();
    expect(source.discoveries, 2);
    expect(source.confirmed, isEmpty);
    await _show(tester, _choose(0));
    expect(tester.widget<FilledButton>(_choose(0)).onPressed, isNull);
    final fixedStatus = find.byKey(const ValueKey('recording-fixed-status'));
    expect(fixedStatus.hitTestable(), findsOneWidget);
    expect(tester.widget<Text>(fixedStatus).data, contains('版本列表已更新'));
    expect(
      find.byKey(const ValueKey('recording-fixed-rediscover')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final failed in [false, true]) {
    testWidgets(
      '${failed ? 'failed' : 'empty'} choice displays actual result and can rediscover another version',
      (tester) async {
        final source = _Source()
          ..empty = !failed
          ..fail = failed;
        final controller = _controller(source);
        await _openChoice(tester, controller);
        await _show(tester, _choose(0));
        await tester.tap(_choose(0));
        await tester.pumpAndSettle();
        expect(find.byType(RecordingChoicePage), findsOneWidget);
        expect(find.byType(CandidateReviewPage), findsNothing);
        expect(
          controller.tasks.single.status,
          failed ? TaskStatus.failed : TaskStatus.noMatch,
        );
        // The outcome stays visible at the clicked row; the detailed source
        // report is allowed to remain above the lazy viewport.
        final status = find.byKey(const ValueKey('recording-fixed-status'));
        expect(status.hitTestable(), findsOneWidget);
        expect(
          tester.widget<Text>(status).data,
          controller.tasks.single.message,
        );
        expect(controller.tasks.single.approvedSuggestions, isEmpty);
        final rediscover = find.byKey(
          const ValueKey('recording-fixed-rediscover'),
        );
        expect(rediscover.hitTestable(), findsOneWidget);
        source
          ..empty = false
          ..fail = false;
        await tester.tap(rediscover);
        await tester.pumpAndSettle();
        expect(source.discoveries, 2);
        await _show(tester, _choose(1));
        await tester.tap(_choose(1));
        await tester.pumpAndSettle();
        expect(source.confirmed.map((item) => item.sourceId), [
          'test:one',
          'test:two',
        ]);
        expect(find.byType(CandidateReviewPage), findsOneWidget);
        expect(
          controller.tasks.single.suggestions
              .singleWhere((item) => item.field == AudioField.album)
              .value,
          'Violet Cry',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'failed chosen recording retries its same ID and guards repeated taps',
    (tester) async {
      final source = _Source()..fail = true;
      final controller = _controller(source);
      await _openChoice(tester, controller);
      await _show(tester, _choose(1));
      await tester.tap(_choose(1));
      await tester.pumpAndSettle();
      final retry = find.byKey(const ValueKey('retry-selected-recording'));
      await _show(tester, retry, delta: -200);
      source
        ..fail = false
        ..pending = Completer<void>();
      final action = tester.widget<TextButton>(retry).onPressed!;
      action();
      action();
      await tester.pump();
      expect(source.confirmed.map((recording) => recording.sourceId), [
        'test:two',
        'test:two',
      ]);
      expect(source.discoveries, 1);
      expect(tester.widget<TextButton>(retry).onPressed, isNull);
      Navigator.of(tester.element(find.byType(RecordingChoicePage))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('新的页面')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      source.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('新的页面'), findsOneWidget);
      expect(find.byType(CandidateReviewPage), findsNothing);
      expect(controller.tasks.single.confirmedRecording?.sourceId, 'test:two');
      expect(controller.tasks.single.suggestions, isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail automatic retry preserves the confirmed recording ID', (
    tester,
  ) async {
    final source = _Source()..fail = true;
    final controller = _controller(source);
    await _openChoice(tester, controller);
    await _show(tester, _choose(1));
    await tester.tap(_choose(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    source.fail = false;
    await tester.tap(find.byKey(const ValueKey('automatic-repair')));
    await tester.pumpAndSettle();
    expect(source.confirmed.map((recording) => recording.sourceId), [
      'test:two',
      'test:two',
    ]);
    expect(source.discoveries, 1);
    expect(find.byType(CandidateReviewPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'choice persistence error remains visible with prior discovery reports',
    (tester) async {
      final source = _Source();
      final controller = _controller(source);
      await _openChoice(tester, controller);
      final previous = controller.tasks.single;
      (controller.store as MemoryStore).failSave = true;
      await _show(tester, _choose(0));
      await tester.tap(_choose(0));
      await tester.pumpAndSettle();
      expect(controller.tasks.single.createdAt, previous.createdAt);
      await _show(
        tester,
        find.byKey(const ValueKey('recording-choice-result')),
        delta: -200,
      );
      expect(find.textContaining('操作未完成'), findsWidgets);
      expect(find.byType(CandidateReviewPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'title-only automatic query waits for its discovery provider only',
    (tester) async {
      final source = _Source();
      final previous = CompletionTask(
        trackId: _track().id,
        trackTitle: '極楽浄土',
        createdAt: DateTime(2026),
        status: TaskStatus.failed,
        message: '版本查询未完成',
        isRepair: true,
        queriedFields: source.supportedFields,
        sourceReports: [
          SourceQueryReport(
            sourceName: source.name,
            outcome: SourceQueryOutcome.failed,
            message: '连接超时',
            failureKind: SourceFailureKind.timeout,
            retryAt: DateTime.now().add(const Duration(seconds: 52)),
          ),
        ],
      );
      final controller = LibraryController(
        store: MemoryStore(
          LibrarySnapshot(tracks: [_track()], tasks: [previous]),
        ),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: [source, _NonDiscoverySource()]),
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _show(tester, find.text('極楽浄土.mp3'));
      await tester.tap(find.text('極楽浄土.mp3'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('automatic-repair')),
            )
            .onPressed,
        isNull,
      );
      expect(source.discoveries, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 480),
    const Size(390, 844),
    const Size(900, 900),
  ]) {
    testWidgets(
      'recording choices fit $size with double text and reach all actions',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final source = _Source();
        final controller = _controller(source, tasks: [_persistedChoiceTask()]);
        await controller.initialize();
        await tester.pumpWidget(
          MaterialApp(
            home: RecordingChoicePage(
              task: controller.tasks.single,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _show(tester, _choose(0));
        expect(tester.getRect(_choose(0)).right, lessThanOrEqualTo(size.width));
        await _show(tester, _choose(1));
        expect(tester.getRect(_choose(1)).right, lessThanOrEqualTo(size.width));
        await _show(tester, find.text('其他修复方式'));
        await tester.tap(find.text('其他修复方式'));
        await tester.pumpAndSettle();
        await _show(
          tester,
          find.byKey(const ValueKey('recording-manual-edit')),
        );
        expect(source.confirmed, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
