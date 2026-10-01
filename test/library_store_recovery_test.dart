import 'dart:convert';
import 'dart:io';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/fakes.dart';

LibrarySnapshot _snapshot(String id) => LibrarySnapshot(
  tracks: [fixtureTrack(id: id)],
  tasks: [
    CompletionTask(
      trackId: id,
      trackTitle: '已检查的歌曲',
      createdAt: DateTime.utc(2026, 1, 2),
      status: TaskStatus.exported,
      message: '已保存副本',
      exportedCopyUri: 'content://documents/$id',
      suggestions: const [
        FieldSuggestion(
          field: AudioField.lyrics,
          value: '[00:01]自行生成的测试歌词',
          source: 'test',
          sourceUrl: 'https://example.com/song',
          matchDescription: '测试歌曲资料匹配',
        ),
      ],
    ),
  ],
  settings: const AppSettings(theme: AppTheme.dark, artwork: false),
);

void main() {
  late Directory root;
  late JsonLibraryStore store;
  File file([String suffix = '']) =>
      File(p.join(root.path, 'library.json$suffix'));
  Future<void> writeSnapshot(String suffix, LibrarySnapshot snapshot) =>
      file(suffix).writeAsString(jsonEncode(snapshot.toJson()));
  Future<Map<String, dynamic>> readJson([String suffix = '']) async =>
      jsonDecode(await file(suffix).readAsString()) as Map<String, dynamic>;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audio-fixer-recovery-');
    store = JsonLibraryStore(() async => root);
  });
  tearDown(() async => root.delete(recursive: true));

  test('empty installation loads without creating a catalog', () async {
    final loaded = await store.load();
    expect(loaded.tracks, isEmpty);
    expect(loaded.tasks, isEmpty);
    expect(loaded.recoveredFromBackup, isFalse);
    expect(loaded.recoveryNotice, isNull);
    expect(await root.list().length, 0);
  });

  test('first save creates a complete validated recovery copy', () async {
    await store.save(_snapshot('first'));
    expect(await readJson('.bak'), await readJson());
    final loaded = await store.load();
    expect(loaded.tracks.single.id, 'first');
    expect(loaded.tasks.single.exportedCopyUri, 'content://documents/first');
    expect(loaded.tasks.single.suggestions.single.value, '[00:01]自行生成的测试歌词');
    expect(loaded.settings.theme, AppTheme.dark);
    expect(loaded.settings.artwork, isFalse);
    expect(loaded.recoveredFromBackup, isFalse);
    expect(await file('.tmp').exists(), isFalse);
    expect(await file('.bak.tmp').exists(), isFalse);
  });

  test(
    'each save rotates the previous committed snapshot into backup',
    () async {
      await store.save(_snapshot('first'));
      await store.save(_snapshot('second'));
      await store.save(_snapshot('third'));
      expect((await readJson())['tracks'][0]['id'], 'third');
      expect((await readJson('.bak'))['tracks'][0]['id'], 'second');
    },
  );

  test(
    'damaged primary recovers backup and preserves original bytes and media',
    () async {
      await store.save(_snapshot('first'));
      await store.save(_snapshot('second'));
      final audio = File(
        p.join(root.path, 'audio', 'newer-private-copy.audio'),
      );
      await audio.parent.create();
      await audio.writeAsBytes([7, 8, 9]);
      await file().writeAsString('{"version":1,"tracks":[');
      final loaded = await store.load();
      expect(loaded.tracks.single.id, 'first');
      expect(loaded.tasks.single.exportedCopyUri, 'content://documents/first');
      expect(loaded.recoveredFromBackup, isTrue);
      expect(loaded.recoveryNotice, contains('已暂停自动清理'));
      expect(await audio.readAsBytes(), [7, 8, 9]);
      final preserved = await root
          .list()
          .where((entry) => entry.path.contains('.preserved-'))
          .toList();
      expect(preserved, hasLength(1));
      expect(
        await File(preserved.single.path).readAsString(),
        '{"version":1,"tracks":[',
      );
      expect((await readJson())['recoveredFromBackup'], isTrue);
      expect((await store.load()).recoveredFromBackup, isTrue);
    },
  );

  test(
    'invalid UTF-8 primary bytes recover without losing the original file',
    () async {
      await writeSnapshot('.bak', _snapshot('safe'));
      await file().writeAsBytes([0xff, 0xfe, 0x80]);
      final loaded = await store.load();
      expect(loaded.tracks.single.id, 'safe');
      final preserved = await root
          .list()
          .where((entry) => entry.path.contains('.preserved-'))
          .toList();
      expect(await File(preserved.single.path).readAsBytes(), [
        0xff,
        0xfe,
        0x80,
      ]);
    },
  );

  test(
    'recovery warning remains after edits that construct a fresh snapshot',
    () async {
      await store.save(_snapshot('first'));
      await file().writeAsString('damaged');
      await store.load();
      await store.save(_snapshot('edited'));
      final loaded = await JsonLibraryStore(() async => root).load();
      expect(loaded.tracks.single.id, 'edited');
      expect(loaded.recoveredFromBackup, isTrue);
    },
  );

  test(
    'missing primary recovers the committed backup before a newer staged save',
    () async {
      await writeSnapshot('.bak', _snapshot('committed'));
      await writeSnapshot('.tmp', _snapshot('uncommitted'));
      final loaded = await store.load();
      expect(loaded.tracks.single.id, 'committed');
      expect(loaded.recoveredFromBackup, isTrue);
      final preserved = await root
          .list()
          .where((entry) => entry.path.contains('.tmp.preserved-'))
          .toList();
      expect(preserved, hasLength(1));
      expect(
        jsonDecode(
          await File(preserved.single.path).readAsString(),
        )['tracks'][0]['id'],
        'uncommitted',
      );
    },
  );

  test(
    'a complete interrupted first save is recovered with a warning',
    () async {
      await writeSnapshot('.tmp', _snapshot('staged'));
      final loaded = await store.load();
      expect(loaded.tracks.single.id, 'staged');
      expect(loaded.recoveredFromBackup, isTrue);
      expect((await readJson())['tracks'][0]['id'], 'staged');
    },
  );

  test(
    'a valid staged backup can rescue a missing primary and broken backup',
    () async {
      await file('.bak').writeAsString('broken');
      await writeSnapshot('.bak.tmp', _snapshot('staged-backup'));
      expect((await store.load()).tracks.single.id, 'staged-backup');
    },
  );

  test(
    'valid primary wins over interrupted or corrupted staging files',
    () async {
      await writeSnapshot('', _snapshot('committed'));
      await writeSnapshot('.tmp', _snapshot('interrupted'));
      await file('.bak').writeAsString('broken');
      await file('.bak.tmp').writeAsString('{');
      final loaded = await store.load();
      expect(loaded.tracks.single.id, 'committed');
      expect(loaded.recoveredFromBackup, isFalse);
      await store.save(_snapshot('new'));
      expect((await readJson('.bak'))['tracks'][0]['id'], 'committed');
      expect((await store.load()).tracks.single.id, 'new');
    },
  );

  test(
    'corruption without recovery fails visibly and keeps all evidence',
    () async {
      for (final suffix in ['', '.bak', '.tmp']) {
        await file(suffix).writeAsString('broken$suffix');
      }
      await expectLater(store.load(), throwsFormatException);
      await expectLater(
        store.save(_snapshot('replacement')),
        throwsFormatException,
      );
      for (final suffix in ['', '.bak', '.tmp']) {
        expect(await file(suffix).readAsString(), 'broken$suffix');
      }
    },
  );

  test(
    'orphaned invalid staging data does not silently become an empty library',
    () async {
      await file('.tmp').writeAsString('{"version":1');
      await expectLater(store.load(), throwsFormatException);
      expect(await file('.tmp').readAsString(), '{"version":1');
      expect(await file().exists(), isFalse);
    },
  );

  test(
    'a primary directory is an error rather than an empty library',
    () async {
      await Directory(file().path).create();
      await expectLater(store.load(), throwsA(isA<FileSystemException>()));
    },
  );

  test('backup write failure leaves committed catalog and media intact and allows retry', () async {
    await store.save(_snapshot('first'));
    final primary = await file().readAsString();
    final backup = await file('.bak').readAsString();
    final obstruction = Directory(file('.bak.tmp').path);
    await obstruction.create();
    await expectLater(
      store.save(_snapshot('second')),
      throwsA(isA<FileSystemException>()),
    );
    expect(await file().readAsString(), primary);
    expect(await file('.bak').readAsString(), backup);
    expect(await file('.tmp').exists(), isFalse);
    await obstruction.delete();
    await store.save(_snapshot('retry'));
    expect((await store.load()).tracks.single.id, 'retry');
  });

  test(
    'first-save backup failure does not report a failed committed save',
    () async {
      await Directory(file('.bak.tmp').path).create();
      await store.save(_snapshot('committed'));
      expect((await store.load()).tracks.single.id, 'committed');
      expect(await file('.tmp').exists(), isFalse);
    },
  );

  test(
    'valid backup remains readable if repairing primary cannot write',
    () async {
      await writeSnapshot('.bak', _snapshot('backup'));
      await file().writeAsString('damaged');
      final obstruction = Directory(file('.restore.tmp').path);
      await obstruction.create();
      final loaded = await store.load();
      expect(loaded.tracks.single.id, 'backup');
      expect(loaded.recoveredFromBackup, isTrue);
      expect(await file().readAsString(), 'damaged');
      await expectLater(
        store.save(_snapshot('edit')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file().readAsString(), 'damaged');
      await obstruction.delete();
      await store.save(_snapshot('retry'));
      expect((await store.load()).tracks.single.id, 'retry');
    },
  );

  test(
    'overlapping reads and saves on different store instances remain ordered',
    () async {
      final other = JsonLibraryStore(() async => root);
      final one = store.save(_snapshot('one'));
      final two = other.save(_snapshot('two'));
      final read = store.load();
      final three = other.save(_snapshot('three'));
      await Future.wait([one, two, three]);
      expect((await read).tracks.single.id, 'two');
      expect((await store.load()).tracks.single.id, 'three');
      expect((await readJson('.bak'))['tracks'][0]['id'], 'two');
    },
  );

  test(
    'save captures track and task lists before caller mutates them',
    () async {
      final tracks = [fixtureTrack(id: 'kept')];
      final tasks = [..._snapshot('kept').tasks];
      final saving = store.save(LibrarySnapshot(tracks: tracks, tasks: tasks));
      tracks.clear();
      tasks.clear();
      await saving;
      final loaded = await store.load();
      expect(loaded.tracks.single.id, 'kept');
      expect(loaded.tasks.single.trackId, 'kept');
    },
  );

  test(
    'unsupported primary schema is never downgraded to an older backup',
    () async {
      await writeSnapshot('.bak', _snapshot('old'));
      final future = {..._snapshot('new').toJson(), 'version': 2};
      await file().writeAsString(jsonEncode(future));
      await expectLater(
        store.load(),
        throwsA(isA<UnsupportedLibraryFormatException>()),
      );
      await expectLater(
        store.save(_snapshot('edit')),
        throwsA(isA<UnsupportedLibraryFormatException>()),
      );
      expect(await readJson(), future);
      expect((await readJson('.bak'))['tracks'][0]['id'], 'old');
    },
  );

  test(
    'unsupported recovery schema stays visible without resetting catalog',
    () async {
      await file('.bak').writeAsString(jsonEncode({'version': 2}));
      await expectLater(
        store.load(),
        throwsA(isA<UnsupportedLibraryFormatException>()),
      );
      expect(await file().exists(), isFalse);
    },
  );

  test(
    'unknown future enum values are not treated as disposable corruption',
    () async {
      await writeSnapshot('.bak', _snapshot('old'));
      final future = jsonDecode(
        jsonEncode(_snapshot('new').toJson()),
      ) as Map<String, dynamic>;
      future['tasks'][0]['status'] = 'futureStatus';
      await file().writeAsString(jsonEncode(future));
      await expectLater(
        store.load(),
        throwsA(isA<UnsupportedLibraryFormatException>()),
      );
      expect(await readJson(), future);
    },
  );

  test(
    'unknown queried fields refuse recovery and save without changing catalog',
    () async {
      await writeSnapshot('.bak', _snapshot('old'));
      final future = jsonDecode(
        jsonEncode(_snapshot('new').toJson()),
      ) as Map<String, dynamic>;
      future['tasks'][0]['queriedFields'] = ['lyrics', 'futureAudioField'];
      await file().writeAsString(jsonEncode(future));
      await expectLater(
        store.load(),
        throwsA(isA<UnsupportedLibraryFormatException>()),
      );
      await expectLater(
        store.save(_snapshot('edit')),
        throwsA(isA<UnsupportedLibraryFormatException>()),
      );
      expect(await readJson(), future);
      expect((await readJson('.bak'))['tracks'][0]['id'], 'old');
    },
  );

  test(
    'known queried fields persist and missing fields retain legacy defaults',
    () async {
      final data = jsonDecode(
        jsonEncode(_snapshot('queried').toJson()),
      ) as Map<String, dynamic>;
      data['tasks'][0]['queriedFields'] = ['lyrics', 'artwork'];
      await file().writeAsString(jsonEncode(data));
      final loaded = await store.load();
      expect(loaded.tasks.single.queriedFields, {
        AudioField.lyrics,
        AudioField.artwork,
      });
      await store.save(loaded);
      expect((await store.load()).tasks.single.queriedFields, {
        AudioField.lyrics,
        AudioField.artwork,
      });
      (data['tasks'][0] as Map).remove('queriedFields');
      await file().writeAsString(jsonEncode(data));
      expect((await store.load()).tasks.single.queriedFields, isEmpty);
    },
  );

  test(
    'invalid known record types recover without dropping individual records',
    () async {
      await writeSnapshot('.bak', _snapshot('safe'));
      final corrupt = jsonDecode(
        jsonEncode(_snapshot('broken').toJson()),
      ) as Map<String, dynamic>;
      corrupt['tracks'].add({'id': 'incomplete'});
      await file().writeAsString(jsonEncode(corrupt));
      final loaded = await store.load();
      expect(loaded.tracks.single.id, 'safe');
      expect(loaded.recoveredFromBackup, isTrue);
    },
  );

  test(
    'duplicate track IDs make a catalog invalid rather than losing a record',
    () async {
      final corrupt = _snapshot('duplicate').toJson();
      (corrupt['tracks'] as List).add(fixtureTrack(id: 'duplicate').toJson());
      await file().writeAsString(jsonEncode(corrupt));
      await expectLater(store.load(), throwsFormatException);
    },
  );

  test(
    'older v1 optional fields keep their defaults and tasks survive',
    () async {
      final old = jsonDecode(
        jsonEncode(_snapshot('old').toJson()),
      ) as Map<String, dynamic>;
      (old['tracks'][0] as Map).remove('localPath');
      (old['tracks'][0] as Map).remove('detailsLoaded');
      (old['tracks'][0] as Map).remove('contentUri');
      (old['tasks'][0] as Map).remove('exportedCopyUri');
      old['tasks'][0]['status'] = 'needsReview';
      await file().writeAsString(jsonEncode(old));
      final loaded = await store.load();
      expect(loaded.tracks.single.localPath, '');
      expect(loaded.tracks.single.detailsLoaded, isTrue);
      expect(loaded.tasks.single.status, TaskStatus.needsReview);
      expect(loaded.tasks.single.suggestions, hasLength(1));
      expect(loaded.tasks.single.exportedCopyUri, isNull);
    },
  );

  test(
    'compatible unknown fields survive edits at every supported record level',
    () async {
      final compatible = jsonDecode(
        jsonEncode(_snapshot('kept').toJson()),
      ) as Map<String, dynamic>;
      compatible['futureRoot'] = {
        'value': [1, '保持'],
      };
      compatible['settings']['futureSetting'] = 42;
      compatible['tracks'][0]['futureTrack'] = ['original'];
      compatible['tasks'][0]['futureTask'] = true;
      compatible['tasks'][0]['suggestions'][0]['futureSuggestion'] =
          'source detail';
      await file().writeAsString(jsonEncode(compatible));
      final loaded = await store.load();
      await store.save(
        LibrarySnapshot(
          tracks: loaded.tracks,
          tasks: loaded.tasks,
          settings: loaded.settings.copyWith(theme: AppTheme.light),
        ),
      );
      final saved = await readJson();
      expect(saved['futureRoot'], compatible['futureRoot']);
      expect(saved['settings']['futureSetting'], 42);
      expect(saved['settings']['theme'], 'light');
      expect(saved['tracks'][0]['futureTrack'], ['original']);
      expect(saved['tasks'][0]['futureTask'], isTrue);
      expect(
        saved['tasks'][0]['suggestions'][0]['futureSuggestion'],
        'source detail',
      );
      expect(saved['tasks'][0]['exportedCopyUri'], 'content://documents/kept');
    },
  );

  test(
    'unknown-field preservation does not resurrect removed tracks or tasks',
    () async {
      final compatible = jsonDecode(
        jsonEncode(_snapshot('removed').toJson()),
      ) as Map<String, dynamic>;
      compatible['tracks'][0]['futureTrack'] = 'old';
      compatible['tasks'][0]['futureTask'] = 'old';
      await file().writeAsString(jsonEncode(compatible));
      await store.save(_snapshot('replacement'));
      final saved = await readJson();
      expect(saved['tracks'], hasLength(1));
      expect(saved['tracks'][0]['id'], 'replacement');
      expect(saved['tracks'][0].containsKey('futureTrack'), isFalse);
      expect(saved['tasks'], hasLength(1));
      expect(saved['tasks'][0].containsKey('futureTask'), isFalse);
    },
  );

  test(
    'malformed root and missing required collections are explicit errors',
    () async {
      for (final value in [
        [],
        {'version': 1},
        {'version': '1', 'tracks': [], 'tasks': [], 'settings': {}},
        {...const LibrarySnapshot().toJson(), 'tasks': null},
      ]) {
        await file().writeAsString(jsonEncode(value));
        await expectLater(store.load(), throwsFormatException);
        expect(jsonDecode(await file().readAsString()), value);
      }
    },
  );
}
