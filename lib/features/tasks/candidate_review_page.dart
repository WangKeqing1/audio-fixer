import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/models/completion_task.dart';
import '../../shared/widgets/notice_panel.dart';
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
  final ScrollController _scrollController = ScrollController();
  bool _exporting = false;
  String? _exportNotice;

  @override
  void initState() {
    super.initState();
    for (final candidate in widget.task.suggestions) {
      if (hasText(candidate.value)) {
        _selected.putIfAbsent(candidate.field, () => candidate);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _export(List<FieldSuggestion> selected) async {
    if (_exporting || !widget.controller.canOperate) return;
    final route = ModalRoute.of(context);
    final revision = widget.controller.noticeRevision;
    setState(() {
      _exporting = true;
      _exportNotice = null;
    });
    final saved = await widget.controller.exportCandidates(
      widget.task,
      selected,
    );
    if (!mounted) return;
    // Never dismiss a newer route if the save finishes while another screen
    // is on top of this one.
    if (saved && route?.isCurrent == true) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _exporting = false;
      _exportNotice = widget.controller.noticeRevision != revision
          ? widget.controller.notice
          : '保存未完成，请稍后重试。';
    });
    if (_scrollController.hasClients) {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _queryAgain(AudioTrack track) async {
    final route = ModalRoute.of(context);
    await widget.controller.complete(track: track);
    if (!mounted || route?.isCurrent != true) return;
    final latest = widget.controller.taskForTrack(track.id);
    if (latest == null || !widget.controller.isTaskCurrent(latest)) return;
    if (latest.suggestions.isEmpty) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) =>
              CandidateReviewPage(task: latest, controller: widget.controller),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final track = controller.trackById(widget.task.trackId);
      final current = controller.taskForTrack(widget.task.trackId);
      final isStale = !controller.isTaskCurrent(widget.task);
      final result =
          current != null && current.createdAt == widget.task.createdAt
          ? current
          : widget.task;
      final theme = Theme.of(context);
      final selected = _selected.values
          .where((candidate) => !hasText(track?.valueOf(candidate.field)))
          .toList();
      final String? unavailableReason;
      if (track == null) {
        unavailableReason = '此歌曲当前不可访问，可能已移除或需要重新授权。请返回音乐库刷新。';
      } else if (current?.status == TaskStatus.outdated) {
        unavailableReason = '原歌曲已发生变化，旧候选仅供参考。请重新查询后再导出。';
      } else if (!track.detailsLoaded || track.readError != null) {
        unavailableReason = '原歌曲的资料需要重新检查。请返回音乐库读取歌曲资料，再重新查询。';
      } else if (isStale) {
        unavailableReason = '歌曲或候选已更新，这份结果仅供查看。请打开最新结果后再导出。';
      } else if (controller.exporter == null) {
        unavailableReason = '此设备尚未启用安全导出，可继续预览候选资料。';
      } else if (!controller.canExportTrack(track)) {
        unavailableReason =
            '${track.extension} 格式当前仅支持预览。安全导出支持 MP3、FLAC 和 M4A/MP4。';
      } else {
        unavailableReason = null;
      }
      final canExport = unavailableReason == null;
      return PopScope(
        canPop: !_exporting,
        child: Scaffold(
          appBar: AppBar(title: const Text('确认候选资料')),
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  controller: _scrollController,
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
                    if (_exportNotice != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: NoticePanel(
                          icon: Icons.info_outline,
                          title: '保存结果',
                          message: _exportNotice!,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (unavailableReason != null) ...[
                      NoticePanel(
                        icon: Icons.info_outline,
                        title: '当前无法导出',
                        message: unavailableReason,
                        action:
                            isStale &&
                                current != null &&
                                controller.isTaskCurrent(current) &&
                                current.suggestions.isNotEmpty
                            ? TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pushReplacement(
                                      MaterialPageRoute<void>(
                                        builder: (_) => CandidateReviewPage(
                                          task: current,
                                          controller: controller,
                                        ),
                                      ),
                                    ),
                                child: const Text('查看最新结果'),
                              )
                            : isStale && track != null
                            ? TextButton(
                                onPressed:
                                    controller.canOperate &&
                                        controller
                                            .settings
                                            .enabledFields
                                            .isNotEmpty
                                    ? () => _queryAgain(track)
                                    : null,
                                child: const Text('重新查询'),
                              )
                            : null,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (result.status == TaskStatus.exported) ...[
                      const NoticePanel(
                        icon: Icons.download_done_outlined,
                        title: '已导出过副本',
                        message: '原音频保持不变。再次导出会重新选择保存位置并创建另一份副本。',
                      ),
                      if (hasText(result.exportedCopyUri)) ...[
                        const SizedBox(height: 8),
                        const Text('上次保存的系统文档位置'),
                        SelectableText(result.exportedCopyUri!),
                      ],
                      const SizedBox(height: 16),
                    ],
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
                      result.message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (widget.task.suggestions.isEmpty)
                      const NoticePanel(
                        icon: Icons.search_off,
                        title: '没有可确认的候选',
                        message: '请返回查看查询结果，或在补全任务中重新查询。',
                      ),
                    for (final candidate in widget.task.suggestions)
                      Card(
                        margin: const EdgeInsets.only(bottom: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CheckboxListTile(
                              value:
                                  !hasText(track?.valueOf(candidate.field)) &&
                                  _selected[candidate.field] == candidate,
                              onChanged:
                                  controller.canOperate &&
                                      !_exporting &&
                                      canExport &&
                                      hasText(candidate.value) &&
                                      !hasText(track?.valueOf(candidate.field))
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
                              subtitle: Text(
                                '来源：${candidate.source}'
                                '${hasText(track?.valueOf(candidate.field)) ? '\n此项已有资料，不会覆盖' : ''}',
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '当前：${candidate.field == AudioField.artwork ? (hasText(track?.artworkPath) ? '已有封面' : '无内嵌封面') : (hasText(track?.valueOf(candidate.field)) ? track!.valueOf(candidate.field) : '未读取到')}',
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
                                          child: SelectableText(
                                            candidate.value,
                                          ),
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
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
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
                    if (controller.isBusy && !_exporting) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(controller.progress ?? '正在处理…'),
                    ],
                  ],
                ),
              ),
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_exporting) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    const Text(
                      '保存期间请留在此页，可在系统保存弹窗中取消。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (canExport && selected.isEmpty) ...[
                    const Text('请至少选择一项要写入的资料', textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                  ],
                  FilledButton.icon(
                    onPressed:
                        controller.canOperate &&
                            !_exporting &&
                            canExport &&
                            selected.isNotEmpty
                        ? () => _export(selected)
                        : null,
                    icon: const Icon(Icons.save_alt),
                    label: Text(
                      _exporting
                          ? '正在校验并保存…'
                          : '${result.status == TaskStatus.exported ? '再次导出副本' : '导出副本'}（${selected.length} 项）',
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
