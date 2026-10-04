import 'package:flutter/material.dart';

import '../../core/models/batch_operation.dart';
import '../library/library_controller.dart';

class BatchProgressPanel extends StatelessWidget {
  const BatchProgressPanel({
    super.key,
    required this.controller,
    this.showStopAction = true,
    this.showRetryAction = true,
  });
  final LibraryController controller;
  final bool showStopAction;
  final bool showRetryAction;

  @override
  Widget build(BuildContext context) {
    final batch = controller.batchOperation;
    if (batch == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final action = switch (batch.kind) {
      BatchOperationKind.identify => '批量查询',
      BatchOperationKind.saveOriginal => '批量保存原文件',
      BatchOperationKind.exportCopies => '批量导出副本',
    };
    return Card(
      key: const ValueKey('batch-progress'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$action${batch.isRunning ? '进行中' : '结果'}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (batch.isRunning) ...[
              LinearProgressIndicator(value: batch.progress),
              const SizedBox(height: 8),
            ],
            Semantics(liveRegion: true, child: Text(batch.summary)),
            if (batch.isRunning && showStopAction)
              TextButton.icon(
                onPressed: batch.stopRequested ? null : controller.stopBatch,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(batch.stopRequested ? '等待当前歌曲完成…' : '停止后续歌曲'),
              ),
            if (!batch.isRunning &&
                showRetryAction &&
                controller.hasRetryableBatchFailures)
              OutlinedButton.icon(
                key: const ValueKey('retry-batch-failures'),
                onPressed: controller.canOperate
                    ? controller.retryFailedBatch
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('重试失败项'),
              ),
            ExpansionTile(
              key: PageStorageKey('batch-details-${batch.kind.name}'),
              tilePadding: EdgeInsets.zero,
              title: Text('逐首结果（${batch.completedCount}/${batch.totalCount}）'),
              children: [
                for (final item in batch.items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      switch (item.status) {
                        BatchItemStatus.queued => Icons.schedule,
                        BatchItemStatus.running => Icons.sync,
                        BatchItemStatus.needsReview =>
                          Icons.fact_check_outlined,
                        BatchItemStatus.savedOriginal =>
                          Icons.check_circle_outline,
                        BatchItemStatus.exported =>
                          Icons.download_done_outlined,
                        BatchItemStatus.skipped => Icons.skip_next_outlined,
                        BatchItemStatus.cancelled => Icons.cancel_outlined,
                        BatchItemStatus.failed => Icons.error_outline,
                      },
                      color: item.status == BatchItemStatus.failed
                          ? theme.colorScheme.error
                          : null,
                    ),
                    title: Text(item.trackTitle),
                    subtitle: Text(item.message),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
