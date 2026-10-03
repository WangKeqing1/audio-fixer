import 'package:flutter/material.dart';

import '../../core/models/completion_task.dart';
import '../library/library_controller.dart';

Future<void> confirmBatchQuery(
  BuildContext context,
  LibraryController controller,
  Set<String> trackIds, {
  VoidCallback? onStart,
}) async {
  if (!controller.canOperate || trackIds.isEmpty) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('查询 ${trackIds.length} 首歌曲？'),
      content: const SingleChildScrollView(
        child: Text(
          '先检查文件标签，再查询缺失资料。只发送歌名、歌手、专辑和时长，不上传音频。\n\n查询不会修改文件，也不会自动勾选候选。重新查询会替换所选歌曲的旧候选并清除之前的确认，请逐首确认后再批量保存。可随时停止后续歌曲。',
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
  );
  if (confirmed != true || !context.mounted || !controller.canOperate) return;
  onStart?.call();
  await controller.complete(trackIds: trackIds);
}

/// All write actions here consume already-confirmed candidates only.
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
            const Text('仅保存逐项确认过的资料；未确认、已保存或不可用的歌曲将跳过。'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('bulk-save-original'),
                  onPressed: controller.canOperate && approved > 0
                      ? () => controller.saveSelectedCandidates()
                      : null,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('批量保存到原文件'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('bulk-query-selected'),
                  onPressed:
                      controller.canOperate &&
                          controller.settings.enabledFields.isNotEmpty
                      ? () => confirmBatchQuery(
                          context,
                          controller,
                          Set<String>.of(selected),
                          onStart: onQueryStart,
                        )
                      : null,
                  icon: const Icon(Icons.search),
                  label: const Text('查询所选'),
                ),
                TextButton.icon(
                  key: const ValueKey('bulk-export-copies'),
                  onPressed: controller.canOperate && approved > 0
                      ? () => controller.saveSelectedCandidates(
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
