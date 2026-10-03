import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/models/completion_task.dart';
import '../../core/services/metadata_source.dart';
import '../../core/services/sources/track_search.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/notice_panel.dart';
import '../../shared/widgets/source_query_status.dart';
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
  });
  final AudioTrack track;
  final LibraryController controller;

  @override
  State<TrackDetailPage> createState() => _TrackDetailPageState();
}

class _TrackDetailPageState extends State<TrackDetailPage> {
  LibraryController get controller => widget.controller;
  final _scrollController = ScrollController();
  bool _querying = false;
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
      if (!mounted || route?.isCurrent != true) return;
      final task = controller.taskForTrack(track.id);
      final hasNewResult = task != null && task.createdAt != previous;
      if (hasNewResult &&
          (task.suggestions.isNotEmpty ||
              task.recordingCandidates.isNotEmpty) &&
          controller.isTaskCurrent(task)) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => task.suggestions.isEmpty
                ? RecordingChoicePage(task: task, controller: controller)
                : CandidateReviewPage(task: task, controller: controller),
          ),
        );
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
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final track = controller.trackById(widget.track.id);
      if (track == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('歌曲资料')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('此歌曲已不可访问，请返回音乐库刷新或重新授权。'),
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
      final emptyResult =
          task != null &&
          task.suggestions.isEmpty &&
          task.status != TaskStatus.outdated;
      final resultMessage = _queryNotice ?? (emptyResult ? task.message : null);
      final reports = task?.sourceReports ?? const [];
      final showFallback = resultMessage != null;
      return Scaffold(
        appBar: AppBar(title: const Text('歌曲资料')),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.all(24),
                children: [
                  Center(
                    child: TrackArtwork(path: track.artworkPath, size: 160),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    track.displayTitle,
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${track.extension} · ${formatDuration(track.durationMs)} · ${formatFileSize(track.sizeBytes)}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '自动匹配元数据、歌词与封面，已有资料也会重新检索。无需填写，找到候选后逐项确认再保存。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    controller.completion.sources.isEmpty
                        ? '当前没有接入在线数据源。可在下方备选方式中手动编辑。'
                        : '使用已有歌名、歌手、专辑与时长匹配；歌名缺失时使用文件名。仅检索数据源支持的字段，不上传音频。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (reports.isNotEmpty &&
                      _noticeIsSeparate &&
                      _queryNotice != null) ...[
                    const SizedBox(height: 16),
                    NoticePanel(
                      key: const ValueKey('query-action-result'),
                      icon: Icons.info_outline,
                      title: '本次操作未完成',
                      message: _queryNotice!,
                    ),
                  ],
                  if (reports.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    SourceQueryStatusPanel(
                      key: const ValueKey('automatic-repair-result'),
                      reports: reports,
                      summary:
                          task!.status == TaskStatus.skipped ||
                              task.status == TaskStatus.outdated ||
                              task.status == TaskStatus.savedOriginal ||
                              task.status == TaskStatus.exported
                          ? task.message
                          : null,
                      hasCandidates:
                          task.suggestions.isNotEmpty ||
                          task.recordingCandidates.isNotEmpty,
                      retrySources: _querySources(track),
                      retryKey: const ValueKey('retry-automatic-repair'),
                      onRetry: canRepair ? _query : null,
                    ),
                  ] else if (resultMessage != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: NoticePanel(
                        key: const ValueKey('automatic-repair-result'),
                        icon: Icons.info_outline,
                        title: '检索结果',
                        message: resultMessage,

                        action: TextButton.icon(
                          key: const ValueKey('retry-automatic-repair'),
                          onPressed: canRepair ? _query : null,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试自动检索'),
                        ),
                      ),
                    ),
                  ],
                  if (pendingRecordingChoice)
                    OutlinedButton.icon(
                      key: const ValueKey('review-recording-choices'),
                      onPressed: controller.canOperate
                          ? () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => RecordingChoicePage(
                                  task: task,
                                  controller: controller,
                                ),
                              ),
                            )
                          : null,
                      icon: const Icon(Icons.library_music_outlined),
                      label: Text(
                        '确认 ${task.recordingCandidates.length} 个歌曲版本',
                      ),
                    ),
                  if (task != null)
                    if (task.suggestions.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CandidateReviewPage(
                              task: task,
                              controller: controller,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.fact_check_outlined),
                        label: Text('查看 ${task.suggestions.length} 项候选资料'),
                      ),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    key: ValueKey('repair-fallback-$showFallback'),
                    initiallyExpanded: showFallback,
                    tilePadding: EdgeInsets.zero,
                    title: const Text('其他修复方式'),
                    subtitle: const Text('按需调整检索条件或手动编辑'),
                    children: [
                      if (controller.canDiscoverRecordings) ...[
                        SourceRetryBuilder(
                          reports: reports,
                          requestedSources: _querySources(
                            track,
                            titleOnly: true,
                          ),
                          builder: (context, retry) => OutlinedButton.icon(
                            key: const ValueKey(
                              'discover-alternative-recordings',
                            ),
                            onPressed: canRepair && !retry.allSourcesCooling
                                ? () => _query(titleOnly: true)
                                : null,
                            icon: const Icon(Icons.library_music_outlined),
                            label: Text(
                              retry.allSourcesCooling
                                  ? retry.label('仅凭歌名查找版本')
                                  : '仅凭歌名查找版本',
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      OutlinedButton.icon(
                        key: const ValueKey('query-metadata-repair'),
                        onPressed: canRepair
                            ? () => _openEditor(track, queryOnly: true)
                            : null,
                        icon: const Icon(Icons.manage_search),
                        label: const Text('调整检索条件'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const ValueKey('edit-metadata'),
                        onPressed: canRepair ? () => _openEditor(track) : null,
                        icon: const Icon(Icons.edit_note),
                        label: const Text('手动编辑元数据与封面'),
                      ),
                      const SizedBox(height: 8),
                      SourceRetryBuilder(
                        reports: reports,
                        requestedSources: _querySources(
                          track,
                          missingOnly: true,
                        ),
                        builder: (context, retry) => TextButton.icon(
                          key: const ValueKey('complete-missing-only'),
                          onPressed:
                              canRepair &&
                                  controller.canQueryTrack(track) &&
                                  !retry.allSourcesCooling
                              ? () => _query(missingOnly: true)
                              : null,
                          icon: const Icon(Icons.playlist_add),
                          label: Text(
                            retry.allSourcesCooling
                                ? retry.label('仅补全缺失项')
                                : '仅补全缺失项',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (!track.detailsLoaded || track.requiresTagRefresh) ...[
                    if (controller.isBusy) const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      controller.isBusy
                          ? '正在读取文件标签…'
                          : track.readError ?? '文件标签尚未检查。',
                      style: !controller.isBusy && track.readError != null
                          ? TextStyle(color: theme.colorScheme.error)
                          : null,
                    ),
                    if (!controller.isBusy)
                      TextButton(
                        onPressed: () => controller.readDetails(track.id),
                        child: const Text('读取歌曲资料'),
                      ),
                  ] else if (track.readError != null)
                    Text(
                      track.readError!,
                      style: TextStyle(color: theme.colorScheme.error),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final field in AudioField.coreFields)
                          Chip(
                            avatar: Icon(
                              track.missingFields.contains(field)
                                  ? Icons.remove_circle_outline
                                  : Icons.check_circle_outline,
                              size: 18,
                            ),
                            label: Text(
                              field == AudioField.lyrics && track.isInstrumental
                                  ? '纯音乐 · 免补歌词'
                                  : '${field.label}${track.missingFields.contains(field) ? '缺失' : '已有'}',
                            ),
                          ),
                      ],
                    ),
                  // MediaStore can lag an external tag edit. A successful
                  // cached read must not make the real file impossible to
                  // inspect again after the exporter detects a change.
                  if (track.detailsLoaded && controller.canRereadTrack(track))
                    TextButton.icon(
                      onPressed: controller.canOperate
                          ? () => controller.readDetails(track.id, force: true)
                          : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重新读取'),
                    ),
                  const SizedBox(height: 28),
                  Text('元数据', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  for (final field in AudioField.metadataFields)
                    _FieldRow(label: field.label, value: track.valueOf(field)),
                  _FieldRow(label: '文件名', value: track.fileName),
                  if (track.tagReadWarnings.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    for (final warning in track.tagReadWarnings)
                      Text(warning, style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    '其他自定义标签保留在原文件中，暂不提供编辑。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const Divider(height: 40),
                  Text('歌词', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 16),
                  SelectableText(
                    hasText(track.lyrics)
                        ? track.lyrics!
                        : track.readError != null || !track.detailsLoaded
                        ? '歌词读取状态未知。'
                        : track.isInstrumental
                        ? '已设为纯音乐，无需补全歌词。'
                        : '音频中尚未发现内嵌歌词。',
                  ),
                  if (!pendingRecordingChoice &&
                      (track.isInstrumental ||
                          (track.detailsLoaded &&
                              track.readError == null &&
                              !hasText(track.lyrics)))) ...[
                    const SizedBox(height: 16),
                    InstrumentalControl(track: track, controller: controller),
                  ],
                  const SizedBox(height: 24),
                  const SizedBox(height: 32),
                  Text(
                    '自动检索只生成候选资料。逐项确认后可保存到原文件，也可导出副本。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SourceRetryBuilder(
                  reports: reports,
                  requestedSources: _querySources(track),
                  builder: (context, retry) => FilledButton.icon(
                    key: const ValueKey('automatic-repair'),
                    onPressed: canRepair && !retry.allSourcesCooling
                        ? _query
                        : null,
                    icon: const Icon(Icons.auto_fix_high_outlined),
                    label: Text(_querying ? '正在自动检索…' : retry.label('自动检索并修复')),
                  ),
                ),
                if (controller.isCompleting) ...[
                  const SizedBox(height: 8),
                  Text(controller.progress ?? '正在查询…'),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: controller.completionStopRequested
                        ? null
                        : controller.stopCompletion,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('停止查询'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
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
        Expanded(child: SelectableText(hasText(value) ? value! : '未读取到')),
      ],
    ),
  );
}
