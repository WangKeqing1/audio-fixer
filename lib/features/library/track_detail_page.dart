import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/track_artwork.dart';
import 'library_controller.dart';
import '../tasks/candidate_review_page.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.readDetails(widget.track.id);
    });
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
      return Scaffold(
        appBar: AppBar(title: const Text('歌曲资料')),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
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
                  if (!track.detailsLoaded) ...[
                    if (controller.isBusy) const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(controller.isBusy ? '正在读取文件标签…' : '文件标签尚未检查。'),
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
                        for (final field in AudioField.values)
                          Chip(
                            avatar: Icon(
                              track.missingFields.contains(field)
                                  ? Icons.remove_circle_outline
                                  : Icons.check_circle_outline,
                              size: 18,
                            ),
                            label: Text(
                              '${field.label}${track.missingFields.contains(field) ? '缺失' : '已有'}',
                            ),
                          ),
                      ],
                    ),
                  if (track.readError != null && track.isDeviceTrack)
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
                  _FieldRow(label: '歌名', value: track.title),
                  _FieldRow(label: '歌手', value: track.artist),
                  _FieldRow(label: '专辑', value: track.album),
                  _FieldRow(label: '年份', value: track.year?.toString()),
                  _FieldRow(label: '文件名', value: track.fileName),
                  const Divider(height: 40),
                  Text('歌词', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 16),
                  SelectableText(
                    hasText(track.lyrics)
                        ? track.lyrics!
                        : track.readError != null || !track.detailsLoaded
                        ? '歌词读取状态未知。'
                        : '音频中尚未发现内嵌歌词。',
                  ),
                  const SizedBox(height: 24),
                  if (controller.taskForTrack(track.id) case final task?)
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
                  const SizedBox(height: 32),
                  Text(
                    controller.completion.sources.isEmpty
                        ? '在线补全的数据源尚未接入。当前可检查缺失信息并创建任务。'
                        : '在线查询缺失资料，逐项确认后可导出音频副本。已有资料与原音频保持不变。',
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
            child: controller.isCompleting
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                  )
                : FilledButton.icon(
                    onPressed:
                        controller.canOperate &&
                            track.needsCompletion &&
                            controller.settings.enabledFields.isNotEmpty
                        ? () async {
                            await controller.complete(track: track);
                            final task = controller.taskForTrack(track.id);
                            if (context.mounted &&
                                task != null &&
                                task.suggestions.isNotEmpty) {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => CandidateReviewPage(
                                    task: task,
                                    controller: controller,
                                  ),
                                ),
                              );
                            }
                          }
                        : null,
                    icon: const Icon(Icons.auto_fix_high_outlined),
                    label: Text(controller.isBusy ? '正在处理…' : '补全缺失信息'),
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
