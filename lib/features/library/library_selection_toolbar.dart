import 'package:flutter/material.dart';

import '../../core/models/completion_task.dart';
import '../tasks/bulk_action_panel.dart';
import 'library_controller.dart';

/// A sibling of the song scroll view, so actions never move with the list.
class LibrarySelectionToolbar extends StatelessWidget {
  const LibrarySelectionToolbar({
    super.key,
    required this.controller,
    required this.visibleIds,
    required this.selectedIds,
    required this.allVisibleSelected,
    required this.onEnd,
    this.onOpenTasks,
    this.toolbarKey = const ValueKey('fixed-library-selection-toolbar'),
    this.selectAllKey = const ValueKey('select-visible-tracks'),
    this.endKey = const ValueKey('toggle-library-selection'),
  });

  final LibraryController controller;
  final Set<String> visibleIds;
  final Set<String> selectedIds;
  final bool allVisibleSelected;
  final VoidCallback onEnd;
  final VoidCallback? onOpenTasks;
  final Key toolbarKey;
  final Key selectAllKey;
  final Key endKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final approved = controller.tasks
        .where(
          (task) =>
              selectedIds.contains(task.trackId) &&
              task.status != TaskStatus.savedOriginal &&
              controller.approvedSuggestionsFor(task).isNotEmpty,
        )
        .length;
    final canWrite = controller.canOperate && approved > 0;
    return Material(
      key: toolbarKey,
      color: colors.surfaceContainer,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        '已选 ${selectedIds.length} 首',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ),
                  IconButton(
                    key: selectAllKey,
                    tooltip: allVisibleSelected ? '取消当前列表全选' : '全选当前列表',
                    onPressed: controller.canOperate && visibleIds.isNotEmpty
                        ? () {
                            if (allVisibleSelected) {
                              controller.retainSelection(const <String>{});
                            } else {
                              controller.retainSelection(visibleIds);
                              controller.selectTracks(visibleIds);
                            }
                          }
                        : null,
                    icon: Icon(
                      allVisibleSelected ? Icons.deselect : Icons.select_all,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('clear-library-selection'),
                    tooltip: '清空选择',
                    onPressed: controller.canOperate && selectedIds.isNotEmpty
                        ? controller.clearSelection
                        : null,
                    icon: const Icon(Icons.remove_done),
                  ),
                  IconButton(
                    key: endKey,
                    tooltip: '结束多选',
                    onPressed: controller.canOperate ? onEnd : null,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('bulk-query-selected'),
                      onPressed:
                          controller.canOperate &&
                              selectedIds.isNotEmpty &&
                              controller.settings.enabledFields.isNotEmpty
                          ? () => confirmBatchQuery(
                              context,
                              controller,
                              Set<String>.of(selectedIds),
                              onStart: onOpenTasks,
                            )
                          : null,
                      child: const Text('查询所选', textAlign: TextAlign.center),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('bulk-save-original'),
                      onPressed: canWrite
                          ? () => controller.saveSelectedCandidates(
                              trackIds: selectedIds,
                            )
                          : null,
                      child: const Text('保存原文件', textAlign: TextAlign.center),
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: const ValueKey('library-bulk-more'),
                    tooltip: '更多批量操作',
                    enabled: controller.canOperate,
                    onSelected: (action) {
                      if (action == 'export') {
                        controller.saveSelectedCandidates(
                          exportCopies: true,
                          trackIds: selectedIds,
                        );
                      } else if (action == 'review') {
                        onOpenTasks?.call();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        key: const ValueKey('bulk-export-copies'),
                        value: 'export',
                        enabled: canWrite,
                        child: const Text('批量导出副本'),
                      ),
                      if (onOpenTasks != null)
                        PopupMenuItem(
                          key: const ValueKey('open-tasks'),
                          value: 'review',
                          enabled: onOpenTasks != null,
                          child: const Text('前往任务确认资料'),
                        ),
                    ],
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '已确认 $approved 首 · 仅保存已确认资料',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
