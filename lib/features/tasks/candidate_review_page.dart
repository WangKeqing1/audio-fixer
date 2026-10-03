import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/models/completion_task.dart';
import '../../core/services/export/audio_copy_exporter.dart';
import '../../shared/widgets/notice_panel.dart';
import '../../shared/widgets/source_query_status.dart';
import '../../shared/widgets/instrumental_control.dart';
import '../../shared/widgets/translation_privacy.dart';
import '../../shared/widgets/track_artwork.dart';
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
  final Map<FieldSuggestion, bool> _translationChoices = {};
  final ScrollController _scrollController = ScrollController();
  bool _exporting = false;
  bool _translationWorking = false;
  bool _translationProcessing = false;
  String? _exportNotice;

  @override
  void initState() {
    super.initState();
    final approved = widget.controller.approvedSuggestionsFor(widget.task);
    for (final candidate in widget.task.suggestions) {
      final matches = approved.where(candidate.permits);
      if (matches.isNotEmpty) {
        _selected[candidate.field] = candidate;
        _translationChoices[candidate] =
            matches.first.includeChineseTranslation;
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _save(
    List<FieldSuggestion> selected, {
    bool exportCopy = false,
    bool approveOnly = false,
    bool revokeOnly = false,
  }) async {
    if (_exporting || !widget.controller.canOperate) return;
    final route = ModalRoute.of(context);
    final revision = widget.controller.noticeRevision;
    setState(() {
      _exporting = true;
      _exportNotice = null;
    });
    final saved = revokeOnly
        ? await widget.controller.revokeCandidateApproval(widget.task)
        : approveOnly
        ? await widget.controller.approveCandidates(widget.task, selected)
        : exportCopy
        ? await widget.controller.exportCandidates(widget.task, selected)
        : await widget.controller.saveCandidates(widget.task, selected);
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
    if (widget.task.suggestions.any((item) => item.source == '手动编辑')) return;
    final route = ModalRoute.of(context);
    await widget.controller.retryTaskQuery(widget.task);
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

  Future<void> _prepareTranslation(FieldSuggestion candidate) async {
    final controller = widget.controller;
    final translator = controller.completion.translator;
    final track = controller.trackById(widget.task.trackId);
    final route = ModalRoute.of(context);
    if (_translationWorking ||
        _exporting ||
        !controller.canOperate ||
        translator == null ||
        track == null ||
        track.isInstrumental ||
        !controller.isTaskCurrent(widget.task)) {
      return;
    }
    bool stillNeedsTranslation() =>
        controller.canOperate &&
        controller.isTaskCurrent(widget.task) &&
        controller.trackById(track.id)?.isInstrumental == false;
    setState(() {
      _translationWorking = true;
      _exportNotice = null;
    });
    try {
      if (!controller.settings.onDeviceTranslationEnabled) {
        if (!await showTranslationPrivacy(context) || !mounted) return;
        await controller.updateSettings(
          controller.settings.copyWith(onDeviceTranslationEnabled: true),
        );
        if (!controller.settings.onDeviceTranslationEnabled) {
          throw StateError('本机翻译设置未保存，请重试。');
        }
      }
      if (!mounted || route?.isCurrent != true || !stillNeedsTranslation()) {
        return;
      }
      setState(() => _translationProcessing = true);
      final status = await translator.inspect(
        candidate.lyricsContent!.original,
      );
      if (!mounted || route?.isCurrent != true || !stillNeedsTranslation()) {
        return;
      }
      setState(() => _translationProcessing = false);
      if (!status.canTranslate) {
        setState(() => _exportNotice = status.message ?? '无法确认可翻译的原文语言，保留原歌词。');
        return;
      }
      if (!status.ready && status.missingModels.isEmpty) {
        setState(() => _exportNotice = status.message ?? '无法确认模型状态，请稍后重试。');
        return;
      }
      if (!status.ready) {
        final count = status.missingModels.length;
        final approved =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('下载本机翻译模型？'),
                content: Text(
                  '当前语言：${status.sourceLanguage} → 中文\n'
                  '需要模型：${status.missingModels.join('、')}\n'
                  '约 ${count * 30} MB（约 30 MB/语言，以实际下载为准）。仅在 Wi-Fi 下下载。模型保留在本机，后续翻译可离线进行。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('下载并使用 Google Translate'),
                  ),
                ],
              ),
            ) ??
            false;
        if (!approved ||
            !mounted ||
            route?.isCurrent != true ||
            !stillNeedsTranslation()) {
          return;
        }
        setState(() => _translationProcessing = true);
        await translator.downloadModels(status.sourceLanguage);
      }
      if (!mounted || route?.isCurrent != true || !stillNeedsTranslation()) {
        return;
      }
      // Re-query uses the source cache and produces a new reviewable candidate;
      // existing approvals are never silently changed into translated saves.
      await _queryAgain(track);
    } catch (error) {
      if (mounted) {
        setState(
          () => _exportNotice =
              '本机翻译暂不可用，请检查 Wi-Fi 和存储空间后重试。已确认的下载可能仍在继续；原歌词未改变。',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _translationWorking = false;
          _translationProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final track = controller.trackById(widget.task.trackId);
      final current = controller.taskForTrack(widget.task.trackId);
      final isManualRepair = widget.task.suggestions.any(
        (candidate) => candidate.source == '手动编辑',
      );
      final isStale = !controller.isTaskCurrent(widget.task);
      final result =
          current != null && current.createdAt == widget.task.createdAt
          ? current
          : widget.task;
      final theme = Theme.of(context);
      final selected = _selected.values
          .where(
            (candidate) =>
                (candidate.replaceExisting ||
                    !hasText(track?.valueOf(candidate.field))) &&
                !(track?.isInstrumental == true &&
                    candidate.field == AudioField.lyrics),
          )
          .map(
            (candidate) => candidate.withChineseTranslation(
              _translationChoices[candidate] ??
                  controller.settings.includeChineseTranslation,
            ),
          )
          .toList();
      final String? unavailableReason;
      if (track == null) {
        unavailableReason = '此歌曲当前不可访问，可能已移除或需要重新授权。请返回音乐库刷新。';
      } else if (current?.status == TaskStatus.outdated) {
        unavailableReason = isManualRepair
            ? '原歌曲已发生变化，旧修改仅供参考。请返回歌曲资料页重新编辑后再保存。'
            : '原歌曲已发生变化，旧候选仅供参考。请重新查询后再保存。';
      } else if (!track.detailsLoaded || track.readError != null) {
        unavailableReason = '原歌曲的资料需要重新检查。请返回音乐库读取歌曲资料，再重新查询。';
      } else if (isStale) {
        unavailableReason = '歌曲或候选已更新，这份结果仅供查看。请打开最新结果后再保存。';
      } else {
        unavailableReason = null;
      }
      final canReview = unavailableReason == null;
      final canSaveOriginal =
          canReview && track != null && controller.canSaveOriginalTrack(track);
      final canExport =
          canReview && track != null && controller.canExportTrack(track);
      final canAct =
          controller.canOperate &&
          !_exporting &&
          !_translationWorking &&
          selected.isNotEmpty;
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
                      '逐项核对旧值与新值并勾选要保存的资料，默认保存到原文件。候选不会自动选中。',
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 20),
                    if (_translationProcessing) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      const Text('正在识别语言、等待模型下载或进行本机翻译。可以返回；已确认的模型下载可能继续。'),
                      const SizedBox(height: 16),
                    ],
                    if (_exportNotice != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: NoticePanel(
                          icon: Icons.info_outline,
                          title: '处理结果',
                          message: _exportNotice!,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (unavailableReason != null) ...[
                      NoticePanel(
                        icon: Icons.info_outline,
                        title: '当前无法保存',
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
                            : isStale && track != null && !isManualRepair
                            ? TextButton(
                                onPressed:
                                    controller.canOperate &&
                                        (widget.task.isRepair
                                            ? widget
                                                  .task
                                                  .queriedFields
                                                  .isNotEmpty
                                            : controller
                                                  .settings
                                                  .enabledFields
                                                  .isNotEmpty)
                                    ? () => _queryAgain(track)
                                    : null,
                                child: const Text('重新查询'),
                              )
                            : null,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (canReview && !canSaveOriginal) ...[
                      NoticePanel(
                        icon: Icons.info_outline,
                        title: '此歌曲暂不支持原位保存',
                        message: canExport
                            ? !track.isDeviceTrack
                                  ? '这首歌曲来自旧版导入的应用内副本，仅支持导出新副本。原位保存适用于系统音乐库中的可写音频，不会修改这份旧版副本。'
                                  : '可以先确认资料，或选择导出副本。原位保存支持可写入的 MP3、FLAC 和 M4A/MP4。'
                            : '${track?.extension ?? ''} 格式当前仅支持预览和确认。保存支持 MP3、FLAC 和 M4A/MP4，并需要文件写入权限。',
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (result.status == TaskStatus.savedOriginal) ...[
                      const NoticePanel(
                        icon: Icons.check_circle_outline,
                        title: '已保存到原文件',
                        message: '已保存所确认的修改，未选择的标签与音频内容保留。',
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (controller
                        .approvedSuggestionsFor(widget.task)
                        .isNotEmpty) ...[
                      NoticePanel(
                        icon: Icons.fact_check_outlined,
                        title: '资料已确认，等待保存',
                        message: '可在此保存，也可返回后批量保存。调整勾选后需再次确认；撤销确认会将此歌曲移出待保存范围。',
                        action: TextButton.icon(
                          key: const ValueKey('revoke-approval'),
                          onPressed:
                              controller.canOperate && !_exporting && canReview
                              ? () => _save([], revokeOnly: true)
                              : null,
                          icon: const Icon(Icons.undo),
                          label: const Text('撤销确认'),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (result.writeError != null &&
                        result.writeError != _exportNotice) ...[
                      NoticePanel(
                        icon: Icons.error_outline,
                        title: '上次保存失败',
                        message: result.writeError!,
                        isError: true,
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
                                '仅保存勾选的项目。标记「将替换已有资料」的项目会覆盖对应旧值，未勾选的标签保留。\n保存前会再次校验文件。保存到原文件可能需要系统授权；也可另行导出副本。',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (result.sourceReports.isNotEmpty)
                      SourceQueryStatusPanel(
                        reports: result.sourceReports,
                        summary:
                            result.status == TaskStatus.skipped ||
                                result.status == TaskStatus.outdated ||
                                result.status == TaskStatus.savedOriginal ||
                                result.status == TaskStatus.exported
                            ? result.message
                            : null,
                        hasCandidates: result.suggestions.isNotEmpty,
                      )
                    else
                      Text(
                        result.message,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (track != null &&
                        (track.isInstrumental ||
                            (canReview &&
                                !hasText(track.lyrics) &&
                                result.queriedFields.contains(
                                  AudioField.lyrics,
                                ) &&
                                !result.suggestions.any(
                                  (item) => item.field == AudioField.lyrics,
                                )))) ...[
                      const SizedBox(height: 16),
                      InstrumentalControl(
                        track: track,
                        controller: controller,
                        enabled: !_exporting && !_translationWorking,
                      ),
                    ],
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
                                  (candidate.replaceExisting ||
                                      !hasText(
                                        track?.valueOf(candidate.field),
                                      )) &&
                                  !(track?.isInstrumental == true &&
                                      candidate.field == AudioField.lyrics) &&
                                  _selected[candidate.field] == candidate,
                              onChanged:
                                  controller.canOperate &&
                                      !_exporting &&
                                      !_translationWorking &&
                                      canReview &&
                                      !(track?.isInstrumental == true &&
                                          candidate.field ==
                                              AudioField.lyrics) &&
                                      hasText(candidate.value) &&
                                      (candidate.replaceExisting ||
                                          !hasText(
                                            track?.valueOf(candidate.field),
                                          ))
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
                                '${hasText(track?.valueOf(candidate.field))
                                    ? candidate.replaceExisting
                                          ? '\n将替换已有资料 · ${candidate.field.label}'
                                          : '\n此项已有资料，不会覆盖'
                                    : '\n补入缺失资料'}',
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if ((candidate.field == AudioField.lyrics ||
                                          candidate.field ==
                                              AudioField.comment) &&
                                      hasText(track?.valueOf(candidate.field)))
                                    ExpansionTile(
                                      tilePadding: EdgeInsets.zero,
                                      title: Text(
                                        '查看当前${candidate.field.label}',
                                      ),
                                      children: [
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxHeight: 180,
                                          ),
                                          child: SingleChildScrollView(
                                            primary: false,
                                            child: SelectableText(
                                              track!.valueOf(candidate.field)!,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  else
                                    SelectableText(
                                      '当前：${candidate.field == AudioField.artwork ? (hasText(track?.artworkPath) ? '已有封面' : '无内嵌封面') : (hasText(track?.valueOf(candidate.field)) ? track!.valueOf(candidate.field) : '未读取到')}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  if (candidate.field == AudioField.artwork &&
                                      hasText(track?.artworkPath)) ...[
                                    const SizedBox(height: 8),
                                    TrackArtwork(
                                      path: track!.artworkPath,
                                      size: 120,
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  Text(
                                    '↓ ${candidate.replaceExisting && hasText(track?.valueOf(candidate.field)) ? '替换为' : '补入'}',
                                    style: theme.textTheme.labelLarge,
                                  ),
                                  const SizedBox(height: 8),
                                  if (candidate.field == AudioField.artwork)
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _ArtworkPreview(value: candidate.value),
                                        const SizedBox(height: 8),
                                        const Text(
                                          '替换正面封面并保留其他类型图片；M4A/MP4 替换首张封面，保留其余图片。',
                                        ),
                                      ],
                                    )
                                  else if (candidate.field == AudioField.lyrics)
                                    _LyricsPreview(
                                      candidate: candidate,
                                      onPrepareTranslation:
                                          controller.canOperate &&
                                              !_exporting &&
                                              !_translationWorking &&
                                              canReview &&
                                              !isManualRepair &&
                                              track?.isInstrumental != true &&
                                              controller
                                                      .completion
                                                      .translator !=
                                                  null &&
                                              !(candidate
                                                      .lyricsContent
                                                      ?.hasChineseTranslation ??
                                                  true)
                                          ? () => _prepareTranslation(candidate)
                                          : null,
                                      includeTranslation:
                                          _translationChoices[candidate] ??
                                          controller
                                              .settings
                                              .includeChineseTranslation,
                                      onChanged:
                                          controller.canOperate &&
                                              !_exporting &&
                                              !_translationWorking &&
                                              track?.isInstrumental != true &&
                                              canReview
                                          ? (value) => setState(() {
                                              _translationChoices[candidate] =
                                                  value;
                                            })
                                          : null,
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
                  if (canReview && selected.isEmpty) ...[
                    const Text('请至少选择一项要写入的资料', textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                  ],
                  FilledButton.icon(
                    key: const ValueKey('save-original'),
                    onPressed: canAct && canSaveOriginal
                        ? () => _save(selected)
                        : null,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                      _exporting ? '正在校验并保存…' : '保存到原文件（${selected.length} 项）',
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('approve-for-batch'),
                    onPressed: canAct && canReview
                        ? () => _save(selected, approveOnly: true)
                        : null,
                    child: const Text(
                      '确认所选资料，稍后批量保存',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('export-copy'),
                    onPressed: canAct && canExport
                        ? () => _save(selected, exportCopy: true)
                        : null,
                    icon: const Icon(Icons.save_alt),
                    label: Text(
                      '${result.status == TaskStatus.exported ? '再次导出副本' : '导出副本'}（${selected.length} 项）',
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

class _ArtworkPreview extends StatefulWidget {
  const _ArtworkPreview({required this.value});
  final String value;

  @override
  State<_ArtworkPreview> createState() => _ArtworkPreviewState();
}

class _ArtworkPreviewState extends State<_ArtworkPreview> {
  Future<Uint8List>? _remote;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ArtworkPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _load();
  }

  void _load() {
    _remote = Uri.tryParse(widget.value)?.scheme == 'https'
        ? loadRemoteArtwork(widget.value)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(widget.value);
    if (uri != null &&
        uri.scheme == 'file' &&
        uri.host.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.path.startsWith('/')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File.fromUri(uri),
          height: 200,
          width: 200,
          fit: BoxFit.contain,
          semanticLabel: '本机候选封面',
          errorBuilder: (_, _, _) => const SizedBox(
            height: 120,
            child: Center(child: Text('封面预览加载失败')),
          ),
        ),
      );
    }
    if (_remote == null) {
      return const Text('封面地址不可用，请重新查询。');
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: FutureBuilder<Uint8List>(
        future: _remote,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const SizedBox(
              height: 120,
              child: Center(child: Text('封面预览加载失败')),
            );
          }
          if (!snapshot.hasData) {
            return const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Image.memory(
            snapshot.data!,
            height: 200,
            width: 200,
            fit: BoxFit.contain,
            semanticLabel: '在线候选封面',
            errorBuilder: (_, _, _) => const SizedBox(
              height: 120,
              child: Center(child: Text('封面预览加载失败')),
            ),
          );
        },
      ),
    );
  }
}

class _LyricsPreview extends StatelessWidget {
  const _LyricsPreview({
    required this.candidate,
    required this.includeTranslation,
    required this.onChanged,
    this.onPrepareTranslation,
  });
  final VoidCallback? onPrepareTranslation;
  final FieldSuggestion candidate;
  final bool includeTranslation;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final content = candidate.lyricsContent!;
    Widget preview(String value) => ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: Scrollbar(
        child: SingleChildScrollView(
          primary: false,
          child: SelectableText(value),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('原歌词', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        preview(content.original),
        const SizedBox(height: 12),
        if (content.hasChineseTranslation) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('附加中文翻译'),
            subtitle: Text(
              content.hasIncompatibleOffsets
                  ? content.status
                  : includeTranslation
                  ? candidate.machineTranslated
                        ? '保存原文与本机生成的机器译文'
                        : '保存原文和来源提供的译文'
                  : '不加翻译，仅保存原歌词',
            ),
            value: includeTranslation && content.canIncludeTranslation,
            onChanged: content.canIncludeTranslation ? onChanged : null,
          ),
          if (includeTranslation) ...[
            Text(
              candidate.machineTranslated
                  ? '中文机器翻译 · Google Translate（本机）'
                  : '中文译文 · ${candidate.source}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            preview(content.chineseTranslation!),
            if (candidate.machineTranslated) ...[
              const SizedBox(height: 8),
              const GoogleTranslationAttribution(),
              const GoogleTranslationDisclaimer(),
            ],
          ],
        ] else ...[
          Text(content.status, style: Theme.of(context).textTheme.bodySmall),
          if (onPrepareTranslation != null)
            OutlinedButton.icon(
              onPressed: onPrepareTranslation,
              icon: const Icon(Icons.translate),
              label: const Text('使用 Google Translate 本机翻译'),
            ),
        ],
        if (candidate.translationNotice != null) ...[
          const SizedBox(height: 8),
          Text(
            candidate.translationNotice!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
