import 'dart:async';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Source implements MetadataSource {
  final calls = <String, Set<AudioField>>{};
  final started = Completer<void>();
  Completer<void>? hold;
  @override
  String get name => 'Offline verified source';
  @override
  Set<AudioField> get supportedFields => {
    ...AudioField.coreFields,
    AudioField.albumArtist,
    AudioField.year,
    AudioField.trackNumber,
  };
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async {
    calls[track.id] = fields;
    if (!started.isCompleted) started.complete();
    await hold?.future;
    return [
      for (final field in fields)
        FieldSuggestion(
          field: field,
          value: field.isNumeric ? '3' : 'New ${field.name}',
          source: name,
        ),
    ];
  }
}

AudioTrack _song(String id, {bool instrumental = false}) => AudioTrack(
  id: id,
  fileName: '$id.mp3',
  localPath: '/fixture/$id.mp3',
  sizeBytes: 1024,
  importedAt: DateTime(2026),
  title: 'Song $id',
  artist: 'Artist',
  album: 'Album',
  lyrics: 'Existing lyrics',
  artworkPath: '/fixture/cover.jpg',
  albumArtist: 'Album artist',
  year: 2001,
  trackNumber: 1,
  isInstrumental: instrumental,
);

LibraryController _controller(
  _Source source, {
  AppSettings settings = const AppSettings(),
}) => LibraryController(
  store: MemoryStore(
    LibrarySnapshot(
      tracks: [_song('one'), _song('two', instrumental: true)],
      settings: settings,
    ),
  ),
  picker: FakePicker(),
  importer: FakeImporter(),
  completion: CompletionService(sources: [source]),
);

void main() {
  test('automatic batch queries populated fields, respects instrumental, never approves', () async {
    final source = _Source();
    final controller = _controller(
      source,
      settings: const AppSettings(
        metadata: false,
        lyrics: false,
        artwork: false,
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.queryAutomaticRepair(trackIds: {'one', 'two'});
    expect(source.calls['one'], source.supportedFields);
    expect(
      source.calls['two'],
      source.supportedFields.difference({AudioField.lyrics}),
    );
    expect(
      source.calls.values.every(
        (fields) => !fields.contains(AudioField.comment),
      ),
      isTrue,
    );
    for (final task in controller.tasks) {
      expect(task.isRepair, isTrue);
      expect(task.approvedSuggestions, isEmpty);
      expect(
        task.suggestions.every((candidate) => candidate.replaceExisting),
        isTrue,
      );
    }
    expect(controller.trackById('one')!.title, 'Song one');
    expect(controller.trackById('two')!.lyrics, 'Existing lyrics');
  });

  test(
    'automatic batch remains sequential and stop preserves unqueried song',
    () async {
      final source = _Source()..hold = Completer<void>();
      final controller = _controller(source);
      addTearDown(controller.dispose);
      await controller.initialize();
      final pending = controller.queryAutomaticRepair(trackIds: {'one', 'two'});
      await source.started.future;
      expect(source.calls.keys, ['one']);
      await controller.queryAutomaticRepair(trackIds: {'two'});
      expect(source.calls.keys, ['one']);
      controller.stopCompletion();
      source.hold!.complete();
      await pending;
      expect(source.calls.keys, ['one']);
      expect(controller.taskForTrack('one')!.isRepair, isTrue);
      expect(controller.taskForTrack('two'), isNull);
      expect(controller.canOperate, isTrue);
    },
  );

  testWidgets(
    'selection is local and batch defaults to complete automatic repair',
    (tester) async {
      final source = _Source();
      final controller = _controller(source);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toggle-library-selection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-visible-tracks')));
      await tester.pumpAndSettle();
      expect(source.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('bulk-query-selected')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('batch-query-missing-only')),
            )
            .value,
        isFalse,
      );
      expect(
        find.byType(TextField),
        findsOneWidget,
      ); // Library search only; no query form.
      expect(source.calls, isEmpty);
      await tester.tap(find.text('开始查询'));
      await tester.pumpAndSettle();
      expect(source.calls['one'], source.supportedFields);
      expect(controller.tasks.every((task) => task.isRepair), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch missing-only choice stays explicit and cancel never queries',
    (tester) async {
      final source = _Source();
      final controller = _controller(source);
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toggle-library-selection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-visible-tracks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bulk-query-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(source.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('bulk-query-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('batch-query-missing-only')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始查询'));
      await tester.pumpAndSettle();
      expect(
        source.calls,
        isEmpty,
      ); // These songs already have every core field.
      expect(controller.tasks.every((task) => !task.isRepair), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
