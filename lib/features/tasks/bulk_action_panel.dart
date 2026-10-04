import 'package:flutter/material.dart';

import '../../core/models/completion_task.dart';
import '../library/library_controller.dart';
import 'recommended_batch_review_page.dart';

Future<void> confirmBatchQuery(
  BuildContext context,
  LibraryController controller,
  Set<String> trackIds, {
  VoidCallback? onStart,
}) async {
  if (!controller.canOperate || trackIds.isEmpty) return;
  var missingOnly = false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('查询 ${trackIds.length} 首歌曲？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '根据歌曲已有标签和文件名，自动检索元数据、封面与歌词；来源有资料且能可靠匹配时才提供候选。无需填写表单。',
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                key: const ValueKey('batch-query-missing-only'),
                contentPadding: EdgeInsets.zero,
                title: const Text('仅补全缺失信息'),
                subtitle: Text(
                  missingOnly ? '按设置中的补全项目查询缺失项' : '默认完整检索，也可修复已有错误资料',
                ),
                value: missingOnly,
                onChanged: controller.settings.enabledFields.isEmpty
                    ? null
                    : (value) => setDialogState(() => missingOnly = value),
              ),
              const Text(
                '只发送歌名、歌手、专辑和时长，不上传音频。\n\n查询不会修改文件。查看结果时会预选可靠且无冲突的缺失项；已有资料和不确定项保留原值。重新查询会替换旧候选并清除之前的确认，可随时停止后续歌曲。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始查询'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || !context.mounted || !controller.canOperate) return;
  onStart?.call();
  if (missingOnly) {
    await controller.complete(trackIds: trackIds);
  } else {
    await controller.queryAutomaticRepair(trackIds: trackIds);
  }
}

/// Opens the same explicit batch review used by the library toolbar.
class BulkActionPanel extends StatelessWidget {
  const BulkActionPanel({
    super.key,
    required this.controller,
    this.onQueryStart,
  });
  final LibraryController controller;
  final VoidCallback? onQueryStart;

  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedTrackIds;
    if (selected.isEmpty) return const SizedBox.shrink();
    final reviewable = controller.tasks
        .where(
          (task) =>
              selected.contains(task.trackId) &&
              controller.isTaskCurrent(task) &&
              task.suggestions.isNotEmpty,
        )
        .length;
    final approved = controller.tasks
        .where(
          (task) =>
              selected.contains(task.trackId) &&
              task.status != TaskStatus.savedOriginal &&
              controller.approvedSuggestionsFor(task).isNotEmpty,
        )
        .length;
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('已选 ${selected.length} 首 · 已确认 $approved 首'),
                ),
                TextButton(
                  onPressed: controller.canOperate
                      ? controller.clearSelection
                      : null,
                  child: const Text('清空选择'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text('先看一眼本次修改，再统一应用；已有资料和有分歧的候选不会默认替换。'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('bulk-save-original'),
                  onPressed: controller.canOperate && reviewable > 0
                      ? () => reviewBatchChanges(
                          context,
                          controller,
                          Set<String>.of(selected),
                        )
                      : null,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('查看并应用'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('bulk-query-selected'),
                  onPressed:
                      controller.canOperate &&
                          controller.completion.availableFields.isNotEmpty
                      ? () => confirmBatchQuery(
                          context,
                          controller,
                          Set<String>.of(selected),
                          onStart: onQueryStart,
                        )
                      : null,
                  icon: const Icon(Icons.search),
                  label: const Text('自动检索所选'),
                ),
                TextButton.icon(
                  key: const ValueKey('bulk-export-copies'),
                  onPressed: controller.canOperate && reviewable > 0
                      ? () => reviewBatchChanges(
                          context,
                          controller,
                          Set<String>.of(selected),
                          exportCopies: true,
                        )
                      : null,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('批量导出副本'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
