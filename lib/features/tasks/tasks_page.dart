import 'package:flutter/material.dart';

import '../../core/models/completion_task.dart';
import '../../core/models/audio_track.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/empty_state.dart';
import '../library/library_controller.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({
    super.key,
    required this.controller,
    required this.onOpenSettings,
  });
  final LibraryController controller;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      key: const PageStorageKey('tasks'),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (controller.completion.sources.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Material(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '等待接入在线数据源',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '当前版本已支持系统音乐库和标签检查。元数据、歌词与封面的在线查询将在后续接入。',
                      style: TextStyle(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: onOpenSettings,
                      child: const Text('查看数据源状态'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (controller.completion.sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Text(
              '从在线来源查询缺失资料。候选结果保留来源，尚未写入音频。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (controller.tasks.isEmpty)
          const EmptyState(
            icon: Icons.playlist_add_check_outlined,
            title: '还没有补全任务',
            description: '点击音乐库右上角的补全按钮，或进入歌曲资料单独补全。',
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '每首歌曲保留最近一次检查结果',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final task in controller.tasks)
            ExpansionTile(
              key: ValueKey(task.trackId),
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 8,
              ),
              leading: Icon(
                switch (task.status) {
                  TaskStatus.waitingForSource => Icons.hourglass_empty,
                  TaskStatus.needsReview => Icons.fact_check_outlined,
                  TaskStatus.noMatch => Icons.search_off,
                  TaskStatus.skipped => Icons.check_circle_outline,
                  TaskStatus.failed => Icons.error_outline,
                },
                color: task.status == TaskStatus.failed
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              title: Text(
                task.trackTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${task.status == TaskStatus.waitingForSource && controller.completion.sources.isNotEmpty ? '可重新查询' : task.status.label} · ${formatTaskTime(task.createdAt)}',
              ),
              childrenPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              expandedAlignment: Alignment.centerLeft,
              children: [
                Text(
                  task.status == TaskStatus.waitingForSource &&
                          controller.completion.sources.isNotEmpty
                      ? '在线数据源已接入，点击重新查询获取候选资料。'
                      : task.message,
                ),
                for (final candidate in task.suggestions)
                  _SuggestionPreview(candidate: candidate),
                if (controller.trackById(task.trackId) case final track?)
                  TextButton.icon(
                    onPressed: controller.canOperate
                        ? () => controller.complete(track: track)
                        : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新查询'),
                  ),
              ],
            ),
        ],
      ],
    );
  }
}

class _SuggestionPreview extends StatelessWidget {
  const _SuggestionPreview({required this.candidate});
  final FieldSuggestion candidate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUri = Uri.tryParse(candidate.value);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(candidate.field.label, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (candidate.field == AudioField.artwork)
            if (imageUri != null && imageUri.scheme == 'https')
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  candidate.value,
                  width: 240,
                  height: 240,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox(
                    height: 80,
                    child: Center(child: Text('封面预览加载失败，可稍后重新查询。')),
                  ),
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : const SizedBox(
                          height: 240,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                ),
              )
            else
              const Text('封面地址不可用。')
          else if (candidate.field == AudioField.lyrics)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                child: SelectableText(candidate.value),
              ),
            )
          else
            SelectableText(candidate.value),
          const SizedBox(height: 8),
          Text('来源：${candidate.source}', style: theme.textTheme.bodySmall),
          if (candidate.matchDescription != null)
            Text(candidate.matchDescription!, style: theme.textTheme.bodySmall),
          if (candidate.sourceUrl != null)
            SelectableText(
              candidate.sourceUrl!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }
}
