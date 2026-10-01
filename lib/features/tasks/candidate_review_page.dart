import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/models/completion_task.dart';
import '../library/library_controller.dart';

class CandidateReviewPage extends StatefulWidget {
  const CandidateReviewPage({
    super.key,
    required this.task,
    required this.controller,
  });
  final CompletionTask task;
  final LibraryController controller;

  @override
  State<CandidateReviewPage> createState() => _CandidateReviewPageState();
}

class _CandidateReviewPageState extends State<CandidateReviewPage> {
  final Map<AudioField, FieldSuggestion> _selected = {};

  @override
  void initState() {
    super.initState();
    for (final candidate in widget.task.suggestions) {
      _selected.putIfAbsent(candidate.field, () => candidate);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final track = controller.trackById(widget.task.trackId);
      final theme = Theme.of(context);
      final canExport = track != null && controller.canExportTrack(track);
      return Scaffold(
        appBar: AppBar(title: const Text('确认候选资料')),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    widget.task.trackTitle,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '选择要写入副本的资料，保存前将再次校验。',
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 20),
                  Card(
                    color: theme.colorScheme.secondaryContainer,
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.verified_user_outlined),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '原音频保持不变\n仅补入缺失项。逐项确认后，由系统弹窗选择新副本的保存位置。',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.task.message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (final candidate in widget.task.suggestions)
                    Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CheckboxListTile(
                            value: _selected[candidate.field] == candidate,
                            onChanged: controller.canOperate
                                ? (checked) => setState(() {
                                    if (checked == true) {
                                      _selected[candidate.field] = candidate;
                                    } else {
                                      _selected.remove(candidate.field);
                                    }
                                  })
                                : null,
                            title: Text(
                              candidate.field.label,
                              style: theme.textTheme.titleMedium,
                            ),
                            subtitle: Text('来源：${candidate.source}'),
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '当前：${candidate.field == AudioField.artwork ? (hasText(track?.artworkPath) ? '已有封面' : '无内嵌封面') : (track?.valueOf(candidate.field) ?? '未读取到')}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                if (candidate.field == AudioField.artwork)
                                  _ArtworkPreview(value: candidate.value)
                                else if (candidate.field == AudioField.lyrics)
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 260,
                                    ),
                                    child: Scrollbar(
                                      child: SingleChildScrollView(
                                        primary: false,
                                        child: SelectableText(candidate.value),
                                      ),
                                    ),
                                  )
                                else
                                  SelectableText(
                                    candidate.value,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                if (candidate.matchDescription != null) ...[
                                  const SizedBox(height: 12),
                                  Text(
                                    candidate.matchDescription!,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                                if (candidate.sourceUrl != null) ...[
                                  const SizedBox(height: 8),
                                  SelectableText(
                                    candidate.sourceUrl!,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!canExport)
                    Text(
                      track == null
                          ? '此歌曲已不可访问，请返回音乐库刷新。'
                          : '此格式当前仅支持预览。安全导出支持 MP3、FLAC 和 M4A/MP4。',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  if (controller.isBusy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(controller.progress ?? '正在准备副本…'),
                  ],
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: FilledButton.icon(
              onPressed:
                  controller.canOperate && canExport && _selected.isNotEmpty
                  ? () async {
                      final saved = await controller.exportCandidates(
                        widget.task,
                        _selected.values.toList(),
                      );
                      if (saved && context.mounted) Navigator.of(context).pop();
                    }
                  : null,
              icon: const Icon(Icons.save_alt),
              label: Text(
                controller.isBusy ? '正在校验并保存…' : '导出副本（${_selected.length} 项）',
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ArtworkPreview extends StatelessWidget {
  const _ArtworkPreview({required this.value});
  final String value;
  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        !(uri.host == 'coverartarchive.org' ||
            uri.host == 'archive.org' ||
            uri.host.endsWith('.archive.org'))) {
      return const Text('封面地址不可用，请重新查询。');
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        value,
        height: 200,
        width: 200,
        fit: BoxFit.contain,
        semanticLabel: '在线候选封面',
        errorBuilder: (_, _, _) =>
            const SizedBox(height: 120, child: Center(child: Text('封面预览加载失败'))),
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              ),
      ),
    );
  }
}
