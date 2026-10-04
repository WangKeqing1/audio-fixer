import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/models/batch_operation.dart';
import '../../core/models/completion_task.dart';
import '../../core/models/recommended_changes.dart';
import '../library/library_controller.dart';
import 'candidate_review_page.dart';
import 'batch_progress_panel.dart';

Future<void> reviewBatchChanges(
  BuildContext context,
  LibraryController controller,
  Set<String> trackIds, {
  bool exportCopies = false,
}) async {
  if (!controller.canOperate || trackIds.isEmpty) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => RecommendedBatchReviewPage(
        controller: controller,
        trackIds: Set.unmodifiable(trackIds),
        exportCopies: exportCopies,
      ),
    ),
  );
}

/// A compact glance-to-apply review. Merely opening or leaving it does not
/// persist approval, and the apply button consumes only its frozen snapshots.
class RecommendedBatchReviewPage extends StatefulWidget {
  const RecommendedBatchReviewPage({
    super.key,
    required this.controller,
    required this.trackIds,
    this.exportCopies = false,
  });

  final LibraryController controller;
  final Set<String> trackIds;
  final bool exportCopies;

  @override
  State<RecommendedBatchReviewPage> createState() =>
      _RecommendedBatchReviewPageState();
}

class _RecommendedBatchReviewPageState
    extends State<RecommendedBatchReviewPage> {
  final Map<String, ReviewedTaskSelection> _snapshots = {};
  final Set<String> _included = {};
  bool _applying = false;
  String? _notice;
  BatchOperation? _previousBatch;
  bool _hasApplied = false;

  @override
  void initState() {
    super.initState();
    for (final id in widget.trackIds) {
      _refreshSnapshot(id);
      if (_snapshots[id]?.suggestions.isNotEmpty == true) _included.add(id);
    }
  }

  void _refreshSnapshot(String id) {
    final task = widget.controller.taskForTrack(id);
    if (task == null) {
      _snapshots.remove(id);
      return;
    }
    _snapshots[id] = ReviewedTaskSelection(
      task: task,
      suggestions: widget.controller.reviewSuggestionsFor(task),
    );
  }

  bool _eligible(String id) {
    final track = widget.controller.trackById(id);
    final snapshot = _snapshots[id];
    return track != null &&
        snapshot != null &&
        widget.controller.isReviewedSelectionCurrent(snapshot) &&
        (widget.exportCopies
            ? widget.controller.canExportTrack(track)
            : widget.controller.canSaveOriginalTrack(track));
  }

  Future<void> _inspect(String id) async {
    final task = widget.controller.taskForTrack(id);
    if (task == null || !widget.controller.isTaskCurrent(task)) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            CandidateReviewPage(task: task, controller: widget.controller),
      ),
    );
    if (!mounted) return;
    setState(() {
      // Only explicit persisted choices from inspection may replace this row's
      // default; do not merge new recommendations into an approved selection.
      _refreshSnapshot(id);
      if (_snapshots[id]?.suggestions.isEmpty ?? true) {
        _included.remove(id);
      } else if (_snapshots[id]!.task.approvedSuggestions.isNotEmpty) {
        _included.add(id);
      }
    });
  }

  Future<void> _apply() async {
    if (_applying || !widget.controller.canOperate) return;
    final selections = [
      for (final id in widget.trackIds)
        if (_included.contains(id) && _eligible(id)) _snapshots[id]!,
    ];
    if (selections.isEmpty) return;
    setState(() {
      _applying = true;
      _notice = null;
      _previousBatch = widget.controller.batchOperation;
      _hasApplied = true;
    });
    final route = ModalRoute.of(context);
    await widget.controller.saveReviewedBatch(
      selections,
      exportCopies: widget.exportCopies,
    );
    if (!mounted) return;
    final completedBatch = widget.controller.batchOperation;
    final completed =
        completedBatch != null &&
        !identical(completedBatch, _previousBatch) &&
        completedBatch.kind ==
            (widget.exportCopies
                ? BatchOperationKind.exportCopies
                : BatchOperationKind.saveOriginal) &&
        selections.every(
          (selection) => completedBatch.items.any(
            (item) =>
                item.trackId == selection.task.trackId &&
                item.status ==
                    (widget.exportCopies
                        ? BatchItemStatus.exported
                        : BatchItemStatus.savedOriginal),
          ),
        );
    if (completed && route?.isCurrent == true) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _applying = false;
      _notice = widget.controller.notice ?? '尚未完成，可检查结果后重试。';
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final selected = widget.trackIds
          .where((id) => _included.contains(id) && _eligible(id))
          .toList();
      final fields = selected.fold<int>(
        0,
        (count, id) => count + _snapshots[id]!.suggestions.length,
      );
      final batch = widget.controller.batchOperation;
      final hasCurrentBatch =
          _hasApplied && batch != null && !identical(batch, _previousBatch);
      return PopScope(
        canPop: !_applying,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('查看本次修改'),
            automaticallyImplyLeading: !_applying,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text(
                '${selected.length} 首歌曲 · $fields 项资料',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                '已预选同版本、无冲突的缺失项。已有资料和有分歧的候选保留原值；你之前明确确认的修改会原样保留。可取消歌曲或查看详情。',
              ),
              const SizedBox(height: 8),
              Text(
                widget.exportCopies
                    ? '点击下方按钮后选择副本文件夹。原文件不变。'
                    : '保存前会备份原文件，保存后校验；需要时由系统确认写入权限。',
              ),
              if (_notice != null) ...[
                const SizedBox(height: 12),
                Text(
                  _notice!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              if (hasCurrentBatch)
                BatchProgressPanel(
                  controller: widget.controller,
                  showStopAction: false,
                  showRetryAction: false,
                ),
              for (final id in widget.trackIds) _trackCard(context, id),
            ],
          ),
          bottomNavigationBar: Material(
            elevation: 3,
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_applying) ...[
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        widget.controller.progress ?? '正在准备安全保存…',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (hasCurrentBatch) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: batch.progress),
                      Text(
                        '已处理 ${batch.completedCount} / ${batch.totalCount} 首',
                      ),
                    ],
                    TextButton(
                      key: const ValueKey('stop-reviewed-batch'),
                      onPressed:
                          hasCurrentBatch &&
                              batch.isRunning &&
                              !batch.stopRequested
                          ? widget.controller.stopBatch
                          : null,
                      child: Text(
                        batch?.stopRequested == true ? '等待当前歌曲安全完成…' : '停止后续歌曲',
                      ),
                    ),
                  ],
                  FilledButton.icon(
                    key: const ValueKey('apply-reviewed-batch'),
                    onPressed:
                        !_applying &&
                            widget.controller.canOperate &&
                            selected.isNotEmpty
                        ? _apply
                        : null,
                    icon: Icon(
                      widget.exportCopies ? Icons.save_alt : Icons.check,
                    ),
                    label: Text(
                      _applying
                          ? '正在安全处理…'
                          : widget.exportCopies
                          ? '导出 ${selected.length} 首副本'
                          : '应用并保存 ${selected.length} 首',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _trackCard(BuildContext context, String id) {
    final track = widget.controller.trackById(id);
    final snapshot = _snapshots[id];
    final choices = snapshot?.suggestions ?? const <FieldSuggestion>[];
    final eligible = _eligible(id);
    final currentTask = widget.controller.taskForTrack(id);
    final canInspect =
        currentTask != null &&
        currentTask.suggestions.isNotEmpty &&
        widget.controller.isTaskCurrent(currentTask);
    final wasApproved =
        snapshot != null && snapshot.task.approvedSuggestions.isNotEmpty;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  key: ValueKey('batch-include-$id'),
                  value: eligible && _included.contains(id),
                  onChanged:
                      eligible && !_applying && widget.controller.canOperate
                      ? (value) => setState(() {
                          if (value == true) {
                            _included.add(id);
                          } else {
                            _included.remove(id);
                          }
                        })
                      : null,
                ),
                Expanded(
                  child: Text(
                    track?.displayTitle ?? snapshot?.task.trackTitle ?? id,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  key: ValueKey('inspect-batch-$id'),
                  onPressed:
                      canInspect && !_applying && widget.controller.canOperate
                      ? () => _inspect(id)
                      : null,
                  child: const Text('查看详情'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    eligible
                        ? wasApproved
                              ? '按你已确认的选择'
                              : '推荐补齐'
                        : choices.isEmpty
                        ? '没有可直接采用的缺失项，原资料保持不变'
                        : '资料已变化、已保存或不支持本次操作，请重新检查',
                  ),
                  if (eligible) ...[
                    const SizedBox(height: 8),
                    Text(
                      choices.map((choice) => choice.field.label).join(' · '),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (_compactValues(choices).isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        _compactValues(choices),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _compactValues(List<FieldSuggestion> choices) => choices
      .where(
        (choice) => const {
          AudioField.title,
          AudioField.artist,
          AudioField.album,
        }.contains(choice.field),
      )
      .map((choice) => '${choice.field.label}：${choice.value}')
      .join('；');
}
