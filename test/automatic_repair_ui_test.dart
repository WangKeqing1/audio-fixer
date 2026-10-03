import 'dart:async';

import 'package:audio_fixer/app/audio_fixer_app.dart';
import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_fixer/features/library/metadata_editor_page.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _suggestions = [
  FieldSuggestion(
    field: AudioField.title,
    value: '正确歌名',
    source: '离线自动检索源',
    matchDescription: '歌名、歌手与时长一致',
  ),
  FieldSuggestion(
    field: AudioField.artwork,
    value: 'https://untrusted.example/cover.jpg',
    source: '离线封面来源',
    sourceUrl: 'https://musicbrainz.org/release/offline-test',
    matchDescription: '专辑与发行版本一致',
  ),
];

class _Source implements MetadataSource {
  int calls = 0;
  Set<AudioField> fields = {};
  AudioTrack? searchedTrack;
  List<FieldSuggestion> suggestions = _suggestions;
  bool fail = false;
  Completer<void>? pending;

  @override
  String get name => '离线自动检索源';
  @override
  Set<AudioField> get supportedFields =>
      AudioField.values.toSet()..remove(AudioField.comment);
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    calls++;
    fields = requestedFields;
    searchedTrack = track;
    await pending?.future;
    if (fail) throw StateError('offline source failure');
    return suggestions;
  }
}

AudioTrack _track({bool instrumental = false}) => AudioTrack(
  id: 'automatic',
  fileName: '旧歌名.mp3',
  localPath: '/fixture/automatic.mp3',
  sizeBytes: 123,
  importedAt: DateTime(2026),
  title: '旧歌名',
  artist: '旧歌手',
  album: '旧专辑',
  year: 2000,
  albumArtist: '旧专辑歌手',
  genre: '旧流派',
  trackNumber: 2,
  trackTotal: 10,
  discNumber: 1,
  discTotal: 2,
  composer: '旧作曲',
  comment: '旧备注',
  lyrics: '旧歌词',
  artworkPath: '/fixture/current-cover.png',
  isInstrumental: instrumental,
);

LibraryController _controller(_Source source, {AudioTrack? track}) =>
    LibraryController(
      store: MemoryStore(
        LibrarySnapshot(
          tracks: [track ?? _track()],
          settings: const AppSettings(
            metadata: false,
            lyrics: false,
            artwork: false,
          ),
        ),
      ),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(sources: [source]),
    );

Future<void> _open(WidgetTester tester, LibraryController controller) async {
  await tester.pumpWidget(AudioFixerApp(controller: controller));
  await tester.pumpAndSettle();
  await _show(tester, find.text('旧歌名'));
  await tester.tap(find.text('旧歌名'));
  await tester.pumpAndSettle();
}

Future<void> _show(
  WidgetTester tester,
  Finder target, {
  double delta = 180,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 50,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(320, 740),
    const Size(390, 844),
    const Size(900, 900),
  ]) {
    testWidgets('automatic repair and fallback fit $size at double text size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final source = _Source()..fail = true;
      final controller = _controller(source);
      await _open(tester, controller);
      final primary = find.byKey(const ValueKey('automatic-repair'));
      expect(tester.getRect(primary).bottom, lessThan(size.height));
      await tester.tap(primary);
      await tester.pumpAndSettle();
      await _show(tester, find.byKey(const ValueKey('edit-metadata')));
      expect(tester.getRect(primary).bottom, lessThan(size.height));
      expect(source.calls, 1);
      expect(find.byType(MetadataEditorPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'populated library opens automatic all-source-field repair without typing',
    (tester) async {
      final source = _Source();
      final controller = _controller(source);
      await _open(tester, controller);
      expect(controller.tracks.single.missingFields, isEmpty);
      expect(source.calls, 0);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(MetadataEditorPage), findsNothing);
      expect(find.byKey(const ValueKey('edit-metadata')), findsNothing);
      final automatic = find.byKey(const ValueKey('automatic-repair'));
      expect(tester.widget<FilledButton>(automatic).onPressed, isNotNull);
      await tester.tap(automatic);
      await tester.pumpAndSettle();
      expect(source.calls, 1);
      expect(source.fields, source.supportedFields);
      expect(source.fields, contains(AudioField.artwork));
      expect(source.fields, contains(AudioField.composer));
      expect(source.searchedTrack?.title, '旧歌名');
      expect(source.searchedTrack?.artist, '旧歌手');
      expect(source.searchedTrack?.album, '旧专辑');
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      expect(find.byType(MetadataEditorPage), findsNothing);
      final task = controller.tasks.single;
      expect(task.isRepair, isTrue);
      expect(task.queriedFields, source.supportedFields);
      expect(task.searchMetadata, isEmpty);
      expect(task.approvedSuggestions, isEmpty);
      expect(task.suggestions.every((item) => item.replaceExisting), isTrue);
      final artwork = task.suggestions.last;
      expect(artwork.source, '离线封面来源');
      expect(artwork.matchDescription, '专辑与发行版本一致');
      expect(artwork.sourceUrl, 'https://musicbrainz.org/release/offline-test');
      await _show(tester, find.byType(Checkbox));
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isFalse,
      );
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(source.calls, 1);
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(controller.tracks.single.title, '旧歌名');
      expect(controller.selectedTrackIds, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final failed in [false, true]) {
    testWidgets(
      '${failed ? 'failed' : 'empty'} automatic lookup shows result, retry and optional fallback',
      (tester) async {
        final source = _Source()
          ..suggestions = []
          ..fail = failed;
        final controller = _controller(source);
        await _open(tester, controller);
        await tester.tap(find.byKey(const ValueKey('automatic-repair')));
        await tester.pumpAndSettle();
        expect(find.byType(TrackDetailPage), findsOneWidget);
        expect(find.byType(MetadataEditorPage), findsNothing);
        expect(find.byType(TextFormField), findsNothing);
        expect(
          controller.tasks.single.status,
          failed ? TaskStatus.failed : TaskStatus.noMatch,
        );
        await _show(
          tester,
          find.byKey(const ValueKey('automatic-repair-result')),
        );
        expect(find.text(controller.tasks.single.message), findsOneWidget);
        expect(find.text('其他修复方式'), findsOneWidget);
        await _show(tester, find.byKey(const ValueKey('edit-metadata')));
        expect(find.text('手动编辑元数据与封面'), findsOneWidget);
        expect(find.text('调整检索条件'), findsOneWidget);
        source
          ..fail = false
          ..suggestions = _suggestions;
        await _show(
          tester,
          find.byKey(const ValueKey('retry-automatic-repair')),
          delta: -180,
        );
        await tester.tap(find.byKey(const ValueKey('retry-automatic-repair')));
        await tester.pumpAndSettle();
        expect(source.calls, 2);
        expect(find.byType(CandidateReviewPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'pending automatic query blocks repeated taps and late navigation',
    (tester) async {
      final source = _Source()..pending = Completer<void>();
      final controller = _controller(source);
      await _open(tester, controller);
      final automatic = find.byKey(const ValueKey('automatic-repair'));
      final action = tester.widget<FilledButton>(automatic).onPressed!;
      action();
      action();
      await tester.pump();
      expect(source.calls, 1);
      expect(tester.widget<FilledButton>(automatic).onPressed, isNull);
      Navigator.of(tester.element(find.byType(TrackDetailPage))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('新的页面')),
        ),
      );
      await tester.pumpAndSettle();
      source.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('新的页面'), findsOneWidget);
      expect(find.byType(CandidateReviewPage), findsNothing);
      expect(controller.tasks.single.suggestions, isNotEmpty);
      expect(source.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving detail during lookup does not reopen a page', (
    tester,
  ) async {
    final source = _Source()..pending = Completer<void>();
    final controller = _controller(source);
    await _open(tester, controller);
    await tester.tap(find.byKey(const ValueKey('automatic-repair')));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(milliseconds: 400));
    source.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TrackDetailPage), findsNothing);
    expect(find.byType(CandidateReviewPage), findsNothing);
    expect(find.byType(MetadataEditorPage), findsNothing);
    expect(source.calls, 1);
    expect(controller.tasks.single.suggestions, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'instrumental automatic lookup skips lyrics and still finds cover',
    (tester) async {
      final source = _Source();
      final controller = _controller(source, track: _track(instrumental: true));
      await _open(tester, controller);
      await tester.tap(find.byKey(const ValueKey('automatic-repair')));
      await tester.pumpAndSettle();
      expect(source.fields, isNot(contains(AudioField.lyrics)));
      expect(source.fields, contains(AudioField.artwork));
      expect(
        controller.tasks.single.queriedFields,
        source.supportedFields.difference({AudioField.lyrics}),
      );
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'custom query offers compact supported choices without auto-query',
    (tester) async {
      final source = _Source();
      final controller = _controller(source);
      await _open(tester, controller);
      await _show(tester, find.text('其他修复方式'));
      await tester.tap(find.text('其他修复方式'));
      await tester.pumpAndSettle();
      await _show(tester, find.byKey(const ValueKey('query-metadata-repair')));
      await tester.tap(find.byKey(const ValueKey('query-metadata-repair')));
      await tester.pumpAndSettle();
      expect(source.calls, 0);
      expect(find.byType(MetadataEditorPage), findsOneWidget);
      await _show(tester, find.byKey(const ValueKey('query-artwork')));
      expect(
        find.byType(FilterChip),
        findsNWidgets(source.supportedFields.length),
      );
      expect(find.byKey(const ValueKey('query-comment')), findsNothing);
      expect(find.textContaining('暂无在线来源'), findsNothing);
      await _show(
        tester,
        find.byKey(const ValueKey('unsupported-query-fields')),
      );
      expect(find.textContaining('当前数据源不支持：备注'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('query-artwork')));
      await tester.pumpAndSettle();
      expect(source.calls, 0);
      expect(controller.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
