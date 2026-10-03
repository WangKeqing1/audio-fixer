import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_settings.dart';
import '../../core/models/audio_folder.dart';
import '../../core/models/audio_track.dart';
import '../../core/models/audio_field_validation.dart';
import '../../core/models/batch_operation.dart';
import '../../core/models/completion_task.dart';
import '../../core/models/recording_candidate.dart';
import '../../core/models/source_query_report.dart';
import '../../core/services/audio_importer.dart';
import '../../core/services/artwork_picker.dart';
import '../../core/services/audio_preview_service.dart';
import '../../core/services/audio_tag_reader.dart';
import '../../core/services/completion_service.dart';
import '../../core/services/device_music_library.dart';
import '../../core/services/export/audio_copy_exporter.dart';
import '../../core/services/metadata_source.dart';
import '../../core/services/sources/json_api_client.dart';
import '../../core/services/sources/track_search.dart';
import '../../core/storage/library_store.dart';

class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.store,
    required this.picker,
    required this.importer,
    required this.completion,
    this.deviceLibrary,
    this.exporter,
    this.artworkPicker,
    AudioPreviewController? preview,
  }) : preview = preview ?? AudioPreviewController();

  final LibraryStore store;
  final AudioPicker picker;
  final AudioImporter importer;
  final CompletionService completion;
  final DeviceMusicLibrary? deviceLibrary;
  final AudioCopyExporter? exporter;
  final ArtworkPicker? artworkPicker;
  final AudioPreviewController preview;
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
  String? exportRecoveryNotice;
  OriginalRecoveryState? originalRecoveryState;
  String? get recoveryNotice {
    final notices = [?_snapshot.recoveryNotice, ?exportRecoveryNotice];
    return notices.isEmpty ? null : notices.join('\n\n');
  }

  Future<bool> _recoverExport() async {
    final recovery = exporter;
    if (recovery is! AudioExportRecovery) return true;
    try {
      await preview.withWriteLock(() async {
        exportRecoveryNotice = await (recovery as AudioExportRecovery)
            .recoverInterruptedExport();
      });
      if (recovery is AudioOriginalRecovery) {
        originalRecoveryState = await (recovery as AudioOriginalRecovery)
            .getOriginalRecoveryState();
      }
      return true;
    } catch (error) {
      originalRecoveryState = null;
      exportRecoveryNotice = '无法检查上次音频保存的恢复记录，请重新启动应用后重试。请先核对原文件，暂不进行新的写入。';
      debugPrint('Export recovery unavailable: $error');
      return false;
    }
  }

  Future<void> acknowledgeExportRecovery() => _operate(() async {
    if (originalRecoveryState != null) {
      _announce('请先处理原文件恢复事项并保留需要的版本，不能直接清除提醒。');
      return;
    }
    final recovery = exporter;
    if (recovery is! AudioExportRecovery) return;
    await (recovery as AudioExportRecovery).acknowledgeExportRecovery();
    exportRecoveryNotice = null;
    _notify();
  });
  bool get canRetryOriginalRecovery => exporter is AudioOriginalRecovery;

  Future<void> retryOriginalRecovery() => _operate(() async {
    final recovery = exporter;
    if (recovery is! AudioOriginalRecovery) return;
    progress = '正在检查权限与恢复状态，不会自动替换当前文件…';
    _notify();
    try {
      exportRecoveryNotice = await (recovery as AudioOriginalRecovery)
          .retryOriginalRecovery();
      await _recoverExport();
      await _syncDeviceLibrary();
      _announce(exportRecoveryNotice ?? '原文件恢复检查完成，请重新读取歌曲确认。');
    } on PlatformException catch (error) {
      await _recoverExport();
      _announce(error.message ?? '恢复尚未完成，备份已保留，请重新授权后重试。');
    }
  }, mutatesAudio: true);

  Future<void> restoreOriginalBackup() => _operate(() async {
    final recovery = exporter;
    if (recovery is! AudioOriginalRecovery ||
        originalRecoveryState?.canRestore != true) {
      return;
    }
    final target = originalRecoveryState!.targetUri;
    progress = '正在保留当前版本并恢复原始备份，请勿退出…';
    _notify();
    try {
      exportRecoveryNotice = await (recovery as AudioOriginalRecovery)
          .restoreOriginalBackup();
      final affected = _snapshot.tracks
          .where((track) => track.contentUri == target)
          .map((track) => track.id)
          .toSet();
      final invalidated = _invalidateTasks(affected);
      var catalogSaved = true;
      try {
        await _commit(tasks: invalidated);
      } catch (_) {
        catalogSaved = false;
        _snapshot = LibrarySnapshot(
          tracks: _snapshot.tracks,
          tasks: invalidated,
          settings: settings,
          recoveredFromBackup: _snapshot.recoveredFromBackup,
          batchOperation: batchOperation,
        );
      }
      await _recoverExport();
      await _syncDeviceLibrary();
      _announce(
        catalogSaved
            ? exportRecoveryNotice ?? '恢复已完成，请核对原文件与保留的版本。'
            : '原文件恢复步骤已完成，但目录记录保存失败。请查看恢复状态并重新读取歌曲，旧候选不能继续保存。',
      );
    } on PlatformException catch (error) {
      await _recoverExport();
      _announce(error.message ?? '恢复未完成，已有版本仍会保留。');
    }
  }, mutatesAudio: true);

  Future<void> exportOriginalRecoveryVersion(String versionId) => _operate(
    () async {
      final recovery = exporter;
      if (recovery is! AudioOriginalRecovery || originalRecoveryState == null) {
        return;
      }
      progress = '请选择保留版本的导出位置…';
      _notify();
      try {
        final uri = await (recovery as AudioOriginalRecovery)
            .exportOriginalRecoveryVersion(versionId);
        await _recoverExport();
        _announce(uri == null ? '已取消导出，恢复版本仍保留在应用中。' : '版本副本已导出并通过完整文件校验。');
      } on PlatformException catch (error) {
        await _recoverExport();
        _announce(error.message ?? '版本导出未完成，恢复版本仍保留。');
      }
    },
    mutatesAudio: true,
  );

  Future<void> finishOriginalRecovery() => _operate(() async {
    final recovery = exporter;
    if (recovery is! AudioOriginalRecovery ||
        originalRecoveryState?.canFinish != true) {
      return;
    }
    try {
      await (recovery as AudioOriginalRecovery).finishOriginalRecovery();
      await _recoverExport();
      _announce('恢复事项已处理，当前原文件保持不变。');
    } on PlatformException catch (error) {
      await _recoverExport();
      _announce(error.message ?? '暂不能完成恢复，请先导出需要保留的版本。');
    }
  }, mutatesAudio: true);

  bool isCompleting = false;
  bool completionStopRequested = false;
  final Map<String, String> sourceConnections = {};
  final Set<String> _selectedTrackIds = {};
  Set<String> get selectedTrackIds => Set.unmodifiable(
    _selectedTrackIds.intersection(tracks.map((track) => track.id).toSet()),
  );
  int get selectedCount => selectedTrackIds.length;
  BatchOperation? batchOperation;
  bool _batchStopRequested = false;
  bool _writeRecordUncertain = false;
  bool get hasRetryableBatchFailures =>
      !isBusy &&
      (batchOperation?.items.any(
            (item) =>
                item.status == BatchItemStatus.failed &&
                trackById(item.trackId) != null,
          ) ??
          false);

  void toggleTrackSelection(String id) {
    if (!canOperate || trackById(id) == null) return;
    if (!_selectedTrackIds.add(id)) _selectedTrackIds.remove(id);
    _notify();
  }

  void selectTracks(Iterable<String> ids) {
    if (!canOperate) return;
    _selectedTrackIds.addAll(ids.where((id) => trackById(id) != null));
    _notify();
  }

  void retainSelection(Iterable<String> allowedIds) {
    // Removing hidden choices is safe even while a batch owns its frozen scope.
    // Never let a search changed during work revive selections for a later batch.
    final allowed = allowedIds.toSet();
    final before = _selectedTrackIds.length;
    _selectedTrackIds.removeWhere((id) => !allowed.contains(id));
    if (_selectedTrackIds.length != before) _notify();
  }

  void clearSelection() {
    if (!canOperate) return;
    _selectedTrackIds.clear();
    _notify();
  }

  void stopBatch() {
    if (!(batchOperation?.isRunning ?? false)) return;
    _batchStopRequested = true;
    completionStopRequested = true;
    batchOperation = batchOperation!.copyWith(stopRequested: true);
    progress = '正在停止，当前歌曲完成安全处理后将停止…';
    _notify();
  }

  Future<void> _startBatch(
    BatchOperationKind kind,
    List<AudioTrack> targets,
  ) async {
    _batchStopRequested = false;
    completionStopRequested = false;
    _writeRecordUncertain = false;
    batchOperation = BatchOperation(
      kind: kind,
      items: targets
          .map(
            (track) => BatchItemResult(
              trackId: track.id,
              trackTitle: track.displayTitle,
            ),
          )
          .toList(),
    );
    await _commit();
  }

  void _setBatchItem(String id, BatchItemStatus status, String message) {
    final batch = batchOperation;
    if (batch == null) return;
    batchOperation = batch.copyWith(
      items: batch.items
          .map(
            (item) =>
                item.trackId == id ? item.withResult(status, message) : item,
          )
          .toList(),
    );
    _notify();
  }

  Future<void> _finishBatch() async {
    final batch = batchOperation;
    if (batch == null) return;
    batchOperation = batch.copyWith(
      isRunning: false,
      items: batch.items
          .map(
            (item) => item.isFinished
                ? item
                : item.withResult(BatchItemStatus.cancelled, '未处理；可以重新选择后继续。'),
          )
          .toList(),
    );
    try {
      await _commit();
    } catch (error) {
      _announce('批量记录保存失败，请核对已完成的文件与恢复提醒后再操作。');
      rethrow;
    } finally {
      isCompleting = false;
      completionStopRequested = false;
      _notify();
    }
  }

  Future<void> retryFailedBatch() async {
    if (!canOperate || batchOperation == null) return;
    final failed = batchOperation!.items
        .where(
          (item) =>
              item.status == BatchItemStatus.failed &&
              trackById(item.trackId) != null,
        )
        .map((item) => item.trackId)
        .toSet();
    if (failed.isEmpty) return;
    if (batchOperation!.kind == BatchOperationKind.identify) {
      final repairTask = failed.length == 1
          ? taskForTrack(failed.single)
          : null;
      if (repairTask != null &&
          (repairTask.isRepair || repairTask.confirmedRecording != null)) {
        await retryTaskQuery(repairTask);
      } else {
        await complete(trackIds: failed);
      }
    } else {
      await _saveBatch(
        failed,
        exportCopies: batchOperation!.kind == BatchOperationKind.exportCopies,
      );
    }
  }

  bool get usesDeviceLibrary => deviceLibrary != null;
  bool get canReadDeviceLibrary =>
      !usesDeviceLibrary || libraryPermission == AudioLibraryPermission.granted;
  List<AudioTrack> get allTracks => List.unmodifiable(
    _snapshot.tracks.where(
      (track) => !track.isDeviceTrack || canReadDeviceLibrary,
    ),
  );
  List<AudioTrack> get tracks =>
      List.unmodifiable(allTracks.where((track) => !isTrackExcluded(track)));
  bool isTrackExcluded(AudioTrack track) => settings.excludes(track);
  int get excludedTrackCount => allTracks.where(isTrackExcluded).length;
  int get unknownDurationCount =>
      tracks.where((track) => !track.hasKnownDuration).length;
  int get unknownFolderCount =>
      allTracks.where((track) => track.folder == null).length;
  List<AudioFolder> get folderChoices {
    final folders = <AudioFolder>{...settings.excludedFolders};
    for (final track in allTracks) {
      folders.addAll(track.folder?.ancestors ?? const <AudioFolder>[]);
    }
    for (final folder in settings.excludedFolders) {
      folders.addAll(folder.ancestors);
    }
    final sorted = folders.toList()
      ..sort((a, b) {
        final volumeOrder = a.volumeName.compareTo(b.volumeName);
        return volumeOrder == 0
            ? a.normalizedPath.compareTo(b.normalizedPath)
            : volumeOrder;
      });
    return List.unmodifiable(sorted);
  }

  List<CompletionTask> get tasks => List.unmodifiable(_snapshot.tasks);
  AppSettings get settings => _snapshot.settings;
  int get incompleteCount =>
      tracks.where((track) => track.needsCompletion).length;
  bool get canOperate => !isLoading && !isBusy && loadError == null;

  void _pruneSelection() {
    final eligibleIds = tracks.map((track) => track.id).toSet();
    _selectedTrackIds.removeWhere((id) => !eligibleIds.contains(id));
  }

  void _notify() {
    _pruneSelection();
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
      await _recoverExport();
      _snapshot = await store.load();
      batchOperation = _snapshot.batchOperation;
      if (batchOperation?.isRunning ?? false) {
        final uncertainIds =
            batchOperation!.kind == BatchOperationKind.saveOriginal
            ? batchOperation!.items
                  .where((item) => item.status == BatchItemStatus.running)
                  .map((item) => item.trackId)
                  .toSet()
            : <String>{};
        batchOperation = batchOperation!.recoverInterrupted();
        await _commit(tasks: _invalidateTasks(uncertainIds));
      }
      await _pruneUnusedFiles();
      if (recoveryNotice case final message?) {
        _announce(
          exportRecoveryNotice == null ? message : '上次音频保存有恢复提醒，请查看说明。',
        );
      }
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

  Future<void> refreshLibrary() => _operate(() async {
    // A recreated Activity can receive the old system picker result after the
    // initial recovery probe. Resume/refresh observes its durable notice too.
    await _recoverExport();
    await _syncDeviceLibrary();
  });

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
    if (isCompleting) stopBatch();
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
      final refreshed = discovered.map((discoveredTrack) {
        final track = discoveredTrack.withInstrumental(
          cached[discoveredTrack.id]?.isInstrumental ?? false,
        );
        final old = cached[track.id];
        if (old != null &&
            (old.dateModifiedMs != track.dateModifiedMs ||
                old.sizeBytes != track.sizeBytes ||
                old.fileName != track.fileName ||
                old.contentUri != track.contentUri ||
                old.folder != track.folder ||
                old.indexedDurationMs != track.indexedDurationMs)) {
          changedIds.add(track.id);
        }
        if (old == null ||
            !old.detailsLoaded ||
            old.dateModifiedMs != track.dateModifiedMs ||
            old.sizeBytes != track.sizeBytes ||
            old.fileName != track.fileName ||
            old.contentUri != track.contentUri ||
            old.folder != track.folder ||
            old.indexedDurationMs != track.indexedDurationMs) {
          return track;
        }
        return AudioTrack.fromJson({
          ...old.toJson(),
          'fileName': track.fileName,
          'sizeBytes': track.sizeBytes,
          'contentUri': track.contentUri,
          'dateModifiedMs': track.dateModifiedMs,
          'volumeName': track.volumeName,
          'relativePath': track.relativePath,
          'indexedDurationMs': track.indexedDurationMs,
        });
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

  bool canRereadTrack(AudioTrack track) => track.isDeviceTrack
      ? deviceLibrary != null && canReadDeviceLibrary
      : importer is AudioDetailsImporter;

  Future<AudioTrack> _readCurrentTrackDetails(AudioTrack track) async {
    final AudioTrack updated;
    if (track.isDeviceTrack && deviceLibrary != null) {
      updated = await deviceLibrary!.readDetails(track);
    } else if (importer is AudioDetailsImporter) {
      updated = await (importer as AudioDetailsImporter).readDetails(track);
    } else {
      return track.withReadError('此音频来源暂不能重新读取标签，请从系统音乐库重新选择。');
    }
    return updated.withInstrumental(track.isInstrumental);
  }

  Future<void> readDetails(String id, {bool force = false}) =>
      _operate(() async {
        final track = trackById(id);
        if (track == null ||
            !canRereadTrack(track) ||
            (track.detailsLoaded && !track.requiresTagRefresh && !force)) {
          return;
        }
        progress = '正在读取歌曲资料…';
        _notify();
        try {
          final updated = await _readCurrentTrackDetails(track);
          final changed = _tagSnapshotChanged(track, updated);
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

  /// This local annotation does not write tags or imply approval of candidates.
  /// The normal operation lock serializes it with lookup, refresh and saving.
  Future<bool> setTrackInstrumental(String id, bool value) async {
    var saved = false;
    await _operate(() async {
      final track = trackById(id);
      if (track == null ||
          (value && (!track.detailsLoaded || track.readError != null))) {
        return;
      }
      if (track.isInstrumental == value) {
        saved = true;
        return;
      }
      final updated = track.withInstrumental(value);
      final revisedTasks = tasks.map((task) {
        if (task.trackId != id ||
            task.status == TaskStatus.savedOriginal ||
            task.status == TaskStatus.outdated) {
          return task;
        }
        final suggestions = task.suggestions
            .where((item) => item.field != AudioField.lyrics)
            .toList();
        final approved = task.approvedSuggestions
            .where((item) => item.field != AudioField.lyrics)
            .toList();
        final remaining = updated.missingFields.intersection(
          settings.enabledFields,
        );
        final status = task.status == TaskStatus.exported
            ? TaskStatus.exported
            : approved.isNotEmpty
            ? TaskStatus.readyToSave
            : suggestions.isNotEmpty || task.needsRecordingChoice
            ? TaskStatus.needsReview
            : remaining.isEmpty
            ? TaskStatus.skipped
            : task.status == TaskStatus.failed
            ? TaskStatus.failed
            : TaskStatus.noMatch;
        final now = DateTime.now();
        final reviewNotice = approved.isNotEmpty
            ? '其余已确认资料保留，可继续保存；未确认候选仍需逐项审核。'
            : suggestions.isNotEmpty
            ? '其余候选仍需逐项确认后保存。'
            : '';
        return CompletionTask(
          trackId: task.trackId,
          trackTitle: task.trackTitle,
          // Open review/translation flows must not apply an older lyric
          // selection after this explicit change, including after undo.
          createdAt: now.isAfter(task.createdAt)
              ? now
              : task.createdAt.add(const Duration(microseconds: 1)),
          status: status,
          message: !value
              ? '已取消纯音乐标记，缺失歌词可以重新查询。${task.status == TaskStatus.exported ? '原先导出的副本不受影响。' : reviewNotice}'
              : task.status == TaskStatus.exported
              ? '已导出过副本。现已在本应用设为纯音乐，跳过歌词；原先导出的副本不受影响。'
              : suggestions.isNotEmpty
              ? '已在本应用设为纯音乐，跳过歌词。$reviewNotice'
              : remaining.isEmpty
              ? '已在本应用设为纯音乐，本次查询无需补全歌词。'
              : '已在本应用设为纯音乐，跳过歌词。${remaining.map((field) => field.label).join('、')}仍待补全，可重新查询。',
          suggestions: suggestions,
          approvedSuggestions: approved,
          queriedFields: task.queriedFields.difference({AudioField.lyrics}),
          isRepair: task.isRepair,
          searchMetadata: task.searchMetadata,
          recordingCandidates: task.recordingCandidates,
          sourceReports: task.sourceReports,
          confirmedRecording: task.confirmedRecording,
          exportedCopyUri: task.exportedCopyUri,
          writeError: task.writeError,
        );
      }).toList();
      await _commit(
        tracks: _snapshot.tracks
            .map((item) => item.id == id ? updated : item)
            .toList(),
        tasks: revisedTasks,
      );
      saved = true;
      _announce(
        value
            ? '已在本应用设为纯音乐，将跳过歌词查询与翻译。音频文件和已有歌词不变。'
            : '已取消纯音乐标记，缺失歌词可以重新查询。音频文件不变。',
      );
    });
    return saved;
  }

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
      batchOperation: batchOperation,
    );
    await store.save(next);
    _snapshot = next;
    _pruneSelection();
    _notify();
  }

  Future<void> _operate(
    Future<void> Function() action, {
    bool mutatesAudio = false,
  }) async {
    if (!canOperate) return;
    isBusy = true;
    _notify();
    try {
      if (mutatesAudio) {
        await preview.withWriteLock(action);
      } else {
        await action();
      }
    } catch (error, stack) {
      debugPrint('Library operation failed: $error\n$stack');
      _announce(
        error is AudioPreviewException
            ? error.message
            : error is ArtworkException
            ? error.message
            : '操作未完成。请检查文件访问权限和可用空间后重试。',
      );
    } finally {
      isBusy = false;
      progress = null;
      _notify();
    }
  }

  Future<void> importAudio() => _operate(() async {
    final selected = await picker.pick();
    if (selected.isEmpty) return;
    final next = [..._snapshot.tracks];
    final existing = _snapshot.tracks.map((track) => track.id).toSet();
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

  bool get _hasLibraryExclusions =>
      settings.excludeShortAudio || settings.excludedFolders.isNotEmpty;

  // Revalidate the native metadata while filters are active. A stale folder or
  // duration must not become an online query/write simply because it was once
  // selected. A failed refresh is not permission to act on old metadata.
  Future<bool> _refreshForExclusions({Iterable<String>? trackIds}) async {
    if (!_hasLibraryExclusions || !usesDeviceLibrary) return true;
    final requestedIds = trackIds?.toSet();
    if (!_snapshot.tracks.any(
      (track) =>
          track.isDeviceTrack &&
          (requestedIds == null || requestedIds.contains(track.id)),
    )) {
      return true;
    }
    await _syncDeviceLibrary();
    if (!canReadDeviceLibrary || libraryError != null) {
      _announce('无法重新确认排除条件，请恢复音乐库访问并刷新后重试。');
      return false;
    }
    return true;
  }

  bool _tagSnapshotChanged(AudioTrack before, AudioTrack after) =>
      AudioField.values.any(
        (field) => before.valueOf(field) != after.valueOf(field),
      ) ||
      before.artworkSha256 != after.artworkSha256 ||
      before.durationMs != after.durationMs ||
      after.readError != null;

  Future<String?> pickArtwork() async {
    String? value;
    await _operate(() async {
      if (artworkPicker == null) {
        _announce('当前环境不支持选择封面，请在安卓应用中选择 JPEG 或 PNG 图片。');
        return;
      }
      value = await artworkPicker!.pickArtwork();
    });
    return value;
  }

  /// The inventory reads many originals. Keep save, refresh and preview work
  /// from racing that snapshot; the report itself never edits audio files.
  Future<T?> runInventoryOperation<T>(Future<T> Function() action) async {
    T? result;
    await _operate(() async {
      result = await action();
    }, mutatesAudio: true);
    return result;
  }

  Future<CompletionTask?> createManualRepair(
    String trackId,
    Map<AudioField, String> values,
  ) async {
    CompletionTask? draft;
    await _operate(() async {
      final track = trackById(trackId);
      if (track == null ||
          !track.detailsLoaded ||
          track.requiresTagRefresh ||
          track.readError != null ||
          !canExportTrack(track)) {
        _announce('请先读取可安全编辑的歌曲资料；目前支持 MP3、FLAC 和 M4A/MP4。');
        return;
      }
      final normalized = <AudioField, String>{
        for (final entry in values.entries)
          entry.key:
              entry.key.isNumeric && int.tryParse(entry.value.trim()) != null
              ? int.parse(entry.value.trim()).toString()
              : entry.value,
      };
      final changes = <AudioField, String>{
        for (final entry in normalized.entries)
          if (hasText(entry.value) && entry.value != track.valueOf(entry.key))
            entry.key: entry.value,
      };
      if (track.isInstrumental && changes.containsKey(AudioField.lyrics)) {
        _announce('请先取消纯音乐标记，再编辑歌词。');
        return;
      }
      final error = validateAudioFieldChanges(track, changes);
      if (error != null || changes.isEmpty) {
        _announce(error ?? '尚未选择有变化的资料，原标签未修改。');
        return;
      }
      final previous = taskForTrack(trackId)?.createdAt;
      final now = DateTime.now();
      draft = CompletionTask(
        trackId: trackId,
        trackTitle: track.displayTitle,
        createdAt: previous != null && !now.isAfter(previous)
            ? previous.add(const Duration(microseconds: 1))
            : now,
        status: TaskStatus.needsReview,
        message: '手动编辑尚未写入，请逐项核对原值和新值，再保存到原文件或导出副本。',
        suggestions: changes.entries
            .map(
              (entry) => FieldSuggestion(
                field: entry.key,
                value: entry.value,
                source: '手动编辑',
                matchDescription: '由你手动选择或输入，尚未写入音频。',
                replaceExisting: hasText(track.valueOf(entry.key)),
              ),
            )
            .toList(),
        queriedFields: changes.keys.toSet(),
        isRepair: true,
      );
      await _commit(
        tasks: [draft!, ...tasks.where((task) => task.trackId != trackId)],
      );
      _announce('已生成 ${changes.length} 项修改草稿，尚未修改音频。');
    });
    return draft != null && taskForTrack(trackId)?.createdAt == draft!.createdAt
        ? draft
        : null;
  }

  /// Explicit automatic repair includes existing values and all fields the
  /// installed sources actually support. Nothing is approved or written here.
  Future<void> queryAutomaticRepair({
    AudioTrack? track,
    Set<String>? trackIds,
  }) => complete(
    track: track,
    trackIds: trackIds,
    repairFields: completion.availableFields,
  );

  Future<void> queryRepair(
    String trackId, {
    required Set<AudioField> fields,
    String? searchTitle,
    String? searchArtist,
    String? searchAlbum,
  }) async {
    final track = trackById(trackId);
    if (track == null || fields.isEmpty) return;
    final search = <String, String>{
      if (searchTitle != null) 'title': searchTitle.trim(),
      if (searchArtist != null) 'artist': searchArtist.trim(),
      if (searchAlbum != null) 'album': searchAlbum.trim(),
    };
    if (search.values.any(
      (value) => value.length > 4096 || value.contains('\x00'),
    )) {
      _announce('检索资料过长或含无效字符，请修改后重试。');
      return;
    }
    await complete(
      track: track,
      repairFields: Set.unmodifiable(fields),
      searchMetadata: search,
    );
  }

  bool get canDiscoverRecordings =>
      completion.sources.any((source) => source is RecordingDiscoverySource);

  /// A user-requested fallback: ignore an uncertain artist only for candidate
  /// discovery. Preserve actual tags and require an explicit recording choice.
  Future<void> discoverAlternativeRecordings(String trackId) async {
    final track = trackById(trackId);
    if (track == null ||
        !canOperate ||
        !canDiscoverRecordings ||
        !track.detailsLoaded ||
        track.requiresTagRefresh ||
        track.readError != null ||
        isTrackExcluded(track)) {
      return;
    }
    final search = TrackSearch.fromTrack(track);
    await queryRepair(
      trackId,
      fields: completion.availableFields,
      searchTitle: search.title,
      searchArtist: '',
      searchAlbum: search.album,
    );
  }

  Future<CompletionTask?> confirmRecordingChoice(
    CompletionTask task,
    RecordingCandidate candidate,
  ) async {
    final current = taskForTrack(task.trackId);
    if (!canOperate ||
        current == null ||
        !isTaskCurrent(task) ||
        !current.needsRecordingChoice ||
        !current.recordingCandidates.any((item) => item.sameAs(candidate))) {
      _announce('歌曲或版本候选已变化，请重新检索后选择。');
      return null;
    }
    final track = trackById(task.trackId)!;
    await complete(
      track: track,
      repairFields: current.isRepair ? current.queriedFields : null,
      searchMetadata: current.searchMetadata,
      confirmedRecording: candidate,
      recordingTask: current,
    );
    final updated = taskForTrack(task.trackId);
    return updated != null && updated.createdAt != task.createdAt
        ? updated
        : null;
  }

  /// Re-query a reviewed recording by its selected provider ID. A translation
  /// retry must not silently switch to a similarly named edition.
  Future<void> retryTaskQuery(CompletionTask task) async {
    final current = taskForTrack(task.trackId);
    final track = trackById(task.trackId);
    if (!canOperate ||
        current == null ||
        track == null ||
        current.createdAt != task.createdAt) {
      return;
    }
    if (current.confirmedRecording != null) {
      if (!isTaskCurrent(task)) {
        _announce('旧版本选择已清除，正在根据当前歌曲资料重新检索。');
        await complete(
          track: track,
          repairFields: current.isRepair ? current.queriedFields : null,
        );
        return;
      }
      await complete(
        track: track,
        repairFields: current.isRepair ? current.queriedFields : null,
        searchMetadata: current.searchMetadata,
        confirmedRecording: current.confirmedRecording,
        recordingTask: current,
      );
    } else if (current.isRepair) {
      await queryRepair(
        track.id,
        fields: current.queriedFields,
        searchTitle: current.searchMetadata['title'],
        searchArtist: current.searchMetadata['artist'],
        searchAlbum: current.searchMetadata['album'],
      );
    } else {
      await complete(track: track);
    }
  }

  Future<void> complete({
    AudioTrack? track,
    Set<String>? trackIds,
    Set<AudioField>? repairFields,
    Map<String, String> searchMetadata = const {},
    RecordingCandidate? confirmedRecording,
    CompletionTask? recordingTask,
  }) => _operate(() async {
    if (confirmedRecording != null &&
        (track == null ||
            recordingTask == null ||
            recordingTask.trackId != track.id ||
            !isTaskCurrent(recordingTask) ||
            !((taskForTrack(track.id)?.confirmedRecording
                        ?.sameAs(confirmedRecording) ??
                    false) ||
                (taskForTrack(track.id)?.recordingCandidates
                        .any((item) => item.sameAs(confirmedRecording)) ??
                    false)))) {
      _announce('版本选择已失效，请重新检索。');
      return;
    }
    if (!await _refreshForExclusions(
      trackIds: track != null ? [track.id] : trackIds,
    )) {
      return;
    }
    final targets = track != null
        ? [?trackById(track.id)]
        : trackIds != null
        ? tracks.where((item) => trackIds.contains(item.id)).toList()
        : repairFields != null
        ? tracks.toList()
        : tracks
              .where(
                (item) => canQueryTrack(item) && !_hasReviewableResult(item),
              )
              .toList();
    if (targets.isEmpty || (repairFields ?? settings.enabledFields).isEmpty) {
      _announce(
        (repairFields ?? settings.enabledFields).isEmpty
            ? repairFields != null
                  ? '没有可用的在线来源，请在设置中查看来源状态。已有资料保留，可使用手动编辑。'
                  : '请先在设置中选择要补全的内容。'
            : '没有新的待查询歌曲，已有候选可在补全任务中确认。',
      );
      return;
    }
    await _startBatch(BatchOperationKind.identify, targets);
    isCompleting = true;
    var finished = 0;
    try {
      for (var index = 0; index < targets.length; index++) {
        if (_batchStopRequested || _disposed) break;
        var item = targets[index];
        if (item.isDeviceTrack &&
            !await _refreshForExclusions(trackIds: [item.id])) {
          _batchStopRequested = true;
          break;
        }
        final eligible = trackById(item.id);
        if (eligible == null || isTrackExcluded(eligible)) {
          _setBatchItem(item.id, BatchItemStatus.skipped, '已被音乐库排除条件过滤，未查询。');
          await _commit();
          continue;
        }
        item = eligible;
        progress = '正在查询 ${index + 1} / ${targets.length}：${item.displayTitle}';
        _setBatchItem(item.id, BatchItemStatus.running, '正在检查和查询');
        await _commit();
        CompletionTask task;
        try {
          if ((!item.detailsLoaded ||
                  item.readError != null ||
                  item.requiresTagRefresh) &&
              (completion.sources.isNotEmpty || repairFields != null) &&
              canRereadTrack(item)) {
            item = await _readCurrentTrackDetails(item);
          }
          if (item.requiresTagRefresh) {
            throw StateError('请先重新读取歌曲标签后再查询修复资料。');
          }
          if (isTrackExcluded(item)) {
            _setBatchItem(item.id, BatchItemStatus.skipped, '读取后符合排除条件，未查询。');
            await _commit(
              tracks: _snapshot.tracks
                  .map((current) => current.id == item.id ? item : current)
                  .toList(),
              tasks: _invalidateTasks({item.id}),
            );
            continue;
          }
          if (item.readError != null) throw StateError(item.readError!);
          final searchTrack = searchMetadata.isEmpty
              ? null
              : AudioTrack.fromJson({
                  ...item.toJson(),
                  if (searchMetadata.containsKey('title'))
                    'title': searchMetadata['title'],
                  if (searchMetadata.containsKey('artist'))
                    'artist': searchMetadata['artist'],
                  if (searchMetadata.containsKey('album'))
                    'album': searchMetadata['album'],
                });
          if (confirmedRecording != null &&
              (!isTaskCurrent(recordingTask!) ||
                  _tagSnapshotChanged(eligible, item))) {
            _setBatchItem(
              item.id,
              BatchItemStatus.skipped,
              '歌曲资料已变化，请重新检索并选择版本。',
            );
            await _commit(
              tracks: _snapshot.tracks
                  .map((current) => current.id == item.id ? item : current)
                  .toList(),
              tasks: _invalidateTasks({item.id}),
            );
            continue;
          }
          final requested =
              (repairFields ??
                      item.missingFields.intersection(settings.enabledFields))
                  .difference(item.isInstrumental ? {AudioField.lyrics} : {});
          final queryTrack = searchTrack ?? item;
          if (confirmedRecording == null &&
              requested.isNotEmpty &&
              !hasText(TrackSearch.fromTrack(queryTrack).artist) &&
              completion.sources.any(
                (source) => source is RecordingDiscoverySource,
              )) {
            final discovered = await completion.discoverRecordings(queryTrack);
            task = CompletionTask(
              trackId: item.id,
              trackTitle: item.displayTitle,
              createdAt: DateTime.now(),
              status: discovered.candidates.isNotEmpty
                  ? TaskStatus.needsReview
                  : discovered.hasFailures
                  ? TaskStatus.failed
                  : TaskStatus.noMatch,
              message: [
                discovered.candidates.isNotEmpty
                    ? '已找到 ${discovered.candidates.length} 个可能的歌曲版本。${hasText(item.artist) && searchMetadata.containsKey('artist') ? '本次未用原歌手标签筛选，' : '缺少歌手标签，'}请先选择正确的歌手和专辑，再获取该版本的资料；尚未选择或修改任何字段。'
                    : '仅按歌名与时长检索，尚未找到可供确认的歌曲版本。可以调整检索条件后重试。',
                ...discovered.diagnostics,
              ].join('\n'),
              recordingCandidates: discovered.candidates,
              sourceReports: discovered.sourceReports,
            );
          } else {
            task = await completion.preview(
              item,
              settings,
              requestedFields: repairFields,
              searchTrack: searchTrack,
              confirmedRecording: confirmedRecording,
            );
            // A strict lookup can reject two plausible editions. Offer a
            // bounded recording choice without dropping known artist evidence.
            // Never replace usable fields, retry a failed provider here, or
            // change an already selected recording identity.
            final discoveryNames = completion.sources
                .whereType<RecordingDiscoverySource>()
                .map((source) => source.name)
                .toSet();
            final unmatchedDiscoveryNames = task.sourceReports
                .where(
                  (report) =>
                      discoveryNames.contains(report.sourceName) &&
                      report.outcome == SourceQueryOutcome.noMatch,
                )
                .map((report) => report.sourceName)
                .toSet();
            if (confirmedRecording == null &&
                requested.isNotEmpty &&
                task.suggestions.isEmpty &&
                hasText(TrackSearch.fromTrack(queryTrack).artist) &&
                unmatchedDiscoveryNames.isNotEmpty) {
              final discovered = await completion.discoverRecordings(
                queryTrack,
                sourceNames: unmatchedDiscoveryNames,
              );
              final reports = [
                ...task.sourceReports.where(
                  (report) =>
                      !unmatchedDiscoveryNames.contains(report.sourceName),
                ),
                ...discovered.sourceReports.where(
                  (report) =>
                      unmatchedDiscoveryNames.contains(report.sourceName),
                ),
              ];
              task = CompletionTask(
                trackId: item.id,
                trackTitle: item.displayTitle,
                createdAt: DateTime.now(),
                status: discovered.candidates.isNotEmpty
                    ? TaskStatus.needsReview
                    : reports.any(
                        (report) =>
                            report.outcome == SourceQueryOutcome.failed ||
                            report.outcome == SourceQueryOutcome.partial,
                      )
                    ? TaskStatus.failed
                    : TaskStatus.noMatch,
                message: discovered.candidates.isNotEmpty
                    ? '找到 ${discovered.candidates.length} 个可能的录音版本，已有歌手仍参与核对。请确认歌手、专辑与时长，再获取该版本资料；尚未选择或修改任何字段。'
                    : '未找到可直接采用的资料或可确认的录音版本，请查看各来源结果，也可调整检索条件。已有资料保留。',
                recordingCandidates: discovered.candidates,
                sourceReports: reports,
              );
            }
          }
          if (repairFields != null) {
            final candidates = task.suggestions
                .where(
                  (candidate) =>
                      candidate.field == AudioField.artwork ||
                      candidate.value != item.valueOf(candidate.field),
                )
                .map(
                  (candidate) => candidate.withReplacement(
                    hasText(item.valueOf(candidate.field)),
                  ),
                )
                .toList();
            final allUnchanged =
                task.suggestions.isNotEmpty && candidates.isEmpty;
            task = CompletionTask(
              trackId: task.trackId,
              trackTitle: task.trackTitle,
              createdAt: task.createdAt,
              status: allUnchanged ? TaskStatus.skipped : task.status,
              message: allUnchanged
                  ? '已检索到的所选资料与当前标签一致，无需替换。${task.message.replaceFirst('已找到候选信息，尚未写入音频。', '').trim()}'
                  : task.message,
              suggestions: candidates,
              recordingCandidates: task.recordingCandidates,
              sourceReports: task.sourceReports,
              confirmedRecording: confirmedRecording,
            );
          }
        } catch (error, stack) {
          debugPrint('Completion failed: $error\n$stack');
          final permissionLost =
              error is PlatformException && error.code == 'permission_denied';
          if (permissionLost) {
            libraryPermission = AudioLibraryPermission.denied;
            stopBatch();
          }
          task = CompletionTask(
            trackId: item.id,
            trackTitle: item.displayTitle,
            createdAt: DateTime.now(),
            status: TaskStatus.failed,
            message: permissionLost
                ? '音乐访问权限已关闭，请重新授权。'
                : item.readError ??
                      (error is TimeoutException
                          ? '数据源响应超时，请稍后重试。'
                          : '查询失败，请检查网络或稍后重试。'),
          );
        }
        task = CompletionTask(
          trackId: task.trackId,
          trackTitle: task.trackTitle,
          createdAt: task.createdAt,
          status: task.status,
          message: task.message,
          suggestions: task.suggestions,
          recordingCandidates: task.recordingCandidates,
          sourceReports: task.sourceReports,
          confirmedRecording: confirmedRecording,
          queriedFields: repairFields == null
              ? _enabledFieldsFor(item)
              : repairFields.difference(
                  item.isInstrumental ? {AudioField.lyrics} : {},
                ),
          isRepair: repairFields != null,
          searchMetadata: Map.unmodifiable(searchMetadata),
        );
        _setBatchItem(
          item.id,
          task.status == TaskStatus.failed
              ? BatchItemStatus.failed
              : task.suggestions.isNotEmpty || task.needsRecordingChoice
              ? BatchItemStatus.needsReview
              : BatchItemStatus.skipped,
          task.message,
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
    } finally {
      await _finishBatch();
    }
    _announce(
      '${_batchStopRequested ? '已停止，' : ''}已查询 $finished 首歌曲，请在「补全任务」查看结果。 ${batchOperation!.summary}',
    );
  });

  List<CompletionTask> _invalidateTasks(Set<String> trackIds) =>
      tasks.map((task) {
        if (!trackIds.contains(task.trackId) ||
            task.status == TaskStatus.outdated ||
            task.status == TaskStatus.savedOriginal) {
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
          isRepair: task.isRepair,
          searchMetadata: task.searchMetadata,
          recordingCandidates: task.recordingCandidates,
          sourceReports: task.sourceReports,
          confirmedRecording: task.confirmedRecording,
        );
      }).toList();

  bool isTaskCurrent(CompletionTask task) {
    final current = taskForTrack(task.trackId);
    final track = trackById(task.trackId);
    return current != null &&
        current.createdAt == task.createdAt &&
        current.status != TaskStatus.outdated &&
        current.status != TaskStatus.savedOriginal &&
        track != null &&
        track.detailsLoaded &&
        !track.requiresTagRefresh &&
        track.readError == null;
  }

  bool _hasReviewableResult(AudioTrack track) {
    final task = taskForTrack(track.id);
    return task != null &&
        isTaskCurrent(task) &&
        (task.suggestions.isNotEmpty || task.needsRecordingChoice) &&
        task.queriedFields.containsAll(_enabledFieldsFor(track)) &&
        (task.status == TaskStatus.needsReview ||
            task.status == TaskStatus.readyToSave ||
            task.status == TaskStatus.exported);
  }

  Set<AudioField> _enabledFieldsFor(AudioTrack track) => settings.enabledFields
      .where((field) => !(track.isInstrumental && field == AudioField.lyrics))
      .toSet();

  bool canQueryTrack(AudioTrack track) =>
      !isTrackExcluded(track) &&
      track.readError == null &&
      settings.enabledFields.isNotEmpty &&
      (!track.detailsLoaded ||
          track.missingFields.intersection(settings.enabledFields).isNotEmpty);

  int get pendingCompletionCount => tracks
      .where((track) => canQueryTrack(track) && !_hasReviewableResult(track))
      .length;

  bool canExportTrack(AudioTrack track) =>
      !isTrackExcluded(track) && (exporter?.supports(track) ?? false);

  CompletionTask? taskForTrack(String id) {
    for (final task in tasks) {
      if (task.trackId == id) return task;
    }
    return null;
  }

  bool canSaveOriginalTrack(AudioTrack track) {
    final writer = exporter;
    return !isTrackExcluded(track) &&
        writer is AudioOriginalSaver &&
        (writer as AudioOriginalSaver).supportsOriginal(track);
  }

  bool _validCandidates(CompletionTask task, List<FieldSuggestion> selected) =>
      selected.isNotEmpty &&
      selected.map((item) => item.field).toSet().length == selected.length &&
      selected.every(
        (item) =>
            hasText(item.value) &&
            (!item.replaceExisting || task.isRepair) &&
            !(item.field == AudioField.lyrics &&
                trackById(task.trackId)?.isInstrumental == true) &&
            task.suggestions.any((candidate) => candidate.permits(item)),
      );

  List<FieldSuggestion> approvedSuggestionsFor(CompletionTask task) {
    final current = taskForTrack(task.trackId);
    if (current == null ||
        !isTaskCurrent(task) ||
        !_validCandidates(current, current.approvedSuggestions)) {
      return const [];
    }
    return List.unmodifiable(current.approvedSuggestions);
  }

  CompletionTask _withReview(
    CompletionTask task, {
    List<FieldSuggestion>? approved,
    String? error,
  }) => CompletionTask(
    trackId: task.trackId,
    trackTitle: task.trackTitle,
    createdAt: task.createdAt,
    status: approved != null ? TaskStatus.readyToSave : task.status,
    message: approved != null
        ? '已确认 ${approved.length} 项资料，可保存到原文件或选择导出副本。'
        : task.message,
    suggestions: task.suggestions,
    exportedCopyUri: task.exportedCopyUri,
    queriedFields: task.queriedFields,
    isRepair: task.isRepair,
    searchMetadata: task.searchMetadata,
    recordingCandidates: task.recordingCandidates,
    sourceReports: task.sourceReports,
    confirmedRecording: task.confirmedRecording,
    approvedSuggestions: approved ?? task.approvedSuggestions,
    writeError: error,
  );

  Future<bool> approveCandidates(
    CompletionTask task,
    List<FieldSuggestion> selected,
  ) async {
    var approved = false;
    await _operate(() async {
      final current = taskForTrack(task.trackId);
      if (current == null ||
          !isTaskCurrent(task) ||
          !_validCandidates(current, selected)) {
        _announce('请选择当前结果中的候选资料。歌曲或候选已变化时请重新查询。');
        return;
      }
      await _commit(
        tasks: tasks
            .map(
              (item) => item.trackId == task.trackId
                  ? _withReview(current, approved: List.unmodifiable(selected))
                  : item,
            )
            .toList(),
      );
      approved = true;
      _announce('已确认 ${selected.length} 项资料，尚未修改文件。可在批量操作中保存。');
    });
    return approved;
  }

  Future<bool> revokeCandidateApproval(CompletionTask task) async {
    var revoked = false;
    await _operate(() async {
      final current = taskForTrack(task.trackId);
      if (current == null || !isTaskCurrent(task)) return;
      final updated = CompletionTask(
        trackId: current.trackId,
        trackTitle: current.trackTitle,
        createdAt: current.createdAt,
        status: TaskStatus.needsReview,
        message: '已撤销确认，请重新核对候选资料。文件未修改。',
        suggestions: current.suggestions,
        exportedCopyUri: current.exportedCopyUri,
        queriedFields: current.queriedFields,
        isRepair: current.isRepair,
        searchMetadata: current.searchMetadata,
        recordingCandidates: current.recordingCandidates,
        sourceReports: current.sourceReports,
        confirmedRecording: current.confirmedRecording,
      );
      await _commit(
        tasks: tasks
            .map((item) => item.trackId == task.trackId ? updated : item)
            .toList(),
      );
      revoked = true;
      _announce('已撤销确认，批量保存将跳过此歌曲。');
    });
    return revoked;
  }

  Future<bool> saveCandidates(
    CompletionTask task,
    List<FieldSuggestion> selected,
  ) => _saveOne(task, selected, exportCopy: false);

  Future<bool> exportCandidates(
    CompletionTask task,
    List<FieldSuggestion> selected,
  ) => _saveOne(task, selected, exportCopy: true);

  Future<bool> _saveOne(
    CompletionTask task,
    List<FieldSuggestion> selected, {
    required bool exportCopy,
  }) async {
    var saved = false;
    await _operate(() async {
      final result = await _writeCandidates(
        task,
        selected,
        exportCopy: exportCopy,
      );
      saved =
          result.status == BatchItemStatus.savedOriginal ||
          result.status == BatchItemStatus.exported;
      _announce(result.message);
    }, mutatesAudio: true);
    return saved;
  }

  Future<void> saveSelectedCandidates({
    bool exportCopies = false,
    Set<String>? trackIds,
  }) => _saveBatch(
    trackIds == null
        ? selectedTrackIds
        : selectedTrackIds.intersection(trackIds),
    exportCopies: exportCopies,
  );

  Future<void> _saveBatch(
    Set<String> ids, {
    required bool exportCopies,
  }) => _operate(() async {
    if (!await _refreshForExclusions(trackIds: ids)) return;
    final targets = tracks.where((track) => ids.contains(track.id)).toList();
    if (targets.isEmpty) {
      _announce('请先选择歌曲。');
      return;
    }
    await _startBatch(
      exportCopies
          ? BatchOperationKind.exportCopies
          : BatchOperationKind.saveOriginal,
      targets,
    );
    String? directory;
    try {
      final eligible = targets.where((track) {
        final task = taskForTrack(track.id);
        return task != null && approvedSuggestionsFor(task).isNotEmpty;
      }).toList();
      if (!exportCopies &&
          eligible.isNotEmpty &&
          exporter is AudioBatchOriginalSaver) {
        final supported = eligible.where(canSaveOriginalTrack).toList();
        if (supported.isNotEmpty) {
          progress = '正在请求 ${supported.length} 首原文件的系统写入授权…';
          _notify();
          final allowed = await (exporter as AudioBatchOriginalSaver)
              .authorizeOriginalWrites(supported);
          if (!allowed) {
            _batchStopRequested = true;
            return;
          }
        }
      }
      if (exportCopies && eligible.isNotEmpty) {
        final writer = exporter;
        if (writer is! AudioBatchExporter) {
          for (final item in targets) {
            _setBatchItem(
              item.id,
              BatchItemStatus.failed,
              '当前环境不支持批量导出，请逐首导出副本。',
            );
          }
          return;
        }
        progress = '请选择批量副本保存文件夹…';
        _notify();
        directory = await (writer as AudioBatchExporter)
            .chooseExportDirectory();
        if (directory == null) {
          _batchStopRequested = true;
          return;
        }
      }
      for (var index = 0; index < targets.length; index++) {
        if (_batchStopRequested || _disposed) break;
        final item = targets[index];
        final task = taskForTrack(item.id);
        final approved = task == null
            ? <FieldSuggestion>[]
            : approvedSuggestionsFor(task);
        if (task == null || approved.isEmpty) {
          _setBatchItem(
            item.id,
            BatchItemStatus.skipped,
            task?.status == TaskStatus.savedOriginal
                ? '原文件已保存，不重复写入。'
                : '尚无已确认的有效资料，请逐项确认候选后再保存。',
          );
          await _commit();
          continue;
        }
        progress =
            '正在${exportCopies ? '导出副本' : '保存原文件'} ${index + 1} / ${targets.length}：${item.displayTitle}';
        _setBatchItem(item.id, BatchItemStatus.running, '正在准备、保存并校验');
        await _commit();
        final result = await _writeCandidates(
          task,
          approved,
          exportCopy: exportCopies,
          directory: directory,
        );
        _setBatchItem(item.id, result.status, result.message);
        if (result.status == BatchItemStatus.cancelled ||
            _writeRecordUncertain) {
          _batchStopRequested = true;
        }
        await _commit();
      }
    } catch (error, stack) {
      debugPrint('Batch write interrupted: $error\n$stack');
      final message = _writeErrorMessage(error, exportCopies);
      final current = batchOperation!;
      for (final item in current.items.where((item) => !item.isFinished)) {
        _setBatchItem(item.trackId, BatchItemStatus.failed, message);
      }
    } finally {
      await _finishBatch();
      _announce(
        '${_batchStopRequested ? '已停止。' : ''}${batchOperation!.summary}',
      );
    }
  }, mutatesAudio: true);

  Future<BatchItemResult> _writeCandidates(
    CompletionTask task,
    List<FieldSuggestion> selected, {
    required bool exportCopy,
    String? directory,
  }) async {
    BatchItemResult result(BatchItemStatus status, String message) =>
        BatchItemResult(
          trackId: task.trackId,
          trackTitle: task.trackTitle,
          status: status,
          message: message,
        );
    if (!await _refreshForExclusions(trackIds: [task.trackId])) {
      return result(BatchItemStatus.skipped, '无法确认最新排除条件，未保存。');
    }
    var candidateTrack = trackById(task.trackId);
    if (candidateTrack == null) {
      return result(BatchItemStatus.skipped, '歌曲不可用或已被音乐库排除条件过滤，未保存。');
    }
    if (candidateTrack.requiresTagRefresh ||
        (_hasLibraryExclusions &&
            candidateTrack.isDeviceTrack &&
            deviceLibrary != null)) {
      try {
        final updated = await _readCurrentTrackDetails(candidateTrack);
        final changed = _tagSnapshotChanged(candidateTrack, updated);
        await _commit(
          tracks: _snapshot.tracks
              .map((item) => item.id == updated.id ? updated : item)
              .toList(),
          tasks: changed ? _invalidateTasks({updated.id}) : null,
        );
        if (isTrackExcluded(updated)) {
          return result(BatchItemStatus.skipped, '读取后符合排除条件，未保存。');
        }
        candidateTrack = trackById(task.trackId);
      } catch (error) {
        if (error is PlatformException && error.code == 'permission_denied') {
          libraryPermission = AudioLibraryPermission.denied;
          _batchStopRequested = true;
          _notify();
        }
        return result(
          BatchItemStatus.failed,
          _writeErrorMessage(error, exportCopy),
        );
      }
    }
    final track = candidateTrack;
    final current = taskForTrack(task.trackId);
    if (track == null || current == null || !isTaskCurrent(task)) {
      return result(BatchItemStatus.skipped, '歌曲或候选已更新，请返回重新打开结果。');
    }
    if (!_validCandidates(current, selected)) {
      return result(BatchItemStatus.skipped, '请选择当前结果中的候选资料，同一字段只能选择一项。');
    }
    if (exportCopy ? !canExportTrack(track) : !canSaveOriginalTrack(track)) {
      return result(
        BatchItemStatus.skipped,
        !exportCopy && !track.isDeviceTrack && canExportTrack(track)
            ? '这是旧版导入的应用内副本，请选择导出副本。系统音乐库原文件支持直接保存。'
            : '此格式或来源暂不支持安全${exportCopy ? '导出' : '保存原文件'}，目前支持 MP3、FLAC 和 M4A/MP4。',
      );
    }
    progress ??= exportCopy ? '正在生成并校验副本，原音频保持不变…' : '正在校验资料并备份原文件，请勿退出…';
    _notify();
    try {
      if (!await _recoverExport()) {
        return result(BatchItemStatus.failed, exportRecoveryNotice!);
      }
      final String? uri;
      if (!exportCopy) {
        uri = await (exporter as AudioOriginalSaver).saveOriginal(
          track,
          selected,
        );
      } else if (directory != null) {
        uri = await (exporter as AudioBatchExporter).exportToDirectory(
          track,
          selected,
          directory,
        );
      } else {
        uri = await exporter!.export(track, selected);
      }
      if (uri == null) {
        return result(BatchItemStatus.cancelled, '已取消保存，原音频未修改。');
      }
      final status = exportCopy
          ? BatchItemStatus.exported
          : BatchItemStatus.savedOriginal;
      var message = exportCopy
          ? '已导出校验通过的音频副本，原音频未修改。'
          : '已保存到原文件，并通过标签与音频完整性校验。';
      AudioTrack updated = track;
      if (!exportCopy) {
        final values = {for (final item in selected) item.field: item.value};
        updated = track.withDetails(
          title: values[AudioField.title] ?? track.title,
          artist: values[AudioField.artist] ?? track.artist,
          album: values[AudioField.album] ?? track.album,
          year: track.year,
          durationMs: track.durationMs,
          lyrics: values[AudioField.lyrics] ?? track.lyrics,
          artworkPath: track.artworkPath,
        );
        try {
          if (track.isDeviceTrack && deviceLibrary != null) {
            updated = (await deviceLibrary!.readDetails(track))
                .withInstrumental(track.isInstrumental);
          } else if (importer is LocalAudioImporter) {
            final root = await (importer as LocalAudioImporter)
                .directoryProvider();
            updated = await readTrackTags(track, track.localPath, root.path);
          }
          if (updated.readError != null) message += ' 列表资料重新读取失败，请刷新核对。';
        } catch (_) {
          updated = updated.withReadError('文件已保存，但列表资料重新读取失败，请刷新核对。');
          message += ' 列表资料重新读取失败，请刷新核对。';
        }
      }
      final savedTask = CompletionTask(
        trackId: current.trackId,
        trackTitle: updated.displayTitle,
        createdAt: current.createdAt,
        status: exportCopy ? TaskStatus.exported : TaskStatus.savedOriginal,
        message: message,
        suggestions: current.suggestions,
        exportedCopyUri: exportCopy ? uri : current.exportedCopyUri,
        queriedFields: current.queriedFields,
        isRepair: current.isRepair,
        searchMetadata: current.searchMetadata,
        recordingCandidates: current.recordingCandidates,
        sourceReports: current.sourceReports,
        confirmedRecording: current.confirmedRecording,
        approvedSuggestions: exportCopy
            ? current.approvedSuggestions
            : const [],
      );
      try {
        await _commit(
          tasks: tasks
              .map((item) => item.trackId == task.trackId ? savedTask : item)
              .toList(),
          tracks: _snapshot.tracks
              .map((item) => item.id == track.id ? updated : item)
              .toList(),
        );
        if (exporter case final AudioExportRecovery recovery) {
          try {
            await recovery.confirmExportRecorded(uri);
          } catch (error) {
            debugPrint('Write journal acknowledgement deferred: $error');
          }
        }
      } catch (_) {
        _writeRecordUncertain = true;
        if (!exportCopy) {
          // Physical verification already succeeded. Keep that truth in memory
          // so another tap cannot re-submit this original while disk is full.
          // The native journal remains unacknowledged for process recovery.
          _snapshot = LibrarySnapshot(
            tracks: _snapshot.tracks
                .map((item) => item.id == track.id ? updated : item)
                .toList(),
            tasks: tasks
                .map((item) => item.trackId == task.trackId ? savedTask : item)
                .toList(),
            settings: settings,
            recoveredFromBackup: _snapshot.recoveredFromBackup,
            batchOperation: batchOperation,
          );
          _notify();
        }
        message = exportCopy
            ? '音频副本已保存，但任务记录保存失败。请在刚选择的位置查看文件。'
            : '原文件已保存，但任务记录保存失败。请查看恢复提醒并重新读取歌曲，勿重复保存。';
      }
      return result(status, message);
    } catch (error) {
      final message = _writeErrorMessage(error, exportCopy);
      try {
        await _commit(
          tasks: tasks
              .map(
                (item) => item.trackId == current.trackId
                    ? _withReview(current, error: message)
                    : item,
              )
              .toList(),
        );
      } catch (_) {
        _writeRecordUncertain = true;
      }
      if (error is PlatformException &&
          (error.code.contains('recovery') ||
              error.code.contains('rollback'))) {
        _writeRecordUncertain = true;
        await _recoverExport();
      }
      return result(BatchItemStatus.failed, message);
    }
  }

  String _writeErrorMessage(Object error, bool exportCopy) {
    if (error is ExportException) return error.message;
    if (error is FormatException) return '音频校验未通过：${error.message}';
    if (error is TimeoutException) return '封面下载超时，未开始写入。请稍后重试。';
    if (error is PlatformException) {
      if (error.code == 'export_cleanup_failed') {
        return '保存未完成，所选位置可能留有不完整副本，请删除该副本后重试。原音频未修改。';
      }
      if (hasText(error.message)) return error.message!;
    }
    return exportCopy
        ? '保存未完成。原音频未修改，请检查保存位置和可用空间后重试。'
        : '原文件保存未完成，请检查系统写入权限、可用空间与恢复提醒后重试。';
  }

  Future<void> updateSettings(AppSettings value) =>
      _operate(() => _commit(settings: value));

  @override
  void dispose() {
    completionStopRequested = true;
    _batchStopRequested = true;
    _disposed = true;
    preview.dispose();
    super.dispose();
  }
}
