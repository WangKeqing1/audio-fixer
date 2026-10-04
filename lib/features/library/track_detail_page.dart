import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/models/completion_task.dart';
import '../../core/services/metadata_source.dart';
import '../../core/services/sources/track_search.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/source_query_status.dart';
import '../../shared/widgets/pane_entrance.dart';
import '../../shared/widgets/track_artwork.dart';
import '../../shared/widgets/instrumental_control.dart';
import 'library_controller.dart';
import 'metadata_editor_page.dart';
import '../tasks/candidate_review_page.dart';
import '../tasks/recording_choice_page.dart';

class TrackDetailPage extends StatefulWidget {
  const TrackDetailPage({
    super.key,
    required this.track,
    required this.controller,
    this.embedded = false,
    this.isActive = true,
    this.onClose,
  });
  final AudioTrack track;
  final LibraryController controller;
  final bool embedded;
  final bool isActive;
  final VoidCallback? onClose;

  @override
  State<TrackDetailPage> createState() => _TrackDetailPageState();
}

class _TrackDetailPageState extends State<TrackDetailPage> {
  LibraryController get controller => widget.controller;
  final _scrollController = ScrollController();
  bool _querying = false;
  bool _reviewing = false;
  String? _queryNotice;
  bool _noticeIsSeparate = false;

  bool _canRepair(AudioTrack track) =>
      controller.canOperate &&
      !_querying &&
      track.detailsLoaded &&
      !track.requiresTagRefresh &&
      track.readError == null &&
      !controller.isTrackExcluded(track);

  Set<String> _querySources(
    AudioTrack track, {
    bool titleOnly = false,
    bool missingOnly = false,
  }) {
    final task = controller.taskForTrack(track.id);
    if (!titleOnly &&
        !missingOnly &&
        task?.confirmedRecording != null &&
        controller.isTaskCurrent(task!)) {
      return {task.confirmedRecording!.sourceName};
    }
    final fields = missingOnly
        ? controller.settings.enabledFields.intersection(track.missingFields)
        : controller.completion.availableFields.difference(
            track.isInstrumental ? {AudioField.lyrics} : {},
          );
    return controller.completion.sources
        .where(
          (source) =>
              (titleOnly || !hasText(TrackSearch.fromTrack(track).artist))
              ? source is RecordingDiscoverySource
              : source.supportedFields.intersection(fields).isNotEmpty,
        )
        .map((source) => source.name)
        .toSet();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.readDetails(widget.track.id);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _query({
    bool missingOnly = false,
    bool titleOnly = false,
  }) async {
    final track = controller.trackById(widget.track.id);
    if (track == null ||
        !_canRepair(track) ||
        !widget.isActive ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final current = controller.taskForTrack(track.id);
    if (SourceRetryState(
      current?.sourceReports ?? const [],
      DateTime.now(),
      requestedSources: _querySources(
        track,
        titleOnly: titleOnly,
        missingOnly: missingOnly,
      ),
    ).allSourcesCooling) {
      return;
    }
    final route = ModalRoute.of(context);
    final previous = controller.taskForTrack(track.id)?.createdAt;
    final noticeRevision = controller.noticeRevision;
    setState(() {
      _querying = true;
      _queryNotice = null;
    });
    try {
      if (titleOnly) {
        await controller.discoverAlternativeRecordings(track.id);
      } else if (missingOnly) {
        await controller.complete(track: track);
      } else if (current?.confirmedRecording != null &&
          controller.isTaskCurrent(current!)) {
        await controller.retryTaskQuery(current);
      } else {
        await controller.queryAutomaticRepair(track: track);
      }
      if (!mounted || !widget.isActive || route?.isCurrent != true) return;
      final task = controller.taskForTrack(track.id);
      final hasNewResult = task != null && task.createdAt != previous;
      if (hasNewResult &&
          (task.suggestions.isNotEmpty ||
              task.recordingCandidates.isNotEmpty) &&
          controller.isTaskCurrent(task)) {
        _openReview(task);
      } else {
        _showQueryNotice(
          hasNewResult
              ? task.message
              : controller.noticeRevision != noticeRevision
              ? controller.notice ?? '检索未完成，请稍后重试。'
              : '检索未生成新候选，请稍后重试。',
          separate: !hasNewResult,
        );
      }
    } catch (_) {
      if (mounted && route?.isCurrent == true) {
        _showQueryNotice('检索未完成，请检查网络后重试，也可调整检索条件或手动编辑。', separate: true);
      }
    } finally {
      if (mounted) setState(() => _querying = false);
    }
  }

  void _showQueryNotice(String message, {bool separate = false}) {
    setState(() {
      _queryNotice = message;
      _noticeIsSeparate = separate;
    });
    if (_scrollController.hasClients) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _scrollController.jumpTo(0);
      } else {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    }
  }

  void _openEditor(AudioTrack track, {bool queryOnly = false}) {
    if (!_canRepair(track)) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetadataEditorPage(
          track: track,
          controller: controller,
          queryOnly: queryOnly,
        ),
      ),
    );
  }

  void _openReview(CompletionTask task) {
    if (!controller.isTaskCurrent(task) || !widget.isActive) return;
    if (task.suggestions.isNotEmpty && widget.embedded) {
      setState(() => _reviewing = true);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => task.suggestions.isEmpty
              ? RecordingChoicePage(task: task, controller: controller)
              : CandidateReviewPage(task: task, controller: controller),
        ),
      );
    }
  }

  void _closeReview() => setState(() {
    _reviewing = false;
    _queryNotice = null;
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final track = controller.trackById(widget.track.id);
      if (track == null) {
        return Scaffold(
          appBar: widget.embedded ? null : AppBar(title: const Text('歌曲资料')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('此歌曲已不可访问，请返回音乐库刷新或重新授权。'),
                  if (widget.onClose != null)
                    TextButton(
                      onPressed: widget.onClose,
                      child: const Text('返回音乐库'),
                    ),
                ],
              ),
            ),
          ),
        );
      }
      final canRepair = _canRepair(track);
      final task = controller.taskForTrack(track.id);
      final pendingRecordingChoice =
          task != null &&
          task.suggestions.isEmpty &&
          task.recordingCandidates.isNotEmpty &&
          task.confirmedRecording == null &&
          controller.isTaskCurrent(task);
      final hasReview =
          task != null &&
          controller.isTaskCurrent(task) &&
          (task.status == TaskStatus.needsReview ||
              task.status == TaskStatus.readyToSave) &&
          (task.suggestions.isNotEmpty || pendingRecordingChoice);
      if (_reviewing && task != null) {
        return PopScope(
          canPop: !widget.isActive,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && widget.isActive) _closeReview();
          },
          child: PaneEntrance(
            key: ValueKey('review-enter-${track.id}-${task.createdAt}'),
            child: CandidateReviewPage(
              key: ValueKey('inline-review-${track.id}-${task.createdAt}'),
              task: task,
              controller: controller,
              embedded: true,
              onBack: _closeReview,
              onFinished: _closeReview,
            ),
          ),
        );
      }
      final reports = task?.sourceReports ?? const [];
      final saved =
          task?.status == TaskStatus.savedOriginal ||
          task?.status == TaskStatus.exported;
      final failed = task?.status == TaskStatus.failed;
      final emptyResult =
          task != null &&
          task.suggestions.isEmpty &&
          task.status != TaskStatus.outdated &&
          !saved;
      final resultMessage = _queryNotice ?? (emptyResult ? task.message : null);
      final showFallback = resultMessage != null;
      final isReading = !track.detailsLoaded || track.requiresTagRefresh;
      final missing = track.missingFields.map((field) => field.label).join('、');
      final statusTitle = _querying
          ? '正在找回歌曲资料'
          : saved
          ? (task!.status == TaskStatus.savedOriginal ? '已保存到歌曲' : '副本已导出')
          : hasReview
          ? (pendingRecordingChoice ? '先确认歌曲版本' : '找到可以补全的资料')
          : _noticeIsSeparate && _queryNotice != null
          ? '这次操作没有完成'
          : failed
          ? '暂时没能完成查询'
          : resultMessage != null
          ? '这次没有找到合适的资料'
          : track.readError != null
          ? '这首歌暂时无法读取'
          : isReading
          ? '正在了解这首歌'
          : track.artworkError != null
          ? '封面无法显示'
          : track.artworkNeedsCheck
          ? '封面还需要检查'
          : missing.isNotEmpty
          ? '还差一点，就完整了'
          : '歌曲资料已齐全';
      final statusMessage = _querying
          ? '正在查询封面、歌词和歌曲资料。可以停止，原文件不会改变。'
          : saved
          ? task!.message
          : hasReview
          ? (pendingRecordingChoice ? '选对版本后，再查看封面和歌词。' : '先看看新资料，确认后再保存。')
          : resultMessage ??
                track.readError ??
                (isReading
                    ? '正在读取本地歌曲信息，稍等一下。'
                    : (track.artworkError != null
                          ? '已有封面暂时无法解码，可以重新检索封面。'
                          : track.artworkNeedsCheck
                          ? '封面尚未验证，检查后才会标记为完整。'
                          : missing.isNotEmpty
                          ? '可补全：$missing'
                          : '也可以重新查找更合适的封面、歌词和版本。'));
      final showInstrumentalCard =
          !pendingRecordingChoice &&
          (track.isInstrumental ||
              (track.detailsLoaded &&
                  track.readError == null &&
                  !hasText(track.lyrics) &&
                  task != null &&
                  (task.status == TaskStatus.noMatch ||
                      task.status == TaskStatus.needsReview) &&
                  task.queriedFields.contains(AudioField.lyrics) &&
                  !task.suggestions.any(
                    (item) => item.field == AudioField.lyrics,
                  )));
      final detailList = ListView(
        key: ValueKey('song-detail-scroll-${track.id}'),
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        children: [
          if (widget.embedded) ...[
            Row(
              children: [
                BackButton(
                  key: const ValueKey('close-selected-song'),
                  onPressed: widget.onClose,
                ),
                const Expanded(child: Text('歌曲资料')),
              ],
            ),
            const SizedBox(height: 12),
          ],
          _SongIdentity(track: track, controller: controller),
          const SizedBox(height: 24),
          Semantics(
            liveRegion: true,
            child: Container(
              key: const ValueKey('song-next-step'),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: failed || track.readError != null
                    ? colors.errorContainer
                    : colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        saved
                            ? Icons.check_circle_outline
                            : failed
                            ? Icons.cloud_off_outlined
                            : Icons.auto_awesome_outlined,
                        color: failed
                            ? colors.onErrorContainer
                            : colors.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          statusTitle,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    statusMessage,
                    key: const ValueKey('automatic-repair-result'),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
                  if (_querying) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                  if (controller.completion.sources.isEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('当前没有接入在线数据源，可手动编辑。'),
                  ],
                  if (isReading && !controller.isBusy)
                    TextButton(
                      onPressed: () => controller.readDetails(track.id),
                      child: const Text('读取歌曲资料'),
                    ),
                ],
              ),
            ),
          ),
          if (_noticeIsSeparate && _queryNotice != null)
            Padding(
              key: const ValueKey('query-action-result'),
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '本次操作未完成，之前的查询结果仍保留。',
                style: TextStyle(color: colors.error),
              ),
            ),
          const SizedBox(height: 12),
          if (task != null && reports.isNotEmpty)
            ExpansionTile(
              key: const PageStorageKey('song-source-details'),
              tilePadding: EdgeInsets.zero,
              title: const Text('查询来源与详情'),
              children: [
                SourceQueryStatusPanel(
                  reports: reports,
                  summary:
                      saved ||
                          task.status == TaskStatus.skipped ||
                          task.status == TaskStatus.outdated
                      ? task.message
                      : null,
                  hasCandidates:
                      task.suggestions.isNotEmpty ||
                      task.recordingCandidates.isNotEmpty,
                  retrySources: _querySources(track),
                  retryKey: const ValueKey('retry-automatic-repair'),
                  onRetry: canRepair ? _query : null,
                ),
              ],
            ),
          ExpansionTile(
            key: ValueKey('repair-fallback-$showFallback'),
            initiallyExpanded: showFallback,
            tilePadding: EdgeInsets.zero,
            title: const Text('其他修复方式'),
            children: [
              if (controller.canDiscoverRecordings)
                SourceRetryBuilder(
                  reports: reports,
                  requestedSources: _querySources(track, titleOnly: true),
                  builder: (context, retry) => ListTile(
                    key: const ValueKey('discover-alternative-recordings'),
                    leading: const Icon(Icons.library_music_outlined),
                    title: Text(
                      retry.allSourcesCooling
                          ? retry.label('仅凭歌名查找版本')
                          : '仅凭歌名查找版本',
                    ),
                    onTap: canRepair && !retry.allSourcesCooling
                        ? () => _query(titleOnly: true)
                        : null,
                  ),
                ),
              ListTile(
                key: const ValueKey('query-metadata-repair'),
                leading: const Icon(Icons.manage_search),
                title: const Text('调整检索条件'),
                onTap: canRepair
                    ? () => _openEditor(track, queryOnly: true)
                    : null,
              ),
              ListTile(
                key: const ValueKey('edit-metadata'),
                leading: const Icon(Icons.edit_note),
                title: const Text('手动编辑元数据与封面'),
                onTap: canRepair ? () => _openEditor(track) : null,
              ),
              if (!track.isInstrumental &&
                  !pendingRecordingChoice &&
                  !showInstrumentalCard)
                ListTile(
                  key: const ValueKey('mark-instrumental-option'),
                  leading: const Icon(Icons.piano_outlined),
                  title: const Text('设为纯音乐'),
                  subtitle: const Text('仅在本应用跳过歌词，不修改音频文件'),
                  onTap: canRepair
                      ? () => controller.setTrackInstrumental(track.id, true)
                      : null,
                ),
              SourceRetryBuilder(
                reports: reports,
                requestedSources: _querySources(track, missingOnly: true),
                builder: (context, retry) => ListTile(
                  key: const ValueKey('complete-missing-only'),
                  leading: const Icon(Icons.playlist_add),
                  title: Text(
                    retry.allSourcesCooling ? retry.label('仅补全缺失项') : '仅补全缺失项',
                  ),
                  onTap:
                      canRepair &&
                          controller.canQueryTrack(track) &&
                          !retry.allSourcesCooling
                      ? () => _query(missingOnly: true)
                      : null,
                ),
              ),
            ],
          ),
          ExpansionTile(
            key: const PageStorageKey('song-file-details'),
            tilePadding: EdgeInsets.zero,
            title: const Text('歌曲与文件详情'),
            subtitle: Text(
              '${track.extension} · ${formatDuration(track.durationMs)} · ${formatFileSize(track.sizeBytes)}',
            ),
            children: [
              for (final field in AudioField.metadataFields)
                _FieldRow(label: field.label, value: track.valueOf(field)),
              _FieldRow(label: '文件名', value: track.fileName),
              for (final warning in track.tagReadWarnings)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(warning, style: theme.textTheme.bodySmall),
                ),
              const Text('其他自定义标签保留在原文件中。'),
              if (track.detailsLoaded && controller.canRereadTrack(track))
                TextButton.icon(
                  onPressed: controller.canOperate
                      ? () => controller.readDetails(track.id, force: true)
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新读取'),
                ),
            ],
          ),
          if (hasText(track.lyrics))
            ExpansionTile(
              key: const PageStorageKey('song-lyrics'),
              tilePadding: EdgeInsets.zero,
              title: const Text('歌词'),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: SelectableText(
                    track.lyrics!,
                    key: const PageStorageKey('lyrics-text-scroll'),
                  ),
                ),
              ],
            ),
          if (showInstrumentalCard) ...[
            const SizedBox(height: 12),
            InstrumentalControl(track: track, controller: controller),
          ],
          const SizedBox(height: 16),
          Text(
            '查询只发送歌名、歌手、专辑和时长，不上传音频。确认资料后才会保存。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      );
      final footer = Material(
        color: colors.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasReview)
                  FilledButton.icon(
                    key: ValueKey(
                      pendingRecordingChoice
                          ? 'review-recording-choices'
                          : 'review-song-result',
                    ),
                    onPressed: controller.canOperate
                        ? () => _openReview(task)
                        : null,
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: Text(pendingRecordingChoice ? '确认歌曲版本' : '查看并确认资料'),
                  )
                else
                  SourceRetryBuilder(
                    reports: reports,
                    requestedSources: _querySources(track),
                    builder: (context, retry) => FilledButton.icon(
                      key: const ValueKey('automatic-repair'),
                      onPressed: canRepair && !retry.allSourcesCooling
                          ? _query
                          : null,
                      icon: const Icon(Icons.auto_fix_high_outlined),
                      label: Text(
                        _querying
                            ? '正在自动检索…'
                            : retry.label(
                                saved
                                    ? '重新查找资料'
                                    : resultMessage != null
                                    ? '重新查找资料'
                                    : '查找封面与歌词',
                              ),
                      ),
                    ),
                  ),
                if (controller.isCompleting) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          controller.progress ?? '正在查询…',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: controller.completionStopRequested
                            ? null
                            : controller.stopCompletion,
                        child: const Text('停止查询'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      );
      final content = LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            Expanded(child: detailList),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .45,
              ),
              child: SingleChildScrollView(child: footer),
            ),
          ],
        ),
      );
      if (widget.embedded) {
        return PopScope(
          canPop: !widget.isActive,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && widget.isActive) widget.onClose?.call();
          },
          child: Material(color: colors.surface, child: content),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('歌曲资料')),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: content,
            ),
          ),
        ),
      );
    },
  );
}

class _SongIdentity extends StatelessWidget {
  const _SongIdentity({required this.track, required this.controller});
  final AudioTrack track;
  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TrackArtwork(
          path: track.artworkError == null ? track.artworkPath : null,
          size: 88,
          validationPending: !track.hasArtwork,
          onLoaded: () =>
              controller.reportArtworkLoaded(track.id, track.artworkPath),
          placeholderLabel: track.artworkError != null ? '封面无法显示' : '暂无封面',
          onError: (message) => controller.reportArtworkFailure(
            track.id,
            track.artworkPath,
            message,
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.displayTitle,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                hasText(track.artist) ? track.artist! : '歌手未知',
                style: theme.textTheme.bodyMedium,
              ),
              if (hasText(track.album)) ...[
                const SizedBox(height: 4),
                Text(
                  track.album!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.value});
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            hasText(value) ? value! : '未读取到',
            key: PageStorageKey('field-text-scroll-$label'),
          ),
        ),
      ],
    ),
  );
}
