import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/app_settings.dart';
import '../models/audio_track.dart';
import '../models/batch_operation.dart';
import '../models/completion_task.dart';

typedef DirectoryProvider = Future<Directory> Function();

// A newer schema is not corruption. Never replace it with an older backup.
class UnsupportedLibraryFormatException extends FormatException {
  const UnsupportedLibraryFormatException(super.message);
}

class LibrarySnapshot {
  const LibrarySnapshot({
    this.tracks = const [],
    this.tasks = const [],
    this.settings = const AppSettings(),
    this.recoveredFromBackup = false,
    this.batchOperation,
  });

  final List<AudioTrack> tracks;
  final List<CompletionTask> tasks;
  final AppSettings settings;
  final BatchOperation? batchOperation;

  // Recovery can omit recent imports. Keep this persisted across later saves
  // and restarts so callers never prune those imports as unreferenced files.
  final bool recoveredFromBackup;
  String? get recoveryNotice =>
      recoveredFromBackup ? '已恢复本地目录，最近一次更改可能未保留。原有目录和音频文件已保留，已暂停自动清理。' : null;

  Map<String, Object?> toJson() => {
    'version': 1,
    'tracks': tracks.map((track) => track.toJson()).toList(),
    'tasks': tasks.map((task) => task.toJson()).toList(),
    'settings': settings.toJson(),
    'batchOperation': batchOperation?.toJson(),
    if (recoveredFromBackup) 'recoveredFromBackup': true,
  };

  factory LibrarySnapshot.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! int) {
      throw const FormatException('本地目录版本无效');
    }
    if (version != 1) {
      throw const UnsupportedLibraryFormatException('不支持的本地目录版本，请使用兼容版本的应用');
    }
    try {
      final tracksJson = json['tracks'] as List;
      final tasksJson = json['tasks'] as List;
      final settingsJson = json['settings'] as Map<String, dynamic>;
      _checkEnum(settingsJson['theme'], AppTheme.values.map((v) => v.name));
      if (json['batchOperation'] case final Map<String, dynamic> batch) {
        _checkEnum(batch['kind'], BatchOperationKind.values.map((v) => v.name));
        for (final item in batch['items'] as List) {
          _checkEnum(
            (item as Map<String, dynamic>)['status'],
            BatchItemStatus.values.map((v) => v.name),
          );
        }
      }
      for (final item in tasksJson) {
        final task = item as Map<String, dynamic>;
        _checkEnum(task['status'], TaskStatus.values.map((v) => v.name));
        for (final field in task['queriedFields'] as List? ?? const []) {
          _checkEnum(field, AudioField.values.map((v) => v.name));
        }
        for (final item in [
          ...task['suggestions'] as List,
          ...task['approvedSuggestions'] as List? ?? const [],
        ]) {
          final suggestion = item as Map<String, dynamic>;
          _checkEnum(suggestion['field'], AudioField.values.map((v) => v.name));
        }
      }
      final tracks = tracksJson
          .map((item) => AudioTrack.fromJson(item as Map<String, dynamic>))
          .toList();
      if (tracks.map((track) => track.id).toSet().length != tracks.length) {
        throw const FormatException('本地目录中存在重复歌曲');
      }
      return LibrarySnapshot(
        tracks: tracks,
        tasks: tasksJson
            .map(
              (item) => CompletionTask.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
        settings: AppSettings.fromJson(settingsJson),
        recoveredFromBackup: json['recoveredFromBackup'] as bool? ?? false,
        batchOperation: json['batchOperation'] == null
            ? null
            : BatchOperation.fromJson(
                json['batchOperation'] as Map<String, dynamic>,
              ),
      );
    } on TypeError {
      throw const FormatException('本地目录字段不完整或类型无效');
    } on ArgumentError {
      throw const FormatException('本地目录字段无效');
    }
  }

  static void _checkEnum(Object? value, Iterable<String> supported) {
    if (value is String && !supported.contains(value)) {
      throw const UnsupportedLibraryFormatException(
        '目录包含当前应用不支持的资料，请使用兼容版本的应用',
      );
    }
  }
}

abstract interface class LibraryStore {
  Future<LibrarySnapshot> load();
  Future<void> save(LibrarySnapshot snapshot);
}

class JsonLibraryStore implements LibraryStore {
  JsonLibraryStore(this.directoryProvider);
  final DirectoryProvider directoryProvider;

  // Multiple widgets/store instances may reach the same catalog. Serialize
  // reads and writes in this isolate, not only calls on one store instance.
  static final Map<String, Future<void>> _pending = {};
  static int _archiveSequence = 0;

  Future<T> _withFile<T>(Future<T> Function(File file) operation) async {
    final directory = await directoryProvider();
    final file = File(p.join(directory.path, 'library.json'));
    final key = p.normalize(p.absolute(file.path));
    final previous = _pending[key] ?? Future<void>.value();
    final completed = Completer<void>();
    _pending[key] = completed.future;
    await previous;
    try {
      await directory.create(recursive: true);
      return await operation(file);
    } finally {
      completed.complete();
      if (identical(_pending[key], completed.future)) _pending.remove(key);
    }
  }

  @override
  Future<LibrarySnapshot> load() => _withFile((file) async {
    final document = await _loadDocument(file);
    return document == null
        ? const LibrarySnapshot()
        : LibrarySnapshot.fromJson(document);
  });

  static Map<String, dynamic> _decode(String contents) {
    final decoded = jsonDecode(contents);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('本地目录必须是对象');
    }
    LibrarySnapshot.fromJson(decoded);
    return decoded;
  }

  Future<Map<String, dynamic>?> _loadDocument(
    File file, {
    bool requireRepair = false,
  }) async {
    FormatException? failure;
    final primaryType = await FileSystemEntity.type(file.path);
    if (primaryType != FileSystemEntityType.notFound &&
        primaryType != FileSystemEntityType.file) {
      throw FileSystemException('本地目录路径不是文件', file.path);
    }
    if (await file.exists()) {
      try {
        return _decode(utf8.decode(await file.readAsBytes()));
      } on UnsupportedLibraryFormatException {
        rethrow;
      } on FormatException catch (error) {
        failure = error;
      }
    }
    // A committed backup takes precedence over an uncommitted write. A
    // complete first-ever interrupted write can still rescue an absent catalog.
    for (final suffix in ['.bak', '.bak.tmp', '.tmp']) {
      final candidate = File('${file.path}$suffix');
      if (!await candidate.exists()) continue;
      Map<String, dynamic> recovered;
      try {
        recovered = _decode(utf8.decode(await candidate.readAsBytes()));
      } on UnsupportedLibraryFormatException {
        rethrow;
      } on FormatException catch (error) {
        failure ??= error;
        continue;
      }
      recovered['recoveredFromBackup'] = true;
      // Preserve unreadable catalogs and staged data before replacing anything.
      // Only catalog files are touched; media remains entirely caller-owned.
      try {
        for (final original in [file, File('${file.path}.tmp')]) {
          if (await original.exists()) await _archive(original);
        }
        final restoring = File('${file.path}.restore.tmp');
        await restoring.writeAsString(jsonEncode(recovered), flush: true);
        await restoring.rename(file.path);
      } on FileSystemException {
        // Read-only/full storage should not prevent browsing a valid backup.
        // Saving still requires a successful repair so damaged evidence cannot
        // later be overwritten without first preserving it.
        if (requireRepair) rethrow;
      }
      return recovered;
    }
    // Incomplete/corrupt artifacts are evidence of an existing library, not a
    // fresh install. Surface the error and preserve every byte for recovery.
    if (failure != null) throw failure;
    return null;
  }

  Future<void> _archive(File file) async {
    final archive = File(
      '${file.path}.preserved-${DateTime.now().microsecondsSinceEpoch}'
      '-${_archiveSequence++}',
    );
    await archive.writeAsBytes(await file.readAsBytes(), flush: true);
  }

  @override
  Future<void> save(LibrarySnapshot snapshot) async {
    // Capture mutable lists now, rather than after waiting for another save.
    final requested = _decode(jsonEncode(snapshot.toJson()));
    return _withFile((file) async {
      final previous = await _loadDocument(file, requireRepair: true);
      final next = _preserveUnknownFields(requested, previous);
      final contents = jsonEncode(next);
      _decode(contents);
      final temporary = File('${file.path}.tmp');
      final backup = File('${file.path}.bak');
      final backupTemporary = File('${backup.path}.tmp');
      if (await temporary.exists()) await _archive(temporary);
      try {
        await temporary.writeAsString(contents, flush: true);
        if (previous != null) {
          // Prepare and atomically rotate the previous known-good catalog
          // before the commit. A failed backup must not alter the primary.
          await backupTemporary.writeAsString(
            jsonEncode(previous),
            flush: true,
          );
          await backupTemporary.rename(backup.path);
        }
        await temporary.rename(file.path); // Commit point.
      } catch (_) {
        await _removeStagingFile(temporary);
        await _removeStagingFile(backupTemporary);
        rethrow;
      }
      if (previous == null) {
        // A first successful save also gets a backup. After commit, backup I/O
        // cannot be reported as a failed save: callers might roll back media
        // which the committed catalog now references.
        try {
          await backupTemporary.writeAsString(contents, flush: true);
          await backupTemporary.rename(backup.path);
        } on FileSystemException {
          await _removeStagingFile(backupTemporary);
        }
      }
    });
  }

  Future<void> _removeStagingFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A leftover staged file is harmless while the committed primary exists.
    }
  }

  // Additive fields from a compatible v1 writer survive edits. Only merge
  // records with the same identity; deleted/replaced tracks or tasks stay gone.
  Map<String, dynamic> _preserveUnknownFields(
    Map<String, dynamic> next,
    Map<String, dynamic>? previous,
  ) {
    if (previous == null) return next;
    final oldTracks = {
      for (final item in previous['tracks'] as List)
        (item as Map<String, dynamic>)['id']: item,
    };
    final oldTasks = {
      for (final item in previous['tasks'] as List)
        _taskKey(item as Map<String, dynamic>): item,
    };
    return {
      ...previous,
      ...next,
      if (previous['recoveredFromBackup'] == true) 'recoveredFromBackup': true,
      'settings': {
        ...previous['settings'] as Map<String, dynamic>,
        ...next['settings'] as Map<String, dynamic>,
      },
      'tracks': [
        for (final item in next['tracks'] as List)
          {...?oldTracks[item['id']], ...item as Map<String, dynamic>},
      ],
      'tasks': [
        for (final item in next['tasks'] as List)
          _mergeTask(item as Map<String, dynamic>, oldTasks[_taskKey(item)]),
      ],
    };
  }

  String _taskKey(Map<String, dynamic> task) =>
      jsonEncode([task['trackId'], task['createdAt']]);

  Map<String, dynamic> _mergeTask(
    Map<String, dynamic> next,
    Map<String, dynamic>? previous,
  ) {
    if (previous == null) return next;
    String suggestionKey(Map<String, dynamic> item) => jsonEncode([
      item['field'],
      item['value'],
      item['source'],
      item['sourceUrl'],
    ]);
    final oldSuggestions = {
      for (final item in previous['suggestions'] as List)
        suggestionKey(item as Map<String, dynamic>): item,
    };
    return {
      ...previous,
      ...next,
      'suggestions': [
        for (final item in next['suggestions'] as List)
          {
            ...?oldSuggestions[suggestionKey(item as Map<String, dynamic>)],
            ...item,
          },
      ],
    };
  }
}
