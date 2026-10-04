import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _ChangedTagsLibrary extends FakeDeviceLibrary {
  @override
  Future<AudioTrack> readDetails(AudioTrack track) async {
    detailsCount++;
    return track.withDetails(
      title: '文件中的新歌名',
      artist: track.artist,
      album: null,
      year: null,
      durationMs: 60000,
      lyrics: null,
      artworkPath: null,
    );
  }
}

void main() {
  testWidgets(
    'successful cached tags can be reread when the media index is unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final indexed = fixtureDeviceTrack();
      final cached = indexed.withDetails(
        title: '缓存的旧歌名',
        artist: indexed.artist,
        album: null,
        year: null,
        durationMs: 60000,
        lyrics: null,
        artworkPath: null,
      );
      final task = CompletionTask(
        trackId: cached.id,
        trackTitle: cached.displayTitle,
        createdAt: DateTime(2026),
        status: TaskStatus.needsReview,
        message: 'Offline test candidate for the old tags.',
        suggestions: const [
          FieldSuggestion(
            field: AudioField.album,
            value: '旧资料候选',
            source: 'Offline fixture',
          ),
        ],
      );
      final library = _ChangedTagsLibrary()..songs = [indexed];
      final controller = testController(
        deviceLibrary: library,
        store: MemoryStore(LibrarySnapshot(tracks: [cached], tasks: [task])),
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存的旧歌名'));
      await tester.pumpAndSettle();
      expect(library.detailsCount, 0);
      expect(controller.trackById(cached.id)!.readError, isNull);
      await tester.ensureVisible(find.text('歌曲与文件详情'));
      await tester.tap(find.text('歌曲与文件详情'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重新读取'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(library.detailsCount, 1);
      final refreshed = controller.trackById(cached.id)!;
      expect(refreshed.title, '文件中的新歌名');
      expect(refreshed.dateModifiedMs, cached.dateModifiedMs);
      expect(refreshed.sizeBytes, cached.sizeBytes);
      expect(controller.tasks.single.status, TaskStatus.outdated);
      expect(controller.isTaskCurrent(task), isFalse);
      expect(find.text('重新读取'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
