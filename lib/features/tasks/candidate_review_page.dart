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
    this.embedded = false,
    this.onFinished,
    this.onBack,
  });
  final bool embedded;
  final VoidCallback? onFinished;
  final VoidCallback? onBack;
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
    final approved = widget.controller.reviewSuggestionsFor(widget.task);
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
      if (widget.onFinished != null) {
        widget.onFinished!();
      } else if (!widget.embedded) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _exporting = false;
          _exportNotice = widget.controller.notice;
        });
      }
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
      if (widget.embedded) {
        widget.onBack?.call();
      } else {
        Navigator.of(context).pop();
      }
    } else if (widget.embedded) {
      widget.onBack?.call();
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

  void _toggle(FieldSuggestion candidate, bool checked) {
    setState(() {
      if (checked) {
        _selected[candidate.field] = candidate;
      } else if (_selected[candidate.field] == candidate) {
        _selected.remove(candidate.field);
      }
    });
  }

  String _previewValue(FieldSuggestion candidate) {
    if (candidate.field == AudioField.artwork) return '专辑图片';
    if (candidate.field == AudioField.lyrics) {
      final lyrics = candidate.lyricsContent!;
      return lyrics.hasChineseTranslation ? '原文与中文翻译' : '原文';
    }
    return candidate.value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Widget _candidateRow(
    FieldSuggestion candidate,
    AudioTrack? track, {
    required bool enabled,
    required bool recommended,
  }) {
    final theme = Theme.of(context);
    final old = track?.valueOf(candidate.field);
    final hasOld = hasText(old);
    final allowed =
        enabled &&
        hasText(candidate.value) &&
        (!hasOld || candidate.replaceExisting) &&
        !(track?.isInstrumental == true &&
            candidate.field == AudioField.lyrics);
    final checked = _selected[candidate.field] == candidate;
    final others = widget.task.suggestions
        .where((item) => item.field == candidate.field)
        .map((item) => item.value)
        .toSet();
    final String contextLabel;
    if (hasOld) {
      contextLabel = candidate.field == AudioField.artwork
          ? '默认保留当前封面'
          : '${candidate.field.label}现为：${old!.replaceAll(RegExp(r'\s+'), ' ')}';
    } else if (others.length > 1) {
      contextLabel = '有不同结果，请选一个';
    } else if (recommended) {
      contextLabel = '补上缺少的${candidate.field.label}';
    } else {
      contextLabel = '确认后才会使用';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: ValueKey(
            'candidate-${candidate.field.name}-${candidate.source}-${candidate.value.hashCode}',
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          controlAffinity: ListTileControlAffinity.trailing,
          value: checked,
          onChanged: allowed
              ? (value) => _toggle(candidate, value == true)
              : null,
          title: Text(
            '${candidate.field.label} · ${_previewValue(candidate)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          subtitle: Text(
            contextLabel,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ExpansionTile(
          key: PageStorageKey(
            'candidate-details-${candidate.field.name}-${candidate.source}-${candidate.value.hashCode}',
          ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          visualDensity: VisualDensity.compact,
          title: Text('预览与来源', style: theme.textTheme.labelMedium),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (candidate.field == AudioField.artwork)
              _ArtworkPreview(value: candidate.value, size: 160)
            else if (candidate.field == AudioField.lyrics)
              _LyricsPreview(
                candidate: candidate,
                includeTranslation:
                    _translationChoices[candidate] ??
                    widget.controller.settings.includeChineseTranslation,
                onPrepareTranslation:
                    allowed && widget.controller.completion.translator != null
                    ? () => _prepareTranslation(candidate)
                    : null,
                onChanged: allowed
                    ? (value) =>
                          setState(() => _translationChoices[candidate] = value)
                    : null,
              )
            else
              SelectableText(
                candidate.value,
                key: PageStorageKey(
                  'candidate-value-${candidate.field.name}-${candidate.value.hashCode}',
                ),
              ),
            if (hasOld) ...[
              const SizedBox(height: 12),
              Text(
                '当前${candidate.field.label}',
                style: theme.textTheme.labelMedium,
              ),
              if (candidate.field == AudioField.artwork)
                TrackArtwork(path: track?.artworkPath, size: 72)
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 140),
                  child: SingleChildScrollView(
                    primary: false,
                    child: SelectableText(
                      old!,
                      key: PageStorageKey(
                        'current-text-${candidate.field.name}-${old.hashCode}',
                      ),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Text('来源：${candidate.source}', style: theme.textTheme.bodySmall),
            if (hasText(candidate.matchDescription))
              Text(
                candidate.matchDescription!,
                style: theme.textTheme.bodySmall,
              ),
            if (hasText(candidate.sourceUrl))
              SelectableText(
                candidate.sourceUrl!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
        const Divider(height: 1),
      ],
    );
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
      final recommended = controller.recommendedSuggestionsFor(widget.task);
      final mainRecommendations = recommended
          .where((item) => AudioField.coreFields.contains(item.field))
          .toList();
      final extraRecommendations = recommended
          .where((item) => !AudioField.coreFields.contains(item.field))
          .toList();
      final held = widget.task.suggestions
          .where((candidate) => !recommended.contains(candidate))
          .toList();
      final isManual = widget.task.suggestions.any(
        (item) => item.source == '手动编辑',
      );
      final String? unavailableReason = track == null
          ? '歌曲已移除或暂不可访问，请返回音乐库刷新。'
          : !track.detailsLoaded || track.readError != null
          ? '需要重新读取这首歌，再查看修复结果。'
          : isStale && result.status != TaskStatus.savedOriginal
          ? '歌曲或查询结果已更新，请查看最新结果。'
          : null;
      final canReview = !isStale && unavailableReason == null;
      final canAct =
          controller.canOperate &&
          !_exporting &&
          !_translationWorking &&
          canReview;
      final canSave = track != null && controller.canSaveOriginalTrack(track);
      final canExport = track != null && controller.canExportTrack(track);
      final replacing = selected
          .where((item) => hasText(track?.valueOf(item.field)))
          .length;
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final approved = controller
          .approvedSuggestionsFor(widget.task)
          .isNotEmpty;
      final proposedCover = _selected[AudioField.artwork];
      final proposedTitle =
          _selected[AudioField.title]?.value ?? widget.task.trackTitle;
      final proposedArtist =
          _selected[AudioField.artist]?.value ?? track?.artist;
      final identity = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (proposedCover != null)
            SizedBox(
              width: 72,
              height: 72,
              child: _ArtworkPreview(value: proposedCover.value, size: 72),
            )
          else
            TrackArtwork(path: track?.artworkPath, size: 72),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  proposedTitle,
                  style: theme.textTheme.headlineSmall,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                if (hasText(proposedArtist)) ...[
                  const SizedBox(height: 4),
                  Text(
                    proposedArtist!,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  result.status == TaskStatus.savedOriginal
                      ? '已修复并校验'
                      : '看一眼，再应用',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
      final summary = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          identity,
          const SizedBox(height: 24),
          Semantics(
            liveRegion: true,
            child: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              child: Align(
                key: ValueKey('${selected.length}-$replacing'),
                alignment: Alignment.centerLeft,
                child: Text(
                  selected.isEmpty
                      ? '暂时保留原样'
                      : replacing > 0
                      ? '将补全 ${selected.length - replacing} 项，替换 $replacing 项'
                      : '将补全 ${selected.length} 项',
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            replacing > 0 ? '仅替换你选中的资料，其余保持原样。' : '已有资料保留。不同结果或替换项由你决定。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (recommended.isEmpty &&
              !isManual &&
              canAct &&
              widget.task.suggestions.isNotEmpty &&
              widget.task.suggestions.every(
                (item) => item.provenance == SuggestionProvenance.unverified,
              ) &&
              controller.completion.sources.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('这份结果需要重新检查，才能生成可靠的补全建议。'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('refresh-review-recommendations'),
                onPressed: track != null ? () => _queryAgain(track) : null,
                icon: const Icon(Icons.refresh),
                label: const Text('重新检查歌曲'),
              ),
            ),
          ],
          if (held.isNotEmpty && recommended.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${held.map((item) => item.field).toSet().length} 项未加入建议',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (_exportNotice != null || result.writeError != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: NoticePanel(
                icon: Icons.info_outline,
                title: '处理结果',
                message: _exportNotice ?? result.writeError!,
              ),
            ),
          ],
          if (unavailableReason != null) ...[
            const SizedBox(height: 16),
            NoticePanel(
              icon: Icons.info_outline,
              title: '先更新结果',
              message: unavailableReason,
              action: current != null && controller.isTaskCurrent(current)
                  ? TextButton(
                      onPressed: widget.embedded
                          ? widget.onBack
                          : () => Navigator.of(context).pushReplacement(
                              MaterialPageRoute<void>(
                                builder: (_) => CandidateReviewPage(
                                  task: current,
                                  controller: controller,
                                ),
                              ),
                            ),
                      child: const Text('查看最新结果'),
                    )
                  : !isManual && track != null && controller.canOperate
                  ? TextButton(
                      onPressed: () => _queryAgain(track),
                      child: const Text('重新查询'),
                    )
                  : null,
            ),
          ],
          if (result.status == TaskStatus.exported) ...[
            const SizedBox(height: 12),
            const Text('已导出过副本。再次导出会另存一份，原文件保持不变。'),
          ],
          if (result.status == TaskStatus.savedOriginal) ...[
            const SizedBox(height: 16),
            const NoticePanel(
              icon: Icons.check_circle_outline,
              title: '已保存到原文件',
              message: '所选资料已写入并回读校验。',
            ),
          ],
          if (canReview && !canSave) ...[
            const SizedBox(height: 16),
            Text(
              canExport ? '这首歌可导出新副本，原文件保持不变。' : '当前格式或设备仅支持预览，暂不能保存。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      );
      final changes = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (recommended.isNotEmpty) ...[
            Text('建议补全', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Material(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final candidate in mainRecommendations)
                    _candidateRow(
                      candidate,
                      track,
                      enabled: canAct,
                      recommended: true,
                    ),
                ],
              ),
            ),
          ],
          if (extraRecommendations.isNotEmpty)
            ExpansionTile(
              key: const PageStorageKey('review-extra-recommendations'),
              tilePadding: EdgeInsets.zero,
              title: Text(
                '另外补全 ${extraRecommendations.length} 项资料',
                style: theme.textTheme.titleSmall,
              ),
              subtitle: Text(
                extraRecommendations.map((item) => item.field.label).join('、'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              children: [
                for (final candidate in extraRecommendations)
                  _candidateRow(
                    candidate,
                    track,
                    enabled: canAct,
                    recommended: true,
                  ),
              ],
            ),
          if (held.isNotEmpty) ...[
            if (recommended.isNotEmpty) const SizedBox(height: 16),
            ExpansionTile(
              key: const PageStorageKey('review-held-changes'),
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: recommended.isEmpty || isManual,
              title: Text(
                isManual
                    ? '你的修改'
                    : '需要你决定 · ${held.map((item) => item.field).toSet().length} 项',
                style: theme.textTheme.titleMedium,
              ),
              subtitle: Text(isManual ? '应用前确认本次修改' : '默认保留原样'),
              children: [
                for (final candidate in held)
                  _candidateRow(
                    candidate,
                    track,
                    enabled: canAct,
                    recommended: false,
                  ),
              ],
            ),
          ],
          if (widget.task.suggestions.isEmpty)
            const NoticePanel(
              icon: Icons.search_off,
              title: '还没有可用结果',
              message: '可以稍后重试，或调整歌名和歌手。',
            ),
          if (track != null &&
              (track.isInstrumental ||
                  (canReview &&
                      !hasText(track.lyrics) &&
                      result.queriedFields.contains(AudioField.lyrics) &&
                      !result.suggestions.any(
                        (item) => item.field == AudioField.lyrics,
                      )))) ...[
            const SizedBox(height: 16),
            InstrumentalControl(
              track: track,
              controller: controller,
              enabled: canAct,
            ),
          ],
          ExpansionTile(
            key: const PageStorageKey('review-query-details'),
            tilePadding: EdgeInsets.zero,
            title: const Text('查询详情'),
            children: [
              if (result.sourceReports.isNotEmpty)
                SourceQueryStatusPanel(
                  reports: result.sourceReports,
                  hasCandidates: result.suggestions.isNotEmpty,
                )
              else
                Text(result.message),
              const SizedBox(height: 8),
              const Text('应用前会再次检查文件，完成后回读校验。系统可能请求写入许可。'),
              if (hasText(result.exportedCopyUri))
                SingleChildScrollView(
                  key: const PageStorageKey('review-export-location-scroll'),
                  primary: false,
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    result.exportedCopyUri!,
                    key: const PageStorageKey('review-export-location-text'),
                  ),
                ),
              if (approved)
                TextButton.icon(
                  key: const ValueKey('revoke-approval'),
                  onPressed: canAct ? () => _save([], revokeOnly: true) : null,
                  icon: const Icon(Icons.undo),
                  label: const Text('撤销待保存确认'),
                ),
            ],
          ),
        ],
      );
      final footer = Material(
        color: colors.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_exporting ||
                    _translationProcessing ||
                    controller.isBusy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _exporting
                          ? '正在校验并保存，请稍候…'
                          : controller.progress ?? '正在准备…',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton.icon(
                  key: const ValueKey('save-original'),
                  onPressed:
                      canAct && selected.isNotEmpty && (canSave || canExport)
                      ? () => _save(selected, exportCopy: !canSave)
                      : null,
                  icon: Icon(
                    _exporting ? Icons.hourglass_top : Icons.auto_fix_high,
                  ),
                  label: Text(
                    _exporting
                        ? '正在应用…'
                        : !canSave && canExport
                        ? '${result.status == TaskStatus.exported ? '再次导出' : '导出'}修复副本（${selected.length} 项）'
                        : '应用${replacing > 0 || isManual ? '所选' : '建议'}（${selected.length} 项）',
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        key: const ValueKey('approve-for-batch'),
                        onPressed: canAct && selected.isNotEmpty
                            ? () => _save(selected, approveOnly: true)
                            : null,
                        child: const Text('稍后保存', textAlign: TextAlign.center),
                      ),
                    ),
                    if (canSave)
                      Expanded(
                        child: TextButton(
                          key: const ValueKey('export-copy'),
                          onPressed: canAct && selected.isNotEmpty && canExport
                              ? () => _save(selected, exportCopy: true)
                              : null,
                          child: const Text(
                            '导出副本',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      final body = SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final roomy = constraints.maxWidth >= 900;
            return ListView(
              controller: _scrollController,
              padding: EdgeInsets.all(roomy ? 28 : 16),
              children: [
                if (roomy)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 4, child: summary),
                      const SizedBox(width: 32),
                      Expanded(flex: 6, child: changes),
                    ],
                  )
                else ...[
                  summary,
                  const SizedBox(height: 24),
                  changes,
                ],
              ],
            );
          },
        ),
      );
      return PopScope(
        canPop: !_exporting,
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: !widget.embedded,
            leading: widget.embedded && widget.onBack != null
                ? IconButton(
                    tooltip: '返回歌曲',
                    onPressed: _exporting ? null : widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                  )
                : null,
            title: const Text('修复预览'),
          ),
          body: body,
          bottomNavigationBar: footer,
        ),
      );
    },
  );
}

class _ArtworkPreview extends StatefulWidget {
  const _ArtworkPreview({required this.value, this.size = 120});
  final String value;
  final double size;

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
          height: widget.size,
          width: widget.size,
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
            height: widget.size,
            width: widget.size,
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
          key: PageStorageKey('lyrics-scroll-${value.hashCode}'),
          primary: false,
          child: SelectableText(
            value,
            key: PageStorageKey('lyrics-text-${value.hashCode}'),
          ),
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
