import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _album = FieldSuggestion(
  field: AudioField.album,
  value: '已核对专辑',
  source: '离线测试',
);

class _Writer implements AudioCopyExporter, AudioOriginalSaver {
  int copies = 0;
  int originals = 0;
  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<String?> export(AudioTrack track, List<FieldSuggestion> values) async {
    copies++;
    return null;
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> values,
  ) async {
    originals++;
    return null;
  }
}

LibraryController _controller({_Writer? writer, bool withTasks = true}) =>
    LibraryController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [
            fixtureTrack(id: 'one', title: '第一首'),
            fixtureTrack(id: 'two', title: '第二首'),
          ],
          tasks: withTasks
              ? [
                  for (final id in ['one', 'two'])
                    CompletionTask(
                      trackId: id,
                      trackTitle: id == 'one' ? '第一首' : '第二首',
                      createdAt: DateTime(2026),
                      status: TaskStatus.needsReview,
                      message: '需要逐项确认',
                      suggestions: const [_album],
                    ),
                ]
              : [],
        ),
      ),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
      exporter: writer,
    );

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'select all applies to visible rows and preserves hidden selections',
    (tester) async {
      final controller = _controller(withTasks: false);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byKey(const ValueKey('toggle-library-selection')),
      );
      await _tap(tester, find.byKey(const ValueKey('select-visible-tracks')));
      expect(controller.selectedTrackIds, {'one', 'two'});
      await tester.enterText(find.byType(TextField), '第一首');
      await tester.pumpAndSettle();
      expect(find.textContaining('另有 1 首已选歌曲不在当前筛选中'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('select-visible-tracks')));
      expect(controller.selectedTrackIds, {'two'});
      await _tap(tester, find.byKey(const ValueKey('select-visible-tracks')));
      expect(controller.selectedTrackIds, {'one', 'two'});
      await _tap(
        tester,
        find.byKey(const ValueKey('toggle-library-selection')),
      );
      expect(controller.selectedTrackIds, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'original save is primary, unchecked choices never write, cancel stays reviewable',
    (tester) async {
      final writer = _Writer();
      final controller = _controller(writer: writer);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('补全任务'));
      await _tap(tester, find.text('确认 1 项候选').first);
      final original = find.byKey(const ValueKey('save-original'));
      expect(tester.widget<FilledButton>(original).onPressed, isNull);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(writer.originals, 0);
      await _tap(tester, find.byType(Checkbox));
      expect(tester.widget<FilledButton>(original).onPressed, isNotNull);
      await _tap(tester, original);
      expect(writer.originals, 1);
      expect(writer.copies, 0);
      expect(find.text('确认候选资料'), findsOneWidget);
      expect(find.text('保存到原文件（1 项）'), findsOneWidget);
      expect(find.text('导出副本（1 项）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit approval is reusable for batch and other candidates stay unreviewed',
    (tester) async {
      final controller = _controller(writer: _Writer());
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('补全任务'));
      await _tap(tester, find.text('确认 1 项候选').first);
      await _tap(tester, find.byType(Checkbox));
      await _tap(tester, find.byKey(const ValueKey('approve-for-batch')));
      expect(find.text('确认候选资料'), findsNothing);
      expect(
        controller.approvedSuggestionsFor(controller.taskForTrack('one')!),
        hasLength(1),
      );
      expect(
        controller.approvedSuggestionsFor(controller.taskForTrack('two')!),
        isEmpty,
      );
      await _tap(tester, find.byKey(const ValueKey('select-all-task-tracks')));
      expect(find.text('已选 2 首 · 已确认 1 首'), findsOneWidget);
      expect(find.textContaining('未确认、已保存或不可用的歌曲将跳过'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('bulk-save-original')),
            )
            .onPressed,
        isNotNull,
      );
      final store = controller.store as MemoryStore;
      final snapshot = store.snapshot;
      store.snapshot = LibrarySnapshot(
        tracks: snapshot.tracks,
        tasks: snapshot.tasks
            .map((task) => CompletionTask.fromJson(task.toJson()))
            .toList(),
      );
      await controller.initialize();
      await tester.pumpAndSettle();
      await _tap(tester, find.text('修改已确认资料'));
      await tester.scrollUntilVisible(
        find.byType(Checkbox),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CandidateReviewPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('revoke-approval')),
        -200,
        scrollable: find
            .descendant(
              of: find.byType(CandidateReviewPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _tap(tester, find.byKey(const ValueKey('revoke-approval')));
      expect(
        controller.approvedSuggestionsFor(controller.taskForTrack('one')!),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
