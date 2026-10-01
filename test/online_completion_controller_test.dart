import 'dart:async';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _DelayedSource implements MetadataSource, SourceConnectionTester {
  final started = Completer<void>();
  final result = Completer<List<FieldSuggestion>>();
  int lookups = 0;
  int checks = 0;
  @override
  String get name => 'Test service';
  @override
  Set<AudioField> get supportedFields => AudioField.values.toSet();
  @override
  Future<void> checkConnection() async {
    checks++;
  }

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) {
    lookups++;
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}

void main() {
  test(
    'stopping a batch saves the current result and skips remaining songs',
    () async {
      final source = _DelayedSource();
      final store = MemoryStore(
        LibrarySnapshot(
          tracks: [
            fixtureTrack(id: 'one'),
            fixtureTrack(id: 'two'),
          ],
        ),
      );
      final controller = testController(
        store: store,
        completion: CompletionService(sources: [source]),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final operation = controller.complete();
      await source.started.future;
      controller.stopCompletion();
      source.result.complete(const [
        FieldSuggestion(
          field: AudioField.lyrics,
          value: 'Synthetic test lyrics',
          source: 'Test service',
        ),
      ]);
      await operation;
      expect(source.lookups, 1);
      expect(store.snapshot.tasks.single.trackId, 'one');
      expect(controller.isCompleting, isFalse);
      expect(controller.isBusy, isFalse);
      expect(controller.notice, contains('已停止'));
      expect(
        controller.tracks.first.lyrics,
        isNull,
        reason: 'Candidate preview is separate from tag writing.',
      );
    },
  );

  test('connection check performs source probes without reading audio or making tasks', () async {
    final source = _DelayedSource();
    final controller = testController(
      completion: CompletionService(sources: [source]),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.checkSourceConnections();
    expect(source.checks, 1);
    expect(source.lookups, 0);
    expect(controller.tasks, isEmpty);
    expect(controller.sourceConnections[source.name], '连接测试通过');
  });
}
