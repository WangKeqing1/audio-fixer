import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/native_navigation.dart';
import 'support/fakes.dart';

class _LyricsSource implements MetadataSource {
  int calls = 0;
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
    return [];
  }
}

void main() {
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
