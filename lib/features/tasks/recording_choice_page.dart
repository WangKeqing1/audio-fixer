import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/models/completion_task.dart';
import '../../core/models/recording_candidate.dart';
import '../../core/services/metadata_source.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/notice_panel.dart';
import '../../shared/widgets/source_query_status.dart';
import '../library/library_controller.dart';
import '../library/metadata_editor_page.dart';
import 'candidate_review_page.dart';

/// Resolves a recording identity before any of its fields can be reviewed.
/// Choosing a version only starts a lookup; it never approves or saves fields.
class RecordingChoicePage extends StatefulWidget {
  const RecordingChoicePage({
    super.key,
    required this.task,
    required this.controller,
  });

  final CompletionTask task;
  final LibraryController controller;

  @override
  State<RecordingChoicePage> createState() => _RecordingChoicePageState();
}

class _RecordingChoicePageState extends State<RecordingChoicePage> {
  final _scrollController = ScrollController();
  bool _querying = false;
  RecordingCandidate? _pendingChoice;
  String? _notice;
  bool _noticeIsSeparate = false;

  LibraryController get controller => widget.controller;

  bool get _canChoose {
    final track = controller.trackById(widget.task.trackId);
    final current = controller.taskForTrack(widget.task.trackId);
    return !_querying &&
        controller.canOperate &&
        controller.isTaskCurrent(widget.task) &&
        track != null &&
        !controller.isTrackExcluded(track) &&
        current != null &&
        current.status == TaskStatus.needsReview &&
        current.confirmedRecording == null &&
        current.suggestions.isEmpty &&
        current.recordingCandidates.isNotEmpty;
  }

  bool _canQuery(AudioTrack track) =>
      !_querying &&
      controller.canOperate &&
      track.detailsLoaded &&
      !track.requiresTagRefresh &&
      track.readError == null &&
      !controller.isTrackExcluded(track);

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _showNotice(String message, {bool separate = false}) {
    setState(() {
      _notice = message;
      _noticeIsSeparate = separate;
    });
  }

  Future<void> _choose(RecordingCandidate candidate) async {
    if (!_canChoose ||
        ModalRoute.of(context)?.isCurrent != true ||
        !controller
            .taskForTrack(widget.task.trackId)!
            .recordingCandidates
            .any(candidate.sameAs)) {
      if (mounted && !_querying && ModalRoute.of(context)?.isCurrent == true) {
        _showNotice(
          controller.isBusy ? '正在完成上一项操作，请稍候。' : '版本列表已更新，请重新查找后选择。',
          separate: true,
        );
      }
      return;
    }
    final route = ModalRoute.of(context);
    final revision = controller.noticeRevision;
    setState(() {
      _querying = true;
      _pendingChoice = candidate;
      _notice = null;
    });
    try {
      final result = await controller.confirmRecordingChoice(
        widget.task,
        candidate,
      );
      if (!mounted || route?.isCurrent != true) return;
      final current = controller.taskForTrack(widget.task.trackId);
      if (result != null &&
          current != null &&
          current.createdAt == result.createdAt &&
          controller.isTaskCurrent(result) &&
          current.confirmedRecording?.sameAs(candidate) == true &&
          current.suggestions.isNotEmpty) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) =>
                CandidateReviewPage(task: current, controller: controller),
          ),
        );
      } else {
        _showNotice(
          result != null && current?.createdAt == result.createdAt
              ? result.message
              : controller.noticeRevision != revision
              ? controller.notice ?? '所选版本未完成检索，请重新检索版本后再试。'
              : '此版本列表已变化，请重新检索版本后再确认。',
          separate: result == null || current?.createdAt != result.createdAt,
        );
      }
    } catch (_) {
      if (mounted && route?.isCurrent == true) {
        _showNotice('所选版本检索失败，请检查网络后重试，也可调整检索条件或手动编辑。', separate: true);
      }
    } finally {
      if (mounted) setState(() => _querying = false);
    }
  }

  Future<void> _retrySelected(CompletionTask task) async {
    final track = controller.trackById(task.trackId);
    if (track == null ||
        !_canQuery(track) ||
        ModalRoute.of(context)?.isCurrent != true ||
        SourceRetryState(
          task.sourceReports,
          DateTime.now(),
        ).allSourcesCooling) {
      return;
    }
    final route = ModalRoute.of(context);
    final selected = task.confirmedRecording;
    setState(() {
      _querying = true;
      _pendingChoice = selected;
      _notice = null;
    });
    try {
      await controller.retryTaskQuery(task);
      if (!mounted || route?.isCurrent != true) return;
      final current = controller.taskForTrack(task.trackId);
      if (current != null &&
          current.createdAt != task.createdAt &&
          controller.isTaskCurrent(current) &&
          current.confirmedRecording?.sameAs(selected!) == true &&
          current.suggestions.isNotEmpty) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) =>
                CandidateReviewPage(task: current, controller: controller),
          ),
        );
      } else {
        _showNotice(
          current != null && current.createdAt != task.createdAt
              ? current.message
              : controller.notice ?? '所选版本检索未完成，请稍后重试。',
          separate: current == null || current.createdAt == task.createdAt,
        );
      }
    } catch (_) {
      if (mounted && route?.isCurrent == true) {
        _showNotice('所选版本检索未完成，请检查网络后重试。', separate: true);
      }
    } finally {
      if (mounted) setState(() => _querying = false);
    }
  }

  Future<void> _rediscover(AudioTrack track) async {
    if (!_canQuery(track) || ModalRoute.of(context)?.isCurrent != true) return;
    final route = ModalRoute.of(context);
    final previous = controller.taskForTrack(track.id)?.createdAt;
    final revision = controller.noticeRevision;
    setState(() {
      _querying = true;
      _pendingChoice = null;
      _notice = null;
    });
    try {
      await controller.complete(
        track: track,
        repairFields: widget.task.isRepair ? widget.task.queriedFields : null,
        searchMetadata: widget.task.searchMetadata,
      );
      if (!mounted || route?.isCurrent != true) return;
      final current = controller.taskForTrack(track.id);
      if (current != null &&
          current.createdAt != previous &&
          controller.isTaskCurrent(current) &&
          (current.recordingCandidates.isNotEmpty ||
              current.suggestions.isNotEmpty)) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => current.suggestions.isEmpty
                ? RecordingChoicePage(task: current, controller: controller)
                : CandidateReviewPage(task: current, controller: controller),
          ),
        );
      } else {
        _showNotice(
          current != null && current.createdAt != previous
              ? current.message
              : controller.noticeRevision != revision
              ? controller.notice ?? '检索未完成，请稍后重试。'
              : '检索未生成新版本，请稍后重试。',
          separate: current == null || current.createdAt == previous,
        );
      }
    } catch (_) {
      if (mounted && route?.isCurrent == true) {
        _showNotice('版本检索失败，请检查网络后重试。', separate: true);
      }
    } finally {
      if (mounted) setState(() => _querying = false);
    }
  }

  void _openEditor(AudioTrack track, {bool queryOnly = false}) {
    if (!_canQuery(track)) return;
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
      final track = controller.trackById(widget.task.trackId);
      final current = controller.taskForTrack(widget.task.trackId);
      final reports = current?.sourceReports ?? widget.task.sourceReports;
      final canRetrySelected =
          current?.confirmedRecording != null &&
          controller.isTaskCurrent(current!) &&
          current.suggestions.isEmpty;
      final currentChoice =
          controller.isTaskCurrent(widget.task) &&
          current?.confirmedRecording == null &&
          current?.status == TaskStatus.needsReview &&
          current?.suggestions.isEmpty == true;
      return Scaffold(
        appBar: AppBar(title: const Text('确认歌曲版本')),
        bottomNavigationBar:
            (_querying ||
                _notice != null ||
                !currentChoice ||
                controller.isBusy)
            ? Material(
                color: theme.colorScheme.surfaceContainer,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_querying || controller.isBusy) ...[
                          const LinearProgressIndicator(),
                          const SizedBox(height: 8),
                        ],
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _querying
                                ? _pendingChoice == null
                                      ? '正在查找歌曲版本…'
                                      : '正在获取“${_pendingChoice!.title}”的资料…'
                                : _notice ??
                                      (controller.isBusy
                                          ? controller.progress ?? '正在处理…'
                                          : '版本列表已更新，请重新查找后选择。'),
                            key: const ValueKey('recording-fixed-status'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!_querying &&
                            !controller.isBusy &&
                            !currentChoice &&
                            track != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              key: const ValueKey('recording-fixed-rediscover'),
                              onPressed: _canQuery(track)
                                  ? () => _rediscover(track)
                                  : null,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重新查找版本'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              )
            : null,
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.all(20),
                children: [
                  Text('先确认对应的录音版本', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(
                    track == null
                        ? '原歌曲已不可访问，请返回音乐库刷新或重新授权。'
                        : '本地文件：${track.fileName}\n本地时长：${formatDuration(track.durationMs)}${track.durationMs == null ? '' : '（${(track.durationMs! / 1000).toStringAsFixed(3)} 秒）'}',
                    key: const ValueKey('recording-local-file'),
                  ),
                  if (track != null && hasText(track.artist)) ...[
                    const SizedBox(height: 8),
                    Text('本地歌手：${track.artist}'),
                  ],
                  if (widget.task.searchMetadata['artist'] == '') ...[
                    const SizedBox(height: 8),
                    const Text('本次仅凭歌名与时长查找，未使用本地歌手信息核对。请仔细确认歌手与版本。'),
                  ],
                  const SizedBox(height: 16),
                  NoticePanel(
                    icon: Icons.help_outline,
                    title: '低置信度候选，需要你确认版本',
                    message:
                        '${track == null || !hasText(track.artist) ? '本地歌手缺失，' : ''}'
                        '仅凭歌名和相近时长无法确认录音。同名歌曲、不同专辑或现场版本可能不同；请核对歌手、专辑与时长后选择。'
                        '\n选择版本仅用于继续检索，查看补全建议后再应用。',
                  ),
                  if (reports.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    SourceQueryStatusPanel(
                      key: const ValueKey('recording-choice-source-status'),
                      reports: reports,
                      hasCandidates: currentChoice,
                      retryKey: canRetrySelected
                          ? const ValueKey('retry-selected-recording')
                          : null,
                      retryLabel: '重试所选版本',
                      retrySources: current?.confirmedRecording != null
                          ? {current!.confirmedRecording!.sourceName}
                          : null,
                      onRetry:
                          canRetrySelected && track != null && _canQuery(track)
                          ? () => _retrySelected(current)
                          : null,
                    ),
                  ],
                  if (_notice != null &&
                      (reports.isEmpty || _noticeIsSeparate)) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: NoticePanel(
                        key: const ValueKey('recording-choice-result'),
                        icon: Icons.info_outline,
                        title: '检索结果',
                        message: _notice!,
                      ),
                    ),
                  ] else if (!currentChoice &&
                      !canRetrySelected &&
                      !_querying) ...[
                    const SizedBox(height: 16),
                    const NoticePanel(
                      key: ValueKey('recording-choice-stale'),
                      icon: Icons.update_outlined,
                      title: '此版本列表已失效',
                      message: '歌曲资料或检索结果已变化，请重新检索版本后再确认。',
                    ),
                  ],
                  if (_querying) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Semantics(
                      liveRegion: true,
                      child: Text(controller.progress ?? '正在检索所选版本…'),
                    ),
                  ],
                  const SizedBox(height: 20),
                  for (final candidate in widget.task.recordingCandidates)
                    Card(
                      key: ValueKey(
                        'recording-${candidate.sourceName}-${candidate.sourceId}',
                      ),
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              candidate.title,
                              style: theme.textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text('歌手：${candidate.artist}'),
                            const SizedBox(height: 4),
                            Text(
                              '专辑：${hasText(candidate.album) ? candidate.album : '未提供'}',
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '时长：${formatDuration(candidate.durationMs)} · ${_durationDifference(track?.durationMs, candidate.durationMs)}',
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '来源：${candidate.sourceName} · ID ${candidate.sourceId}',
                              style: theme.textTheme.bodySmall,
                            ),
                            if (hasText(candidate.sourceUrl)) ...[
                              const SizedBox(height: 4),
                              SelectableText(
                                candidate.sourceUrl,
                                key: PageStorageKey(
                                  'recording-source-${candidate.sourceId}',
                                ),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                            if (hasText(candidate.matchDescription)) ...[
                              const SizedBox(height: 8),
                              Text(candidate.matchDescription),
                            ],
                            const SizedBox(height: 12),
                            FilledButton.tonalIcon(
                              key: ValueKey(
                                'choose-recording-${candidate.sourceName}-${candidate.sourceId}',
                              ),
                              onPressed: _canChoose
                                  ? () => _choose(candidate)
                                  : null,
                              icon:
                                  _querying &&
                                      _pendingChoice?.sameAs(candidate) == true
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.manage_search),
                              label: Text(
                                _querying &&
                                        _pendingChoice?.sameAs(candidate) ==
                                            true
                                    ? '正在获取这个版本…'
                                    : _querying
                                    ? '请等待当前版本完成'
                                    : '使用此版本检索资料',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (track != null) ...[
                    const SizedBox(height: 8),
                    SourceRetryBuilder(
                      reports: reports,
                      requestedSources: controller.completion.sources
                          .whereType<RecordingDiscoverySource>()
                          .map((source) => source.name)
                          .toSet(),
                      builder: (context, retry) => OutlinedButton.icon(
                        key: const ValueKey('rediscover-recordings'),
                        onPressed: _canQuery(track) && !retry.allSourcesCooling
                            ? () => _rediscover(track)
                            : null,
                        icon: const Icon(Icons.refresh),
                        label: Text(retry.label('重新检索版本')),
                      ),
                    ),
                    ExpansionTile(
                      title: const Text('其他修复方式'),
                      children: [
                        TextButton.icon(
                          key: const ValueKey('recording-adjust-query'),
                          onPressed: _canQuery(track)
                              ? () => _openEditor(track, queryOnly: true)
                              : null,
                          icon: const Icon(Icons.manage_search),
                          label: const Text('调整检索条件'),
                        ),
                        TextButton.icon(
                          key: const ValueKey('recording-manual-edit'),
                          onPressed: _canQuery(track)
                              ? () => _openEditor(track)
                              : null,
                          icon: const Icon(Icons.edit_note),
                          label: const Text('手动编辑元数据与封面'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

String _durationDifference(int? local, int? candidate) {
  if (local == null || candidate == null) return '无法比较时长';
  final difference = candidate - local;
  if (difference == 0) return '与本地时长相同';
  return '比本地${difference > 0 ? '长' : '短'} ${(difference.abs() / 1000).toStringAsFixed(3)} 秒';
}
