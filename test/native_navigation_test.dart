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
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:audio_fixer/features/tasks/recommended_batch_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/native_navigation.dart';
import 'support/fakes.dart';

class _LyricsSource implements MetadataSource {
  int calls = 0;
  bool suggest = false;
  @override
  String get name => 'Offline native navigation fixture';
  @override
  Set<AudioField> get supportedFields => {AudioField.lyrics};
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async {
    expect(fields, {AudioField.lyrics});
    calls++;
    return suggest
        ? [
            FieldSuggestion(
              field: AudioField.lyrics,
              value:
                  '[00:00.00]Synthetic Android runtime fixture only\n'
                  '[00:00.60]Native save cancellation and retry',
              source: name,
            ),
          ]
        : [];
  }
}

class _CancelledWriter implements AudioCopyExporter, AudioOriginalSaver {
  int originals = 0;
  int copies = 0;
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

class _PendingOriginalWriter extends _CancelledWriter {
  final result = Completer<String?>();
  final writtenIds = <String>[];

  @override
  Future<String?> saveOriginal(AudioTrack track, List<FieldSuggestion> values) {
    originals++;
    writtenIds.add(track.id);
    return result.future;
  }
}

void main() {
  testWidgets('native saved batch result waits for review route dismissal', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const suggestion = FieldSuggestion(
      field: AudioField.lyrics,
      value: 'Offline reviewed native navigation fixture',
      source: 'Fixture',
    );
    final writer = _PendingOriginalWriter();
    final controller = LibraryController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [
            fixtureTrack(id: 'approved'),
            fixtureTrack(id: 'unapproved'),
          ],
          tasks: [
            for (final id in ['approved', 'unapproved'])
              CompletionTask(
                trackId: id,
                trackTitle: id,
                createdAt: DateTime(2026),
                status: id == 'approved'
                    ? TaskStatus.readyToSave
                    : TaskStatus.needsReview,
                message: 'Offline fixture',
                suggestions: const [suggestion],
                approvedSuggestions: id == 'approved'
                    ? const [suggestion]
                    : const [],
                reviewSelectionMade: id == 'approved',
              ),
          ],
        ),
      ),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(),
      exporter: writer,
    );
    await tester.pumpWidget(AudioFixerApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('补全任务'));
    await tester.pumpAndSettle();
    await showNativeTarget(
      tester,
      find.byKey(const ValueKey('select-all-task-tracks')),
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(
      find.byKey(const ValueKey('select-all-task-tracks')).hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(controller.selectedTrackIds, {'approved', 'unapproved'});
    await tester.tap(
      find.byKey(const ValueKey('bulk-save-original')).hitTestable(),
    );
    await tester.pumpAndSettle();
    final review = find.byType(RecommendedBatchReviewPage);
    expect(review, findsOneWidget);
    expect(writer.writtenIds, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey('apply-reviewed-batch')).hitTestable(),
    );
    await tester.pump();
    expect(writer.writtenIds, ['approved']);
    expect(controller.isBusy, isTrue);
    writer.result.complete('content://fixture/approved');
    await tester.pump();
    // The native wait exits once persistence is complete, before the route
    // animation is drained. Reproduce that state rather than hiding it.
    expect(controller.isBusy, isFalse);
    expect(
      controller.taskForTrack('approved')!.status,
      TaskStatus.savedOriginal,
    );
    expect(review, findsOneWidget);
    expect(find.byKey(const ValueKey('batch-progress')), findsNWidgets(2));
    final result = await showNativeSavedBatchResult(tester);
    expect(review, findsNothing);
    expect(result.hitTestable(), findsOneWidget);
    expect(
      find.descendant(
        of: result,
        matching: find.text(controller.batchOperation!.summary),
      ),
      findsOneWidget,
    );
    expect(controller.batchOperation!.savedOriginalCount, 1);
    expect(writer.writtenIds, ['approved']);
    expect(
      controller.taskForTrack('unapproved')!.status,
      TaskStatus.needsReview,
    );
    expect(controller.taskForTrack('unapproved')!.approvedSuggestions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native review checkbox clears fixed footer before explicit approval',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final track = fixtureTrack();
      final source = _LyricsSource()..suggest = true;
      final writer = _CancelledWriter();
      final controller = LibraryController(
        store: MemoryStore(
          LibrarySnapshot(
            tracks: [track],
            settings: const AppSettings(
              metadata: false,
              artwork: false,
              lyrics: true,
            ),
          ),
        ),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: [source]),
        exporter: writer,
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      final library = find.byKey(const PageStorageKey('library-scroll-view'));
      await showNativeTarget(
        tester,
        find.text(track.displayTitle),
        scrollable: find
            .descendant(of: library, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(find.text(track.displayTitle).hitTestable());
      await tester.pumpAndSettle();
      await tapNativeMissingOnly(tester);
      await tester.pumpAndSettle();
      final review = find.byType(CandidateReviewPage);
      expect(review, findsOneWidget);
      final checkbox = find.descendant(
        of: review,
        matching: find.byType(Checkbox),
      );
      final scroll = find
          .descendant(of: review, matching: find.byType(Scrollable))
          .first;
      final save = find.byKey(const ValueKey('save-original'));
      expect(tester.widget<Checkbox>(checkbox).value, isFalse);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(writer.originals, 0);
      expect(writer.copies, 0);
      await showNativeTarget(tester, checkbox, scrollable: scroll);
      await tester.tap(checkbox.hitTestable());
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(checkbox).value, isTrue);
      expect(find.text('应用建议（1 项）'), findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(writer.originals, 0);
      expect(writer.copies, 0);
      final export = find.byKey(const ValueKey('export-copy'));
      expect(export.hitTestable(), findsOneWidget);
      await tester.tap(export.hitTestable());
      await tester.pumpAndSettle();
      expect(writer.copies, 1);
      expect(writer.originals, 0);
      expect(review, findsOneWidget);
      await showNativeTarget(tester, checkbox, scrollable: scroll);
      expect(tester.widget<Checkbox>(checkbox).value, isTrue);
      final approve = find.byKey(const ValueKey('approve-for-batch'));
      await showNativeTarget(tester, approve, scrollable: scroll);
      await tester.tap(approve.hitTestable());
      await tester.pumpAndSettle();
      expect(review, findsNothing);
      expect(
        controller.approvedSuggestionsFor(controller.taskForTrack(track.id)!),
        hasLength(1),
      );
      final detail = find.byType(TrackDetailPage);
      final close = find.byKey(const ValueKey('close-selected-song'));
      await showNativeTarget(
        tester,
        close,
        delta: -180,
        scrollable: find
            .descendant(of: detail, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(close.hitTestable());
      await tester.pumpAndSettle();
      expect(detail, findsNothing);
      expect(writer.originals, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final expanded in [false, true]) {
    testWidgets(
      'native missing-only action with ${expanded ? 'expanded' : 'collapsed'} disclosure and pinned navigation',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 1920);
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = _LyricsSource();
        final track = fixtureTrack();
        final controller = testController(
          completion: CompletionService(sources: [source]),
          store: MemoryStore(
            LibrarySnapshot(
              tracks: [track],
              settings: const AppSettings(
                metadata: false,
                artwork: false,
                lyrics: true,
              ),
              tasks: expanded
                  ? [
                      CompletionTask(
                        trackId: track.id,
                        trackTitle: track.displayTitle,
                        createdAt: DateTime(2026),
                        status: TaskStatus.noMatch,
                        message: 'No prior fixture lyric match',
                        queriedFields: {AudioField.lyrics},
                      ),
                    ]
                  : [],
            ),
          ),
        );
        await tester.pumpWidget(AudioFixerApp(controller: controller));
        await tester.pumpAndSettle();
        final list = find.byKey(const PageStorageKey('library-scroll-view'));
        final scroll = find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first;
        final title = find.text(track.displayTitle);
        await tester.scrollUntilVisible(title, 180, scrollable: scroll);
        await tester.pumpAndSettle();
        await tester.tap(title.hitTestable());
        await tester.pumpAndSettle();
        expect(find.byType(TrackDetailPage), findsOneWidget);
        expect(
          tester.widget<TrackDetailPage>(find.byType(TrackDetailPage)).embedded,
          isTrue,
        );
        final navigation = find.byType(NavigationBar);
        final pinnedRect = tester.getRect(navigation);
        await tapNativeMissingOnly(tester);
        await tester.pumpAndSettle();
        expect(source.calls, 1);
        expect(controller.taskForTrack(track.id)!.status, TaskStatus.noMatch);
        expect(tester.getRect(navigation), pinnedRect);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
