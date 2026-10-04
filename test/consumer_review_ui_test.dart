import 'dart:async';

import 'package:audio_fixer/app/app_shell.dart';
import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:audio_fixer/features/tasks/recommended_batch_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _album = FieldSuggestion(
  field: AudioField.album,
  value: '树影与风',
  source: '已核对的离线来源',
  provenance: SuggestionProvenance.verifiedRecording,
);
const _lyrics = FieldSuggestion(
  field: AudioField.lyrics,
  value: '[00:00.00] 沿着树荫慢慢走\n[00:05.00] 把风留在身后',
  source: '已核对的离线来源',
  provenance: SuggestionProvenance.verifiedRecording,
);
const _overwrite = FieldSuggestion(
  field: AudioField.title,
  value: '午后散步（现场版）',
  source: '已核对的离线来源',
  replaceExisting: true,
  provenance: SuggestionProvenance.verifiedRecording,
);
const _conflictA = FieldSuggestion(
  field: AudioField.year,
  value: '2025',
  source: '离线来源 A',
  provenance: SuggestionProvenance.verifiedRecording,
);
const _conflictB = FieldSuggestion(
  field: AudioField.year,
  value: '2026',
  source: '离线来源 B',
  provenance: SuggestionProvenance.verifiedRecording,
);
const _unverified = FieldSuggestion(
  field: AudioField.genre,
  value: '民谣',
  source: '未经版本核对的离线来源',
);
const _choices = [
  _album,
  _lyrics,
  _overwrite,
  _conflictA,
  _conflictB,
  _unverified,
];

class _Writer implements AudioCopyExporter, AudioOriginalSaver {
  final writes = <(String, List<FieldSuggestion>)>[];
  int copies = 0;
  Completer<String?>? pending;
  Object? failure;

  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    copies++;
    return null;
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    writes.add((track.id, List.unmodifiable(selected)));
    if (failure case final error?) throw error;
    return pending?.future;
  }
}

CompletionTask _task(String id, {DateTime? createdAt}) => CompletionTask(
  trackId: id,
  trackTitle: id == 'one' ? '午后散步' : '城市夜晚',
  createdAt: createdAt ?? DateTime(2026, 10, 4),
  status: TaskStatus.needsReview,
  message: '离线界面测试资料；没有连接在线来源。',
  suggestions: _choices,
  isRepair: true,
);

LibraryController _controller(_Writer writer, {int tracks = 1}) =>
    LibraryController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [
            fixtureTrack(id: 'one', title: '午后散步'),
            if (tracks > 1) fixtureTrack(id: 'two', title: '城市夜晚'),
          ],
          tasks: [_task('one'), if (tracks > 1) _task('two')],
        ),
      ),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
      exporter: writer,
    );

Finder _candidate(FieldSuggestion value) => find.byKey(
  ValueKey(
    'candidate-${value.field.name}-${value.source}-${value.value.hashCode}',
  ),
);

bool _selected(WidgetTester tester, FieldSuggestion value) =>
    tester.widget<CheckboxListTile>(_candidate(value)).value == true;

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target.hitTestable());
  await tester.pumpAndSettle();
}

void _size(WidgetTester tester, [Size size = const Size(390, 844)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _show(
  WidgetTester tester,
  LibraryController controller, {
  bool batch = false,
  double textScale = 1,
  bool reduceMotion = false,
}) async {
  await controller.initialize();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => batch
                      ? RecommendedBatchReviewPage(
                          controller: controller,
                          trackIds: {'one', 'two'},
                        )
                      : CandidateReviewPage(
                          task: controller.taskForTrack('one')!,
                          controller: controller,
                        ),
                ),
              ),
              child: const Text('打开预览'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, find.text('打开预览'));
}

void main() {
  testWidgets('safe missing values are preselected and held changes stay off', (
    tester,
  ) async {
    _size(tester);
    final writer = _Writer();
    final controller = _controller(writer);
    await _show(tester, controller);
    expect(_selected(tester, _album), isTrue);
    expect(_selected(tester, _lyrics), isTrue);
    expect(find.text('将补全 2 项'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(
      find.byKey(const ValueKey('save-original')).hitTestable(),
      findsOneWidget,
    );
    await _tap(tester, find.byKey(const PageStorageKey('review-held-changes')));
    for (final held in [_overwrite, _conflictA, _conflictB, _unverified]) {
      expect(_selected(tester, held), isFalse);
    }
    expect(writer.writes, isEmpty);
    expect(
      controller.approvedSuggestionsFor(controller.taskForTrack('one')!),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('one apply writes only choices and repeated taps stay disabled', (
    tester,
  ) async {
    _size(tester);
    final writer = _Writer()..pending = Completer<String?>();
    final controller = _controller(writer);
    await _show(tester, controller);
    await _tap(tester, _candidate(_lyrics));
    await _tap(tester, find.byKey(const PageStorageKey('review-held-changes')));
    await _tap(tester, _candidate(_conflictA));
    await _tap(tester, _candidate(_conflictB));
    expect(_selected(tester, _conflictA), isFalse);
    expect(_selected(tester, _conflictB), isTrue);
    final apply = find.byKey(const ValueKey('save-original'));
    await tester.tap(apply);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(writer.writes, hasLength(1));
    expect(writer.writes.single.$2.map((item) => item.field), [
      AudioField.album,
      AudioField.year,
    ]);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    await tester.tap(apply);
    await tester.pump();
    expect(writer.writes, hasLength(1));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(CandidateReviewPage), findsOneWidget);
    expect(writer.copies, 0);
    expect(writer.writes.single.$2.last.value, '2026');
    writer.pending!.complete(null);
    await tester.pumpAndSettle();
    expect(_selected(tester, _album), isTrue);
    expect(_selected(tester, _lyrics), isFalse);
    expect(_selected(tester, _conflictA), isFalse);
    expect(_selected(tester, _conflictB), isTrue);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    expect(find.textContaining('已取消保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save preserves choices and offers the same retry', (
    tester,
  ) async {
    _size(tester);
    final writer = _Writer()..failure = const ExportException('测试磁盘空间不足');
    final controller = _controller(writer);
    await _show(tester, controller);
    await _tap(tester, _candidate(_lyrics));
    await _tap(tester, find.byKey(const ValueKey('save-original')));
    expect(find.text('测试磁盘空间不足'), findsOneWidget);
    expect(_selected(tester, _album), isTrue);
    expect(_selected(tester, _lyrics), isFalse);
    expect(writer.writes.single.$2.map((item) => item.field), [
      AudioField.album,
    ]);
    await _tap(tester, find.byKey(const ValueKey('save-original')));
    expect(writer.writes, hasLength(2));
    expect(writer.writes.last.$2.map((item) => item.field), [AudioField.album]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scroll and phone tablet desktop resize retain choices and apply',
    (tester) async {
      _size(tester);
      final controller = _controller(_Writer());
      await _show(tester, controller);
      await _tap(tester, _candidate(_lyrics));
      for (final size in [
        const Size(390, 844),
        const Size(900, 900),
        const Size(1440, 960),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(_selected(tester, _album), isTrue);
        expect(_selected(tester, _lyrics), isFalse);
        final apply = find.byKey(const ValueKey('save-original'));
        final pinned = tester.getRect(apply);
        await tester.drag(find.byType(ListView), const Offset(0, -1400));
        await tester.pumpAndSettle();
        expect(tester.getRect(apply), pinned);
        expect(apply.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$size');
      }
    },
  );

  testWidgets(
    'embedded review retains edited choices across workspace resize',
    (tester) async {
      _size(tester);
      final controller = _controller(_Writer());
      await controller.initialize();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => AppShell(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('song-tile-one')));
      await _tap(tester, find.byKey(const ValueKey('review-song-result')));
      await _tap(tester, _candidate(_lyrics));
      for (final size in [
        const Size(900, 900),
        const Size(1440, 960),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(find.byType(CandidateReviewPage), findsOneWidget);
        expect(_selected(tester, _album), isTrue);
        expect(_selected(tester, _lyrics), isFalse);
        expect(
          find.byKey(const ValueKey('save-original')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull, reason: '$size');
      }
    },
  );

  testWidgets('large text reduced motion keeps primary action reachable', (
    tester,
  ) async {
    _size(tester);
    final controller = _controller(_Writer());
    await _show(tester, controller, textScale: 2, reduceMotion: true);
    final apply = find.byKey(const ValueKey('save-original'));
    expect(apply.hitTestable(), findsOneWidget);
    await _tap(tester, _candidate(_album));
    expect(find.text('将补全 1 项'), findsOneWidget);
    expect(apply.hitTestable(), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1800));
    await tester.pumpAndSettle();
    expect(apply.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('newer query makes open preview stale and blocks saving', (
    tester,
  ) async {
    _size(tester);
    final writer = _Writer();
    final controller = _controller(writer);
    await _show(tester, controller);
    final store = controller.store as MemoryStore;
    store.snapshot = LibrarySnapshot(
      tracks: store.snapshot.tracks,
      tasks: [_task('one', createdAt: DateTime(2026, 10, 4, 0, 1))],
    );
    await controller.initialize();
    await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('save-original'));
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    expect(find.text('歌曲或查询结果已更新，请查看最新结果。'), findsOneWidget);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(writer.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving batch review changes no approval or files', (
    tester,
  ) async {
    _size(tester);
    final writer = _Writer();
    final controller = _controller(writer, tracks: 2);
    await _show(tester, controller, batch: true);
    expect(find.text('2 首歌曲 · 4 项资料'), findsOneWidget);
    await _tap(tester, find.byType(BackButton));
    expect(find.text('打开预览'), findsOneWidget);
    expect(writer.writes, isEmpty);
    for (final id in ['one', 'two']) {
      expect(
        controller.approvedSuggestionsFor(controller.taskForTrack(id)!),
        isEmpty,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large text batch progress stops safely and protects active writes',
    (tester) async {
      _size(tester);
      final writer = _Writer()..pending = Completer<String?>();
      final controller = _controller(writer, tracks: 2);
      await _show(
        tester,
        controller,
        batch: true,
        textScale: 2,
        reduceMotion: true,
      );
      final apply = find.byKey(const ValueKey('apply-reviewed-batch'));
      expect(apply.hitTestable(), findsOneWidget);
      await tester.tap(apply);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(writer.writes, hasLength(1));
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      final stop = find.byKey(const ValueKey('stop-reviewed-batch'));
      expect(stop.hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(RecommendedBatchReviewPage), findsOneWidget);
      await tester.tap(stop);
      await tester.pump();
      writer.pending!.complete(null);
      await tester.pumpAndSettle();
      expect(writer.writes, hasLength(1));
      expect(find.byType(RecommendedBatchReviewPage), findsOneWidget);
      expect(apply.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('batch apply excludes deselected rows and retains cancel state', (
    tester,
  ) async {
    _size(tester);
    final writer = _Writer();
    final controller = _controller(writer, tracks: 2);
    await _show(tester, controller, batch: true);
    await _tap(tester, find.byKey(const ValueKey('batch-include-two')));
    expect(find.text('1 首歌曲 · 2 项资料'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('apply-reviewed-batch')));
    expect(writer.writes, hasLength(1));
    expect(writer.writes.single.$1, 'one');
    expect(writer.writes.single.$2.map((item) => item.field), [
      AudioField.album,
      AudioField.lyrics,
    ]);
    expect(
      tester
          .widget<Checkbox>(find.byKey(const ValueKey('batch-include-two')))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<Checkbox>(find.byKey(const ValueKey('batch-include-one')))
          .value,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('apply-reviewed-batch')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
