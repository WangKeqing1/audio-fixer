import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_settings.dart';
import '../../core/models/audio_track.dart';
import '../../core/models/completion_task.dart';
import '../../core/services/audio_importer.dart';
import '../../core/services/completion_service.dart';
import '../../core/services/device_music_library.dart';
import '../../core/services/export/audio_copy_exporter.dart';
import '../../core/services/metadata_source.dart';
import '../../core/services/sources/json_api_client.dart';
import '../../core/storage/library_store.dart';

class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.store,
    required this.picker,
    required this.importer,
    required this.completion,
    this.deviceLibrary,
    this.exporter,
  });

  final LibraryStore store;
  final AudioPicker picker;
  final AudioImporter importer;
  final CompletionService completion;
  final DeviceMusicLibrary? deviceLibrary;
  final AudioCopyExporter? exporter;
  LibrarySnapshot _snapshot = const LibrarySnapshot();
  bool _disposed = false;
  bool isLoading = true;
  bool isBusy = false;
  String? loadError;
  String? progress;
  String? notice;
  int noticeRevision = 0;
  AudioLibraryPermission libraryPermission =
      AudioLibraryPermission.notRequested;
  String? libraryError;
  String? get recoveryNotice => _snapshot.recoveryNotice;
  bool isCompleting = false;
  bool completionStopRequested = false;
  final Map<String, String> sourceConnections = {};

  bool get usesDeviceLibrary => deviceLibrary != null;
  bool get canReadDeviceLibrary =>
      !usesDeviceLibrary || libraryPermission == AudioLibraryPermission.granted;
  List<AudioTrack> get tracks => List.unmodifiable(
    _snapshot.tracks.where(
      (track) => !track.isDeviceTrack || canReadDeviceLibrary,
    ),
  );
  List<CompletionTask> get tasks => List.unmodifiable(_snapshot.tasks);
  AppSettings get settings => _snapshot.settings;
  int get incompleteCount =>
      tracks.where((track) => track.needsCompletion).length;
  bool get canOperate => !isLoading && !isBusy && loadError == null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _announce(String message) {
    notice = message;
    noticeRevision++;
    _notify();
  }

  Future<void> initialize() async {
    if (isBusy) return;
    isBusy = true;
    isLoading = true;
    loadError = null;
    _notify();
    try {
      _snapshot = await store.load();
      await _pruneUnusedFiles();
      if (_snapshot.recoveryNotice case final message?) _announce(message);
      if (usesDeviceLibrary) await _syncDeviceLibrary(autoRequest: true);
    } catch (error, stack) {
      debugPrint('Library load failed: $error\n$stack');
      loadError = '无法读取本地目录。请检查可用空间后重试，已有目录会被保留。';
    } finally {
      isBusy = false;
      isLoading = false;
      _notify();
    }
  }

  AudioTrack? trackById(String id) {
    for (final track in tracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  Future<void> refreshLibrary() => _operate(() => _syncDeviceLibrary());

  Future<void> checkSourceConnections() => _operate(() async {
    for (final source in completion.sources) {
      if (source is! SourceConnectionTester) continue;
      progress = '正在测试 ${source.name}…';
      sourceConnections[source.name] = '测试中…';
      _notify();
      try {
        await (source as SourceConnectionTester).checkConnection().timeout(
          const Duration(seconds: 40),
        );
        sourceConnections[source.name] = '连接测试通过';
      } catch (error) {
        sourceConnections[source.name] = error is ApiException
            ? error.message
            : '连接测试失败，请检查网络后重试。';
      }
      _notify();
    }
    _announce('数据源连接测试已完成。');
  });

  void stopCompletion() {
    if (!isCompleting) return;
    completionStopRequested = true;
    progress = '正在停止，等待当前歌曲处理结束…';
    _notify();
  }

  Future<void> authorizeLibrary() => _operate(() async {
    if (libraryPermission == AudioLibraryPermission.blocked) {
      await deviceLibrary?.openSettings();
    } else {
      await _syncDeviceLibrary(requestPermission: true);
    }
  });

  Future<void> _syncDeviceLibrary({
    bool autoRequest = false,
    bool requestPermission = false,
  }) async {
    final library = deviceLibrary;
    if (library == null) return;
    libraryError = null;
    try {
      libraryPermission = await library.permissionStatus();
      if ((autoRequest &&
              libraryPermission == AudioLibraryPermission.notRequested) ||
          (requestPermission &&
              libraryPermission != AudioLibraryPermission.granted)) {
        libraryPermission = await library.requestPermission();
      }
      _notify();
      if (!canReadDeviceLibrary) return;
      progress = '正在读取系统音乐库…';
      _notify();
      final discovered = await library.querySongs();
      final cached = {for (final track in _snapshot.tracks) track.id: track};
      final changedIds = <String>{};
      final refreshed = discovered.map((track) {
        final old = cached[track.id];
        if (old != null &&
            (old.dateModifiedMs != track.dateModifiedMs ||
                old.sizeBytes != track.sizeBytes ||
                old.fileName != track.fileName ||
                old.contentUri != track.contentUri)) {
          changedIds.add(track.id);
        }
        if (old == null ||
            !old.detailsLoaded ||
            old.dateModifiedMs != track.dateModifiedMs ||
            old.sizeBytes != track.sizeBytes ||
            old.fileName != track.fileName ||
            old.contentUri != track.contentUri) {
          return track;
        }
        return track.withDetails(
          title: old.title,
          artist: old.artist,
          album: old.album,
          year: old.year,
          durationMs: old.durationMs,
          lyrics: old.lyrics,
          artworkPath: old.artworkPath,
          readError: old.readError,
        );
      }).toList();
      await _commit(
        tracks: [
          ...refreshed,
          ..._snapshot.tracks.where((track) => !track.isDeviceTrack),
        ],
        tasks: _invalidateTasks(changedIds),
      );
    } on PlatformException catch (error) {
      if (error.code == 'permission_denied') {
        libraryPermission = AudioLibraryPermission.denied;
      } else {
        libraryError = '系统音乐库读取失败，请稍后刷新重试。';
      }
      debugPrint('System music library failed: ${error.code}');
    } catch (error, stack) {
      libraryError = '音乐库刷新未完成，请检查可用空间后重试。';
      debugPrint('System music library failed: $error\n$stack');
    }
    _notify();
  }

  Future<void> readDetails(String id, {bool force = false}) =>
      _operate(() async {
        final track = trackById(id);
        if (track == null ||
            !track.isDeviceTrack ||
            !canReadDeviceLibrary ||
            (track.detailsLoaded && !force)) {
          return;
        }
        progress = '正在读取歌曲资料…';
        _notify();
        try {
          final updated = await deviceLibrary!.readDetails(track);
          final changed =
              track.title != updated.title ||
              track.artist != updated.artist ||
              track.album != updated.album ||
              track.durationMs != updated.durationMs ||
              track.lyrics != updated.lyrics ||
              track.artworkPath != updated.artworkPath ||
              updated.readError != null;
          await _commit(
            tracks: _snapshot.tracks
                .map((item) => item.id == id ? updated : item)
                .toList(),
            tasks: changed ? _invalidateTasks({id}) : null,
          );
        } on PlatformException catch (error) {
          if (error.code != 'permission_denied') rethrow;
          libraryPermission = AudioLibraryPermission.denied;
          _announce('音乐和音频访问权限已关闭，请重新授权。');
        }
      });

  Future<void> _pruneUnusedFiles() async {
    if (_snapshot.recoveredFromBackup) return;
    try {
      await importer.prune(_snapshot.tracks.map((track) => track.id).toSet());
    } catch (error, stack) {
      // Cleanup must never turn a successful catalog save into a failed action.
      debugPrint('Unused file cleanup deferred: $error\n$stack');
    }
  }

  Future<void> _commit({
    List<AudioTrack>? tracks,
    List<CompletionTask>? tasks,
    AppSettings? settings,
  }) async {
    final next = LibrarySnapshot(
      tracks: tracks ?? _snapshot.tracks,
      tasks: tasks ?? _snapshot.tasks,
      settings: settings ?? _snapshot.settings,
      recoveredFromBackup: _snapshot.recoveredFromBackup,
    );
    await store.save(next);
    _snapshot = next;
    _notify();
  }

  Future<void> _operate(Future<void> Function() action) async {
    if (!canOperate) return;
    isBusy = true;
    _notify();
    try {
      await action();
    } catch (error, stack) {
      debugPrint('Library operation failed: $error\n$stack');
      _announce('操作未完成。请检查文件访问权限和可用空间后重试。');
    } finally {
      isBusy = false;
      progress = null;
      _notify();
    }
  }

  Future<void> importAudio() => _operate(() async {
    final selected = await picker.pick();
    if (selected.isEmpty) return;
    final next = [...tracks];
    final existing = tracks.map((track) => track.id).toSet();
    var imported = 0;
    var duplicates = 0;
    var readErrors = 0;
    final failed = <String>[];
    for (var index = 0; index < selected.length; index++) {
      final selection = selected[index];
      progress = '正在导入 ${index + 1} / ${selected.length}';
      _notify();
      try {
        final track = await importer.import(selection);
        if (!existing.add(track.id)) {
          duplicates++;
          continue;
        }
        next.insert(0, track);
        imported++;
        if (track.readError != null) readErrors++;
      } catch (error, stack) {
        debugPrint('Audio import failed: $error\n$stack');
        failed.add(selection.name);
      }
    }
    try {
      if (imported > 0) await _commit(tracks: next);
    } finally {
      await _pruneUnusedFiles();
    }
    _announce(
      [
        '已导入 $imported 首',
        if (duplicates > 0) '跳过 $duplicates 个重复文件',
        if (readErrors > 0) '$readErrors 首标签读取异常，可在列表中查看',
        if (failed.isNotEmpty) '导入失败：${failed.join('、')}',
      ].join('；'),
    );
  });

  Future<void> complete({AudioTrack? track}) => _operate(() async {
    final targets = track == null
        ? tracks
              .where(
                (item) => canQueryTrack(item) && !_hasReviewableResult(item),
              )
              .toList()
        : [?trackById(track.id)];
    if (targets.isEmpty || settings.enabledFields.isEmpty) {
      _announce(
        settings.enabledFields.isEmpty
            ? '请先在设置中选择要补全的内容。'
            : '没有新的待查询歌曲，已有候选可在补全任务中确认。',
      );
      return;
    }
    isCompleting = true;
    completionStopRequested = false;
    var finished = 0;
    try {
      for (var index = 0; index < targets.length; index++) {
        if (completionStopRequested || _disposed) break;
        var item = targets[index];
        progress = '正在查询 ${index + 1} / ${targets.length}：${item.displayTitle}';
        _notify();
        CompletionTask task;
        try {
          if (item.isDeviceTrack &&
              !item.detailsLoaded &&
              completion.sources.isNotEmpty) {
            item = await deviceLibrary!.readDetails(item);
          }
          task = await completion.preview(item, settings);
        } catch (error, stack) {
          debugPrint('Completion failed: $error\n$stack');
          final permissionLost =
              error is PlatformException && error.code == 'permission_denied';
          if (permissionLost) {
            libraryPermission = AudioLibraryPermission.denied;
            completionStopRequested = true;
          }
          task = CompletionTask(
            trackId: item.id,
            trackTitle: item.displayTitle,
            createdAt: DateTime.now(),
            status: TaskStatus.failed,
            message: permissionLost
                ? '音乐访问权限已关闭，请重新授权。'
                : error is TimeoutException
                ? '数据源响应超时，请稍后重试。'
                : '查询失败，请检查网络或稍后重试。',
          );
        }
        task = CompletionTask(
          trackId: task.trackId,
          trackTitle: task.trackTitle,
          createdAt: task.createdAt,
          status: task.status,
          message: task.message,
          suggestions: task.suggestions,
          queriedFields: settings.enabledFields,
        );
        await _commit(
          tracks: _snapshot.tracks
              .map((current) => current.id == item.id ? item : current)
              .toList(),
          tasks: [
            task,
            ...tasks.where((current) => current.trackId != item.id),
          ],
        );
        finished++;
      }
      _announce(
        '${completionStopRequested ? '已停止，' : ''}已查询 $finished 首歌曲，请在「补全任务」查看结果。',
      );
    } finally {
      isCompleting = false;
      completionStopRequested = false;
    }
  });

  List<CompletionTask> _invalidateTasks(Set<String> trackIds) =>
      tasks.map((task) {
        if (!trackIds.contains(task.trackId) ||
            task.status == TaskStatus.outdated) {
          return task;
        }
        return CompletionTask(
          trackId: task.trackId,
          trackTitle: task.trackTitle,
          createdAt: task.createdAt,
          status: TaskStatus.outdated,
          message: '原文件或已读取资料已变化，请重新查询后再确认。原先导出的副本不受影响。',
          suggestions: task.suggestions,
          exportedCopyUri: task.exportedCopyUri,
          queriedFields: task.queriedFields,
        );
      }).toList();

  bool isTaskCurrent(CompletionTask task) {
    final current = taskForTrack(task.trackId);
    final track = trackById(task.trackId);
    return current != null &&
        current.createdAt == task.createdAt &&
        current.status != TaskStatus.outdated &&
        track != null &&
        track.detailsLoaded &&
        track.readError == null;
  }

  bool _hasReviewableResult(AudioTrack track) {
    final task = taskForTrack(track.id);
    return task != null &&
        isTaskCurrent(task) &&
        task.suggestions.isNotEmpty &&
        task.queriedFields.containsAll(settings.enabledFields) &&
        (task.status == TaskStatus.needsReview ||
            task.status == TaskStatus.exported);
  }

  bool canQueryTrack(AudioTrack track) =>
      track.readError == null &&
      settings.enabledFields.isNotEmpty &&
      (!track.detailsLoaded ||
          track.missingFields.intersection(settings.enabledFields).isNotEmpty);

  int get pendingCompletionCount => tracks
      .where((track) => canQueryTrack(track) && !_hasReviewableResult(track))
      .length;

  bool canExportTrack(AudioTrack track) => exporter?.supports(track) ?? false;

  CompletionTask? taskForTrack(String id) {
    for (final task in tasks) {
      if (task.trackId == id) return task;
    }
    return null;
  }

  Future<bool> exportCandidates(
    CompletionTask task,
    List<FieldSuggestion> selected,
  ) async {
    var saved = false;
    await _operate(() async {
      final track = trackById(task.trackId);
      final current = taskForTrack(task.trackId);
      if (track == null || current == null || !isTaskCurrent(task)) {
        _announce('歌曲或候选已更新，请返回重新打开结果。');
        return;
      }
      if (selected.isEmpty ||
          selected.any(
            (item) => !current.suggestions.any(
              (candidate) =>
                  candidate.field == item.field &&
                  candidate.value == item.value &&
                  candidate.source == item.source,
            ),
          )) {
        _announce('请选择当前结果中的候选资料。');
        return;
      }
      if (!canExportTrack(track)) {
        _announce('此格式暂不支持安全导出，目前支持 MP3、FLAC 和 M4A/MP4。');
        return;
      }
      progress = '正在生成并校验副本，原音频保持不变…';
      _notify();
      try {
        final uri = await exporter!.export(track, selected);
        if (uri == null) {
          _announce('已取消保存，原音频未修改。');
          return;
        }
        saved = true;
        final exported = CompletionTask(
          trackId: current.trackId,
          trackTitle: current.trackTitle,
          createdAt: current.createdAt,
          status: TaskStatus.exported,
          message: '已将所选资料写入新副本，并通过音频完整性和标签校验。原音频未修改。',
          suggestions: current.suggestions,
          exportedCopyUri: uri,
          queriedFields: current.queriedFields,
        );
        try {
          await _commit(
            tasks: tasks
                .map((item) => item.trackId == task.trackId ? exported : item)
                .toList(),
          );
          _announce('已导出校验通过的音频副本，原音频未修改。');
        } catch (_) {
          _announce('音频副本已保存，但任务记录保存失败。请在刚选择的位置查看文件。');
        }
      } on ExportException catch (error) {
        _announce(error.message);
      } on FormatException catch (error) {
        _announce('音频校验未通过：${error.message} 原音频未修改。');
      } on TimeoutException {
        _announce('封面下载超时，未导出副本。请稍后重试。');
      } on PlatformException catch (error) {
        _announce(
          error.code == 'export_cleanup_failed'
              ? '保存未完成，所选位置可能留有不完整副本，请删除该副本后重试。原音频未修改。'
              : '保存未完成。原音频未修改，请检查保存位置和可用空间后重试。',
        );
      }
    });
    return saved;
  }

  Future<void> updateSettings(AppSettings value) =>
      _operate(() => _commit(settings: value));

  @override
  void dispose() {
    completionStopRequested = true;
    _disposed = true;
    super.dispose();
  }
}
