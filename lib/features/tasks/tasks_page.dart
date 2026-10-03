import 'package:flutter/material.dart';

import '../../core/models/completion_task.dart';
import '../../core/models/audio_track.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/notice_panel.dart';
import '../../shared/widgets/instrumental_control.dart';
import '../library/library_controller.dart';
import '../library/metadata_editor_page.dart';
import 'candidate_review_page.dart';
import '../library/library_selection_toolbar.dart';
import 'batch_progress_panel.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({
    super.key,
    required this.controller,
    required this.onOpenSettings,
  });
  final LibraryController controller;
  final VoidCallback onOpenSettings;

  bool _isManual(CompletionTask task) =>
      task.suggestions.any((candidate) => candidate.source == '手动编辑');

  void _retry(BuildContext context, CompletionTask task, AudioTrack track) {
    if (_isManual(task)) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MetadataEditorPage(
            track: track,
            controller: controller,
            initialValues: {
              for (final candidate in task.suggestions)
                candidate.field: candidate.value,
            },
          ),
        ),
      );
    } else if (task.isRepair) {
      controller.queryRepair(
        track.id,
        fields: task.queriedFields,
        searchTitle: task.searchMetadata['title'],
        searchArtist: task.searchMetadata['artist'],
        searchAlbum: task.searchMetadata['album'],
      );
    } else {
      controller.complete(track: track);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reviewCount = controller.tasks
        .where(
          (task) =>
              task.status == TaskStatus.needsReview &&
              controller.isTaskCurrent(task),
        )
        .length;
    final visibleIds = controller.tasks
        .where((task) => controller.trackById(task.trackId) != null)
        .map((task) => task.trackId)
        .toSet();
    final selectedIds = controller.selectedTrackIds.intersection(visibleIds);
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Expanded(
            child: ListView(
              key: const PageStorageKey('tasks'),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Text(
                  reviewCount > 0 ? '$reviewCount 首歌曲待确认' : '每一次整理，都有记录',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '查询或编辑 → 逐项确认 → 保存到原文件\n可多选批量处理，也可单独导出副本。仅保存勾选的修改，替换已有值会明确标注。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                if (controller.tasks.isNotEmpty && selectedIds.isEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('select-all-task-tracks'),
                        onPressed: controller.canOperate
                            ? () => controller.selectTracks(
                                controller.tasks
                                    .where(
                                      (task) =>
                                          controller.trackById(task.trackId) !=
                                          null,
                                    )
                                    .map((task) => task.trackId),
                              )
                            : null,
                        icon: const Icon(Icons.select_all),
                        label: const Text('全选任务歌曲'),
                      ),
                    ],
                  ),
                ],
                if (controller.batchOperation != null) ...[
                  BatchProgressPanel(controller: controller),
                  const SizedBox(height: 12),
                ],
                if (controller.settings.enabledFields.isEmpty) ...[
                  NoticePanel(
                    icon: Icons.tune_outlined,
                    title: '尚未选择补全内容',
                    message: '在设置中启用至少一项资料后，即可重新查询。已有结果仍可查看。',
                    action: TextButton(
                      onPressed: onOpenSettings,
                      child: const Text('选择补全内容'),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (controller.completion.sources.isEmpty)
                  Card(
                    color: theme.colorScheme.secondaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('等待接入在线数据源', style: theme.textTheme.titleMedium),
                          const SizedBox(height: 8),
                          const Text('当前可检查本地标签；接入数据源后再查询候选资料。'),
                          TextButton(
                            onPressed: onOpenSettings,
                            child: const Text('查看数据源状态'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (controller.tasks.isEmpty)
                  const EmptyState(
                    icon: Icons.playlist_add_check_outlined,
                    title: '还没有补全任务',
                    description: '从音乐库打开一首歌曲，查询缺失资料后在这里确认结果。',
                  )
                else
                  for (final task in controller.tasks)
                    Card(
                      key: ValueKey('task-${task.trackId}'),
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Checkbox(
                                  key: ValueKey('select-task-${task.trackId}'),
                                  value: controller.selectedTrackIds.contains(
                                    task.trackId,
                                  ),
                                  semanticLabel: '选择 ${task.trackTitle}',
                                  onChanged:
                                      controller.canOperate &&
                                          controller.trackById(task.trackId) !=
                                              null
                                      ? (_) => controller.toggleTrackSelection(
                                          task.trackId,
                                        )
                                      : null,
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Icon(
                                    switch (task.status) {
                                      TaskStatus.waitingForSource =>
                                        Icons.hourglass_empty,
                                      TaskStatus.needsReview =>
                                        Icons.fact_check_outlined,
                                      TaskStatus.readyToSave =>
                                        Icons.playlist_add_check,
                                      TaskStatus.savedOriginal =>
                                        Icons.save_outlined,
                                      TaskStatus.exported =>
                                        Icons.download_done_outlined,
                                      TaskStatus.noMatch => Icons.search_off,
                                      TaskStatus.skipped =>
                                        Icons.check_circle_outline,
                                      TaskStatus.failed => Icons.error_outline,
                                      TaskStatus.outdated =>
                                        Icons.update_outlined,
                                    },
                                    color: task.status == TaskStatus.failed
                                        ? theme.colorScheme.error
                                        : theme.colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        task.trackTitle,
                                        style: theme.textTheme.titleMedium,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${task.status == TaskStatus.waitingForSource && controller.completion.sources.isNotEmpty ? '可重新查询' : task.status.label} · ${formatTaskTime(task.createdAt)}',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              task.message,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (controller.trackById(task.trackId)
                                case final track?)
                              if (track.isInstrumental ||
                                  (controller.isTaskCurrent(task) &&
                                      task.queriedFields.contains(
                                        AudioField.lyrics,
                                      ) &&
                                      !hasText(track.lyrics) &&
                                      !task.suggestions.any(
                                        (item) =>
                                            item.field == AudioField.lyrics,
                                      ))) ...[
                                const SizedBox(height: 12),
                                InstrumentalControl(
                                  track: track,
                                  controller: controller,
                                ),
                              ],
                            if (task.writeError case final error?) ...[
                              const SizedBox(height: 8),
                              Text(
                                error,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            if (controller.trackById(task.trackId) == null) ...[
                              const Text('原歌曲当前不可访问。请返回音乐库刷新或重新授权；历史结果仍可查看。'),
                              const SizedBox(height: 8),
                            ] else if (task.suggestions.isNotEmpty &&
                                !controller.canExportTrack(
                                  controller.trackById(task.trackId)!,
                                ) &&
                                !controller.canSaveOriginalTrack(
                                  controller.trackById(task.trackId)!,
                                )) ...[
                              Text(
                                controller.exporter == null
                                    ? '当前可预览并确认资料，此设备暂不支持写入或导出。'
                                    : '${controller.trackById(task.trackId)!.extension} 可预览并确认；保存支持 MP3、FLAC 和 M4A/MP4。',
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (task.exportedCopyUri case final uri?) ...[
                              ExpansionTile(
                                key: PageStorageKey(
                                  'export-location-${task.trackId}',
                                ),
                                tilePadding: EdgeInsets.zero,
                                title: const Text('查看副本保存位置'),
                                childrenPadding: const EdgeInsets.only(
                                  bottom: 12,
                                ),
                                expandedCrossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  const Text('系统文档位置；副本是否出现在音乐库取决于保存位置与系统索引。'),
                                  const SizedBox(height: 8),
                                  SelectableText(
                                    uri,
                                    key: PageStorageKey(
                                      'export-uri-${task.trackId}',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (task.suggestions.isNotEmpty)
                                  FilledButton.tonalIcon(
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => CandidateReviewPage(
                                          task: task,
                                          controller: controller,
                                        ),
                                      ),
                                    ),
                                    icon: const Icon(Icons.fact_check_outlined),
                                    label: Text(
                                      !controller.isTaskCurrent(task)
                                          ? '查看历史候选'
                                          : task.status == TaskStatus.exported
                                          ? '查看候选资料'
                                          : task.status ==
                                                TaskStatus.readyToSave
                                          ? '修改已确认资料'
                                          : task.status ==
                                                TaskStatus.savedOriginal
                                          ? '查看已保存资料'
                                          : '确认 ${task.suggestions.length} 项候选',
                                    ),
                                  ),
                                if (controller.trackById(task.trackId)
                                    case final track?)
                                  TextButton.icon(
                                    key: ValueKey('retry-task-${task.trackId}'),
                                    onPressed:
                                        controller.canOperate &&
                                            (_isManual(task)
                                                ? track.detailsLoaded &&
                                                      track.readError == null
                                                : task.isRepair
                                                ? task.queriedFields.isNotEmpty
                                                : controller
                                                      .settings
                                                      .enabledFields
                                                      .isNotEmpty)
                                        ? () => _retry(context, task, track)
                                        : null,
                                    icon: Icon(
                                      _isManual(task)
                                          ? Icons.edit_note
                                          : Icons.refresh,
                                    ),
                                    label: Text(
                                      _isManual(task) ? '继续编辑草稿' : '重新查询',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
          if (selectedIds.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * 0.5,
              ),
              child: SingleChildScrollView(
                child: LibrarySelectionToolbar(
                  controller: controller,
                  visibleIds: visibleIds,
                  selectedIds: selectedIds,
                  allVisibleSelected:
                      visibleIds.isNotEmpty &&
                      visibleIds.every(selectedIds.contains),
                  onEnd: controller.clearSelection,
                  toolbarKey: const ValueKey('fixed-task-selection-toolbar'),
                  selectAllKey: const ValueKey('select-all-task-tracks'),
                  endKey: const ValueKey('end-task-selection'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
