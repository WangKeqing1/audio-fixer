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
import 'package:audio_fixer/features/library/metadata_editor_page.dart';
import 'package:audio_fixer/features/library/track_detail_page.dart';
import 'package:audio_fixer/features/tasks/candidate_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Writer implements AudioCopyExporter, AudioOriginalSaver {
  int originals = 0;
  int copies = 0;
  List<FieldSuggestion> values = [];
  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<String?> export(AudioTrack track, List<FieldSuggestion> values) async {
    copies++;
    this.values = values;
    return null;
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> values,
  ) async {
    originals++;
    this.values = values;
    return null;
  }
}

class _Source implements MetadataSource {
  AudioTrack? search;
  Set<AudioField> fields = {};
  Completer<void>? pending;
  @override
  String get name => '离线测试';
  @override
  Set<AudioField> get supportedFields => {
    AudioField.title,
    AudioField.artist,
    AudioField.album,
  };
  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> requestedFields,
  ) async {
    search = track;
    fields = requestedFields;
    await pending?.future;
    return [
      for (final field in requestedFields)
        FieldSuggestion(field: field, value: '新${field.label}', source: name),
    ];
  }
}

class _Controller extends LibraryController {
  _Controller({required AudioTrack track, _Writer? writer, _Source? source})
    : super(
        store: MemoryStore(LibrarySnapshot(tracks: [track])),
        picker: FakePicker(),
        importer: FakeImporter(),
        completion: CompletionService(sources: source == null ? [] : [source]),
        exporter: writer,
      );
  Future<String?> Function()? chooseArtwork;
  @override
  Future<String?> pickArtwork() async => await chooseArtwork?.call();
}

AudioTrack _track({bool instrumental = false}) => AudioTrack(
  id: 'editable',
  fileName: 'editable.mp3',
  localPath: '/fixture/editable.mp3',
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
  isInstrumental: instrumental,
);

Future<void> _open(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => page)),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Future<void> _show(
  WidgetTester tester,
  Finder target, {
  double delta = 250,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 60,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _change(
  WidgetTester tester,
  AudioField field,
  String value, {
  bool select = true,
}) async {
  final input = find.byKey(ValueKey('edit-${field.name}'));
  await _show(tester, input);
  await tester.enterText(input, value);
  await tester.pumpAndSettle();
  if (select) {
    final checkbox = find.byKey(ValueKey('select-${field.name}'));
    await _show(tester, checkbox, delta: -200);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'fully tagged track keeps manual edit and custom query as fallback',
    (tester) async {
      final controller = _Controller(track: _track(), writer: _Writer());
      addTearDown(controller.dispose);
      await controller.initialize();
      await _open(
        tester,
        TrackDetailPage(
          track: controller.tracks.single,
          controller: controller,
        ),
      );
      expect(find.byKey(const ValueKey('edit-metadata')), findsNothing);
      await _show(tester, find.text('其他修复方式'));
      await tester.tap(find.text('其他修复方式'));
      await tester.pumpAndSettle();
      final edit = find.byKey(const ValueKey('edit-metadata'));
      await _show(tester, edit);
      expect(tester.widget<OutlinedButton>(edit).onPressed, isNotNull);
      final query = find.byKey(const ValueKey('query-metadata-repair'));
      expect(tester.widget<OutlinedButton>(query).onPressed, isNotNull);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.byType(MetadataEditorPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only checked changed values become unapproved replacements; save remains explicit',
    (tester) async {
      final writer = _Writer();
      final controller = _Controller(track: _track(), writer: writer);
      addTearDown(controller.dispose);
      await controller.initialize();
      await _open(
        tester,
        MetadataEditorPage(
          track: controller.tracks.single,
          controller: controller,
        ),
      );
      await _change(tester, AudioField.title, '新歌名');
      await _change(tester, AudioField.artist, '未选择的歌手', select: false);
      await _change(tester, AudioField.album, '', select: false);
      await tester.tap(find.byKey(const ValueKey('review-metadata-changes')));
      await tester.pumpAndSettle();
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      final task = controller.tasks.single;
      expect(task.suggestions, hasLength(1));
      expect(task.suggestions.single.field, AudioField.title);
      expect(task.suggestions.single.replaceExisting, isTrue);
      expect(task.approvedSuggestions, isEmpty);
      expect(controller.tracks.single.title, '旧歌名');
      expect(writer.originals, 0);
      expect(writer.copies, 0);
      await _show(tester, find.byType(Checkbox));
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(find.textContaining('将替换已有资料 · 歌名'), findsOneWidget);
      expect(find.text('当前：旧歌名'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-original')));
      await tester.pumpAndSettle();
      expect(writer.originals, 1);
      expect(writer.copies, 0);
      expect(writer.values.single.value, '新歌名');
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'extended tags are prefilled and invalid year cannot enter review',
    (tester) async {
      final controller = _Controller(track: _track(), writer: _Writer());
      addTearDown(controller.dispose);
      await controller.initialize();
      await _open(
        tester,
        MetadataEditorPage(
          track: controller.tracks.single,
          controller: controller,
        ),
      );
      for (final field in [
        AudioField.albumArtist,
        AudioField.year,
        AudioField.genre,
        AudioField.trackNumber,
        AudioField.trackTotal,
        AudioField.discNumber,
        AudioField.discTotal,
        AudioField.composer,
        AudioField.comment,
        AudioField.lyrics,
      ]) {
        final input = find.byKey(ValueKey('edit-${field.name}'));
        await _show(tester, input);
        expect(
          tester.widget<TextFormField>(input).controller!.text,
          controller.tracks.single.valueOf(field),
        );
      }
      await _show(tester, find.byKey(const ValueKey('edit-year')), delta: -300);
      await _change(tester, AudioField.year, 'not a year');
      await tester.tap(find.byKey(const ValueKey('review-metadata-changes')));
      await tester.pumpAndSettle();
      expect(find.text('年份须为 1–9999 的整数。'), findsOneWidget);
      expect(controller.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repair query includes existing chosen fields and uses corrected search clues',
    (tester) async {
      final source = _Source();
      final controller = _Controller(
        track: _track(),
        writer: _Writer(),
        source: source,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await _open(
        tester,
        MetadataEditorPage(
          track: controller.tracks.single,
          controller: controller,
          queryOnly: true,
        ),
      );
      final searchTitle = find.byKey(const ValueKey('search-title'));
      await _show(tester, searchTitle);
      await tester.enterText(searchTitle, '正确的搜索歌名');
      await _show(tester, find.byKey(const ValueKey('query-artist')));
      await tester.tap(find.byKey(const ValueKey('query-artist')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('review-metadata-changes')));
      await tester.pumpAndSettle();
      expect(source.search?.title, '正确的搜索歌名');
      expect(source.fields, {AudioField.title, AudioField.album});
      expect(controller.tracks.single.title, '旧歌名');
      expect(
        controller.tasks.single.suggestions.every(
          (item) => item.replaceExisting,
        ),
        isTrue,
      );
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(find.byType(CandidateReviewPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelled or failed second cover selection preserves prior image and checkbox',
    (tester) async {
      final controller = _Controller(track: _track(), writer: _Writer());
      addTearDown(controller.dispose);
      await controller.initialize();
      controller.chooseArtwork = () async =>
          'file:///fixture/missing-cover.png';
      await _open(
        tester,
        MetadataEditorPage(
          track: controller.tracks.single,
          controller: controller,
        ),
      );
      final choose = find.byKey(const ValueKey('pick-artwork'));
      await _show(tester, choose);
      await tester.tap(choose);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-artwork')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('封面预览加载失败'), findsOneWidget);
      controller.chooseArtwork = () async => null;
      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('select-artwork')),
            )
            .value,
        isTrue,
      );
      expect(find.text('新封面'), findsOneWidget);
      controller.chooseArtwork = () async => throw StateError('bad image');
      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('select-artwork')),
            )
            .value,
        isTrue,
      );
      expect(find.text('新封面'), findsOneWidget);
      expect(controller.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cover picker result after leaving editor does not reopen or update disposed page',
    (tester) async {
      final pending = Completer<String?>();
      final controller = _Controller(track: _track(), writer: _Writer())
        ..chooseArtwork = () => pending.future;
      addTearDown(controller.dispose);
      await controller.initialize();
      await _open(
        tester,
        MetadataEditorPage(
          track: controller.tracks.single,
          controller: controller,
        ),
      );
      await _show(tester, find.byKey(const ValueKey('pick-artwork')));
      await tester.tap(find.byKey(const ValueKey('pick-artwork')));
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      pending.complete('file:///fixture/missing-cover.png');
      await tester.pumpAndSettle();
      expect(find.byType(MetadataEditorPage), findsNothing);
      expect(find.text('打开'), findsOneWidget);
      expect(controller.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task retry preserves repair fields and clues when missing-field settings are off',
    (tester) async {
      final source = _Source();
      final controller = _Controller(
        track: _track(),
        writer: _Writer(),
        source: source,
      );
      final store = controller.store as MemoryStore;
      store.snapshot = LibrarySnapshot(
        tracks: [_track()],
        settings: const AppSettings(
          metadata: false,
          lyrics: false,
          artwork: false,
        ),
        tasks: [
          CompletionTask(
            trackId: 'editable',
            trackTitle: '旧歌名',
            createdAt: DateTime(2026),
            status: TaskStatus.failed,
            message: '上次查询失败',
            isRepair: true,
            queriedFields: const {AudioField.title},
            searchMetadata: const {'title': '正确搜索词', 'artist': '正确歌手'},
          ),
        ],
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补全任务'));
      await tester.pumpAndSettle();
      final retry = find.byKey(const ValueKey('retry-task-editable'));
      await _show(tester, retry);
      expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(source.fields, {AudioField.title});
      expect(source.search?.title, '正确搜索词');
      expect(source.search?.artist, '正确歌手');
      expect(controller.tracks.single.title, '旧歌名');
      expect(controller.tasks.single.isRepair, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual task continues editing its draft without querying or approving',
    (tester) async {
      final source = _Source();
      final controller = _Controller(
        track: _track(),
        writer: _Writer(),
        source: source,
      );
      final store = controller.store as MemoryStore;
      store.snapshot = LibrarySnapshot(
        tracks: [_track()],
        tasks: [
          CompletionTask(
            trackId: 'editable',
            trackTitle: '旧歌名',
            createdAt: DateTime(2026),
            status: TaskStatus.needsReview,
            message: '手动草稿',
            isRepair: true,
            queriedFields: const {AudioField.title},
            suggestions: const [
              FieldSuggestion(
                field: AudioField.title,
                value: '草稿歌名',
                source: '手动编辑',
                replaceExisting: true,
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(AudioFixerApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补全任务'));
      await tester.pumpAndSettle();
      final retry = find.byKey(const ValueKey('retry-task-editable'));
      await _show(tester, retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      final title = find.byKey(const ValueKey('edit-title'));
      await _show(tester, title);
      expect(tester.widget<TextFormField>(title).controller!.text, '草稿歌名');
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('select-title')),
            )
            .value,
        isFalse,
      );
      expect(source.search, isNull);
      expect(controller.tasks.single.approvedSuggestions, isEmpty);
      expect(controller.tracks.single.title, '旧歌名');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending query cannot replace a newer route when results arrive',
    (tester) async {
      final source = _Source()..pending = Completer<void>();
      final controller = _Controller(
        track: _track(),
        writer: _Writer(),
        source: source,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await _open(
        tester,
        MetadataEditorPage(
          track: controller.tracks.single,
          controller: controller,
          queryOnly: true,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('review-metadata-changes')));
      await tester.pump();
      Navigator.of(tester.element(find.byType(MetadataEditorPage))).push(
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
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'candidate cover previews use local file or reject untrusted remote host safely',
    (tester) async {
      final controller = _Controller(track: _track(), writer: _Writer());
      addTearDown(controller.dispose);
      final store = controller.store as MemoryStore;
      final task = CompletionTask(
        trackId: 'editable',
        trackTitle: '旧歌名',
        createdAt: DateTime(2026),
        status: TaskStatus.needsReview,
        message: '本机测试',
        suggestions: const [
          FieldSuggestion(
            field: AudioField.artwork,
            value: 'file:///fixture/missing-cover.png',
            source: '手动编辑',
          ),
          FieldSuggestion(
            field: AudioField.artwork,
            value: 'https://untrusted.example/cover.jpg',
            source: '不可信来源',
          ),
        ],
      );
      store.snapshot = LibrarySnapshot(tracks: [_track()], tasks: [task]);
      await controller.initialize();
      await _open(
        tester,
        CandidateReviewPage(task: task, controller: controller),
      );
      await _show(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.image is FileImage,
        ),
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.image is NetworkImage,
        ),
        findsNothing,
      );
      await _show(tester, find.text('来源：不可信来源\n补入缺失资料'));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('封面预览加载失败'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changed track blocks stale editor from producing a replacement task',
    (tester) async {
      final controller = _Controller(track: _track(), writer: _Writer());
      addTearDown(controller.dispose);
      await controller.initialize();
      await _open(
        tester,
        MetadataEditorPage(
          track: controller.tracks.single,
          controller: controller,
        ),
      );
      await _change(tester, AudioField.title, '过时的修改');
      final store = controller.store as MemoryStore;
      store.snapshot = LibrarySnapshot(
        tracks: [controller.tracks.single.withInstrumental(true)],
      );
      await controller.initialize();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('review-metadata-changes')),
            )
            .onPressed,
        isNull,
      );
      expect(controller.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('instrumental keeps lyric editor and lyric query disabled', (
    tester,
  ) async {
    final controller = _Controller(
      track: _track(instrumental: true),
      writer: _Writer(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await _open(
      tester,
      MetadataEditorPage(
        track: controller.tracks.single,
        controller: controller,
      ),
    );
    final lyrics = find.byKey(const ValueKey('edit-lyrics'));
    await _show(tester, lyrics);
    expect(tester.widget<TextFormField>(lyrics).enabled, isFalse);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('select-lyrics')))
          .onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unsupported source explains capabilities and keeps editing disabled',
    (tester) async {
      final controller = _Controller(track: _track());
      addTearDown(controller.dispose);
      await controller.initialize();
      await _open(
        tester,
        MetadataEditorPage(
          track: controller.tracks.single,
          controller: controller,
        ),
      );
      expect(find.text('此格式暂不支持编辑保存'), findsOneWidget);
      final title = find.byKey(const ValueKey('edit-title'));
      await _show(tester, title);
      expect(tester.widget<TextFormField>(title).enabled, isFalse);
      expect(controller.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final queryOnly in [false, true]) {
    testWidgets(
      'editor pinned action remains usable at large text, query=$queryOnly',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final controller = _Controller(
          track: _track(),
          writer: _Writer(),
          source: _Source(),
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        await _open(
          tester,
          MetadataEditorPage(
            track: controller.tracks.single,
            controller: controller,
            queryOnly: queryOnly,
          ),
        );
        final action = find.byKey(const ValueKey('review-metadata-changes'));
        final before = tester.getRect(action);
        await tester.drag(find.byType(ListView), const Offset(0, -1000));
        await tester.pumpAndSettle();
        expect(tester.getRect(action), before);
        expect(action.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
