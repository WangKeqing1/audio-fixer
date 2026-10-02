import 'dart:async';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _candidate = FieldSuggestion(
  field: AudioField.album,
  value: '示例专辑',
  source: '离线测试来源',
);

CompletionTask _task({
  DateTime? createdAt,
  TaskStatus status = TaskStatus.needsReview,
  List<FieldSuggestion> suggestions = const [_candidate],
  String? uri,
}) => CompletionTask(
  trackId: 'fixture',
  trackTitle: '示例歌曲',
  createdAt: createdAt ?? DateTime(2026),
  status: status,
  message: '离线测试候选，不来自真实歌曲。',
  suggestions: suggestions,
  exportedCopyUri: uri,
);

class _Exporter implements AudioCopyExporter {
  int calls = 0;
  String? result;
  String? error;
  Completer<String?>? pending;
  List<FieldSuggestion> selected = [];

  @override
  bool supports(AudioTrack track) =>
      {'MP3', 'FLAC', 'M4A', 'MP4'}.contains(track.extension);

  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    calls++;
    this.selected = selected;
    if (error != null) throw ExportException(error!);
    return pending != null ? pending!.future : result;
  }
}

class _Source implements MetadataSource {
  int calls = 0;
  Completer<List<FieldSuggestion>>? pending;
  @override
  String get name => '离线测试来源';
  @override
  Set<AudioField> get supportedFields => {AudioField.album};
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    calls++;
    return pending != null ? pending!.future : const [_candidate];
  }
}

LibraryController _controller({
  MemoryStore? store,
  CompletionTask? task,
  AudioTrack? track,
  _Exporter? exporter,
  CompletionService? completion,
}) => LibraryController(
  store:
      store ??
      MemoryStore(
        LibrarySnapshot(
          tracks: [track ?? fixtureTrack()],
          tasks: [task ?? _task()],
        ),
      ),
  picker: FakePicker(),
  importer: FakeImporter(),
  completion: completion ?? CompletionService(sources: [_Source()]),
  exporter: exporter ?? _Exporter(),
);

Future<void> _openTasks(
  WidgetTester tester,
  LibraryController controller, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(AudioFixerApp(controller: controller));
  await tester.pumpAndSettle();
  await tester.tap(find.text('补全任务'));
  await tester.pumpAndSettle();
}

Future<void> _openReview(
  WidgetTester tester, {
  String label = '确认 1 项候选',
  bool selectCandidates = true,
}) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).hitTestable());
  await tester.pumpAndSettle();
  if (selectCandidates) await _selectCandidate(tester);
}

Future<void> _selectCandidate(WidgetTester tester) async {
  if (tester
      .widget<CandidateReviewPage>(find.byType(CandidateReviewPage))
      .task
      .suggestions
      .isEmpty) {
    return;
  }
  if (find.byType(Checkbox).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      find.byType(Checkbox),
      220,
      scrollable: find
          .descendant(
            of: find.byType(CandidateReviewPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }
  final checkbox = find.byType(Checkbox).first;
  final value = tester.widget<Checkbox>(checkbox);
  if (value.onChanged == null || value.value == true) return;
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox.hitTestable());
  await tester.pumpAndSettle();
}

OutlinedButton _saveButton(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.byKey(const ValueKey('export-copy')));

void main() {
  testWidgets(
    'all-unselected review explains disabled save and restores selection',
    (tester) async {
      final exporter = _Exporter();
      await _openTasks(tester, _controller(exporter: exporter));
      await _openReview(tester, selectCandidates: false);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(find.text('请至少选择一项要写入的资料'), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
      expect(exporter.calls, 0);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(_saveButton(tester).onPressed, isNotNull);
      expect(find.text('请至少选择一项要写入的资料'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancel and export failure remain visible after notice expires and retry succeeds',
    (tester) async {
      final exporter = _Exporter();
      final controller = _controller(exporter: exporter);
      await _openTasks(tester, controller);
      await _openReview(tester);
      await tester.tap(find.text('导出副本（1 项）'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('已取消保存，原音频未修改。'), findsOneWidget);
      expect(controller.tasks.single.status, TaskStatus.needsReview);
      exporter.error = '示例校验失败。请检查保存位置后重试。';
      await tester.tap(find.text('导出副本（1 项）'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text(exporter.error!), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNotNull);
      exporter.error = null;
      exporter.result = 'content://offline/copy';
      await tester.tap(find.text('导出副本（1 项）'));
      await tester.pumpAndSettle();
      expect(exporter.calls, 3);
      expect(find.byType(CandidateReviewPage), findsNothing);
      expect(controller.tasks.single.status, TaskStatus.exported);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning to an exported result identifies another copy and saved location',
    (tester) async {
      final controller = _controller(
        task: _task(
          status: TaskStatus.exported,
          uri: 'content://offline/saved-copy',
        ),
      );
      await _openTasks(tester, controller);
      await tester.tap(find.text('查看副本保存位置'));
      await tester.pumpAndSettle();
      expect(find.text('content://offline/saved-copy'), findsOneWidget);
      await _openReview(tester, label: '查看候选资料');
      expect(find.text('已导出过副本'), findsOneWidget);
      expect(find.text('再次导出副本（1 项）'), findsOneWidget);
      expect(find.text('content://offline/saved-copy'), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stale review disables writing and opens the latest candidate', (
    tester,
  ) async {
    final store = MemoryStore(
      LibrarySnapshot(tracks: [fixtureTrack()], tasks: [_task()]),
    );
    final exporter = _Exporter();
    final controller = _controller(store: store, exporter: exporter);
    await _openTasks(tester, controller);
    await _openReview(tester);
    store.snapshot = LibrarySnapshot(
      tracks: [fixtureTrack()],
      tasks: [
        _task(
          createdAt: DateTime(2026, 2),
          suggestions: const [
            FieldSuggestion(
              field: AudioField.album,
              value: '更新后的示例专辑',
              source: '离线测试来源',
            ),
          ],
        ),
      ],
    );
    await controller.initialize();
    await tester.pumpAndSettle();
    expect(find.textContaining('歌曲或候选已更新'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
    await tester.tap(find.text('查看最新结果'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('更新后的示例专辑'));
    expect(find.text('更新后的示例专辑'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
    await _selectCandidate(tester);
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(exporter.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'outdated result stays view-only and can query again without leaving review',
    (tester) async {
      final source = _Source();
      final controller = _controller(
        task: _task(status: TaskStatus.outdated),
        completion: CompletionService(sources: [source]),
      );
      await _openTasks(tester, controller);
      await _openReview(tester, label: '查看历史候选');
      expect(find.textContaining('原歌曲已发生变化'), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
      await tester.tap(find.text('重新查询'));
      await tester.pumpAndSettle();
      expect(source.calls, 1);
      expect(controller.tasks.single.status, TaskStatus.needsReview);
      expect(find.textContaining('原歌曲已发生变化'), findsNothing);
      expect(_saveButton(tester).onPressed, isNull);
      await _selectCandidate(tester);
      expect(_saveButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removed source preserves readable history but cannot export or retry',
    (tester) async {
      final controller = _controller(
        store: MemoryStore(LibrarySnapshot(tasks: [_task()])),
      );
      await _openTasks(tester, controller);
      expect(find.textContaining('原歌曲当前不可访问'), findsOneWidget);
      expect(find.text('重新查询'), findsNothing);
      expect(find.text('1 首歌曲待确认'), findsNothing);
      await _openReview(tester, label: '查看历史候选');
      expect(find.textContaining('此歌曲当前不可访问'), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('查看历史候选'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unsupported format permits review but disables writing', (
    tester,
  ) async {
    final track = AudioTrack(
      id: 'fixture',
      fileName: 'example.ogg',
      sizeBytes: 1024,
      importedAt: DateTime(2026),
      title: '示例歌曲',
    );
    final exporter = _Exporter();
    await _openTasks(tester, _controller(track: track, exporter: exporter));
    expect(find.textContaining('OGG 可预览并确认'), findsOneWidget);
    await _openReview(tester);
    expect(find.textContaining('OGG 格式当前仅支持预览和确认'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
    expect(exporter.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'existing fields are deselected and protected instead of failing at export',
    (tester) async {
      final track = fixtureTrack().withDetails(
        title: '示例歌曲',
        artist: '示例歌手',
        album: '已有专辑',
        year: null,
        durationMs: null,
        lyrics: null,
        artworkPath: null,
      );
      await _openTasks(tester, _controller(track: track));
      await _openReview(tester);
      expect(find.textContaining('此项已有资料，不会覆盖'), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
      expect(_saveButton(tester).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'save cannot start twice and back waits until the save dialog returns',
    (tester) async {
      final exporter = _Exporter()..pending = Completer<String?>();
      final controller = _controller(exporter: exporter);
      await _openTasks(tester, controller);
      await _openReview(tester);
      await tester.tap(find.text('导出副本（1 项）'));
      await tester.pump();
      expect(exporter.calls, 1);
      expect(_saveButton(tester).onPressed, isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      expect(find.text('保存期间请留在此页，可在系统保存弹窗中取消。'), findsOneWidget);
      exporter.pending!.complete(null);
      await tester.pumpAndSettle();
      expect(_saveButton(tester).onPressed, isNotNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(CandidateReviewPage), findsNothing);
      expect(controller.tasks.single.status, TaskStatus.needsReview);
      expect(find.text('确认 1 项候选'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('export completion never pops a newer route', (tester) async {
    final exporter = _Exporter()..pending = Completer<String?>();
    await _openTasks(tester, _controller(exporter: exporter));
    await _openReview(tester);
    await tester.tap(find.text('导出副本（1 项）'));
    await tester.pump();
    Navigator.of(tester.element(find.byType(CandidateReviewPage))).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('稍后打开的新页面')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    exporter.pending!.complete('content://offline/newer-route');
    await tester.pumpAndSettle();
    expect(find.text('稍后打开的新页面'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('已导出过副本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unrelated query does not block leaving a review', (
    tester,
  ) async {
    final source = _Source()..pending = Completer<List<FieldSuggestion>>();
    final controller = _controller(
      completion: CompletionService(sources: [source]),
    );
    await _openTasks(tester, controller);
    await _openReview(tester);
    final query = controller.complete(track: controller.tracks.single);
    await tester.pump();
    expect(controller.isBusy, isTrue);
    final reviewRoute = ModalRoute.of(
      tester.element(find.byType(CandidateReviewPage)),
    )!;
    await tester.tap(find.byType(BackButton));
    // First process maybePop and start its reverse animation. Advancing time
    // in that same first frame only starts the transition at the later time.
    await tester.pump();
    expect(reviewRoute.isCurrent, isFalse);
    // Cross the transition's end timestamp by a frame so the animation emits
    // dismissed and the navigator removes the route. An exact end timestamp
    // can still report reverse with value 0 on this SDK.
    await tester.pump(
      reviewRoute.reverseTransitionDuration + const Duration(milliseconds: 16),
    );
    await tester.pump();
    expect(find.byType(CandidateReviewPage), findsNothing);
    expect(controller.isBusy, isTrue);
    expect(source.pending!.isCompleted, isFalse);
    source.pending!.complete(const [_candidate]);
    await query;
    await tester.pumpAndSettle();
    expect(controller.tasks.single.status, TaskStatus.needsReview);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all-disabled settings offer recovery and disable misleading retry',
    (tester) async {
      final controller = _controller(
        store: MemoryStore(
          LibrarySnapshot(
            tracks: [fixtureTrack()],
            tasks: [_task()],
            settings: const AppSettings(
              metadata: false,
              lyrics: false,
              artwork: false,
            ),
          ),
        ),
      );
      await _openTasks(tester, controller);
      expect(find.text('尚未选择补全内容'), findsOneWidget);
      final retry = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '重新查询'),
      );
      expect(retry.onPressed, isNull);
      await tester.tap(find.text('选择补全内容'));
      await tester.pumpAndSettle();
      expect(find.text('补全内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large text retains the complete failure and a reachable retry', (
    tester,
  ) async {
    final exporter = _Exporter()
      ..error = '保存失败。文档提供程序不支持清理，请手动删除保存位置中可能残留的不完整副本，再检查空间后重试。';
    await _openTasks(tester, _controller(exporter: exporter), scale: 2);
    tester.view.physicalSize = const Size(320, 740);
    await tester.pumpAndSettle();
    await _openReview(tester);
    await tester.tap(find.text('导出副本（1 项）'));
    await tester.pumpAndSettle();
    expect(find.text('处理结果'), findsOneWidget);
    expect(find.text(exporter.error!), findsWidgets);
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(find.text('导出副本（1 项）').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty review has explicit recovery text and cannot write', (
    tester,
  ) async {
    final task = _task(suggestions: []);
    final controller = _controller(task: task);
    await _openTasks(tester, controller);
    Navigator.of(tester.element(find.byType(Scaffold).first)).push(
      MaterialPageRoute<void>(
        builder: (_) => CandidateReviewPage(task: task, controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('没有可确认的候选'));
    expect(find.text('没有可确认的候选'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
