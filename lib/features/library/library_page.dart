import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/services/device_music_library.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/notice_panel.dart';
import '../../shared/widgets/track_artwork.dart';
import 'library_controller.dart';
import 'track_detail_page.dart';
import '../tasks/bulk_action_panel.dart';

enum _LibraryFilter {
  all('全部'),
  unchecked('待检查'),
  incomplete('待补全'),
  readError('读取异常');

  const _LibraryFilter(this.label);
  final String label;

  bool matches(AudioTrack track) => switch (this) {
    all => true,
    unchecked => !track.detailsLoaded && track.readError == null,
    incomplete => track.detailsLoaded && track.missingFields.isNotEmpty,
    readError => track.readError != null,
  };
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.controller, this.onOpenTasks});
  final LibraryController controller;
  final VoidCallback? onOpenTasks;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _search = TextEditingController();
  _LibraryFilter _filter = _LibraryFilter.all;
  bool _selectionMode = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _resetSearch() => setState(() {
    _search.clear();
    _filter = _LibraryFilter.all;
  });

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    if (!controller.canReadDeviceLibrary) {
      final blocked =
          controller.libraryPermission == AudioLibraryPermission.blocked;
      return SingleChildScrollView(
        child: EmptyState(
          icon: Icons.library_music_outlined,
          title: '让设备音乐井井有条',
          description: blocked
              ? '请在系统设置中允许访问音乐和音频。授权后会自动显示系统音乐库。'
              : '允许访问音乐和音频，即可查看歌曲、检查标签并查找缺失资料。无需逐个导入，原文件保留在原位置。',
          action: FilledButton.icon(
            onPressed: controller.canOperate
                ? controller.authorizeLibrary
                : null,
            icon: Icon(
              blocked ? Icons.settings_outlined : Icons.music_note_outlined,
            ),
            label: Text(blocked ? '前往设置' : '允许访问音乐'),
          ),
        ),
      );
    }
    final allTracks = controller.tracks;
    if (controller.libraryError != null && allTracks.isEmpty) {
      return SingleChildScrollView(
        child: EmptyState(
          icon: Icons.sync_problem_outlined,
          title: '音乐库刷新失败',
          description: controller.libraryError!,
          action: FilledButton.icon(
            onPressed: controller.canOperate ? controller.refreshLibrary : null,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (allTracks.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.only(top: 32, bottom: 32),
        child: EmptyState(
          icon: Icons.library_music_outlined,
          title: '系统音乐库中还没有歌曲',
          description: '将音乐保存到手机的 Music 或 Download 文件夹，待系统识别后刷新即可。',
          action: OutlinedButton.icon(
            onPressed: controller.canOperate ? controller.refreshLibrary : null,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新音乐库'),
          ),
        ),
      );
    }
    final query = _search.text.trim().toLowerCase();
    final counts = {
      for (final filter in _LibraryFilter.values)
        filter: allTracks.where(filter.matches).length,
    };
    final tracks = allTracks.where((track) {
      return _filter.matches(track) &&
          '${track.fileName} ${track.title ?? ''} ${track.artist ?? ''} ${track.album ?? ''}'
              .toLowerCase()
              .contains(query);
    }).toList();
    final selectionMode = _selectionMode || controller.selectedCount > 0;
    final visibleIds = tracks.map((track) => track.id).toSet();
    final allVisibleSelected =
        visibleIds.isNotEmpty &&
        visibleIds.every(controller.selectedTrackIds.contains);
    final hiddenSelected = controller.selectedTrackIds
        .difference(visibleIds)
        .length;
    final checked = allTracks.where((track) => track.detailsLoaded).length;
    final complete = allTracks
        .where(
          (track) =>
              track.detailsLoaded &&
              track.readError == null &&
              track.missingFields.isEmpty,
        )
        .length;
    final horizontal = MediaQuery.sizeOf(context).width < 360 ? 16.0 : 24.0;

    return CustomScrollView(
      key: const PageStorageKey('library'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (controller.libraryError != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: NoticePanel(
                      icon: Icons.sync_problem_outlined,
                      title: '刷新未完成，已保留上次的音乐库',
                      message: controller.libraryError!,
                      isError: true,
                      action: OutlinedButton.icon(
                        onPressed: controller.canOperate
                            ? controller.refreshLibrary
                            : null,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试刷新'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                _LibraryOverview(
                  total: allTracks.length,
                  checked: checked,
                  complete: complete,
                  isDeviceLibrary: controller.usesDeviceLibrary,
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => FocusScope.of(context).unfocus(),
                  decoration: InputDecoration(
                    hintText: '搜索歌曲、歌手、专辑…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () => setState(_search.clear),
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final filter in _LibraryFilter.values)
                      FilterChip(
                        label: Text('${filter.label} ${counts[filter]}'),
                        selected: filter == _filter,
                        onSelected: (_) => setState(() => _filter = filter),
                      ),
                  ],
                ),
                if (_filter == _LibraryFilter.unchecked) ...[
                  const SizedBox(height: 8),
                  Text(
                    '尚未读取完整文件标签，点开歌曲后检查。待检查不代表资料缺失。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      key: const ValueKey('toggle-library-selection'),
                      onPressed: controller.canOperate
                          ? () => setState(() {
                              _selectionMode = !selectionMode;
                              if (!_selectionMode) controller.clearSelection();
                            })
                          : null,
                      icon: Icon(selectionMode ? Icons.close : Icons.checklist),
                      label: Text(selectionMode ? '结束多选' : '多选'),
                    ),
                    if (selectionMode)
                      TextButton.icon(
                        key: const ValueKey('select-visible-tracks'),
                        onPressed:
                            controller.canOperate && visibleIds.isNotEmpty
                            ? () {
                                if (allVisibleSelected) {
                                  for (final id in visibleIds) {
                                    controller.toggleTrackSelection(id);
                                  }
                                } else {
                                  controller.selectTracks(visibleIds);
                                }
                              }
                            : null,
                        icon: Icon(
                          allVisibleSelected
                              ? Icons.deselect
                              : Icons.select_all,
                        ),
                        label: Text(allVisibleSelected ? '取消当前列表全选' : '全选当前列表'),
                      ),
                    TextButton.icon(
                      key: const ValueKey('query-visible-tracks'),
                      onPressed:
                          controller.canOperate &&
                              visibleIds.isNotEmpty &&
                              controller.settings.enabledFields.isNotEmpty
                          ? () => confirmBatchQuery(
                              context,
                              controller,
                              visibleIds,
                              onStart: widget.onOpenTasks,
                            )
                          : null,
                      icon: const Icon(Icons.manage_search),
                      label: const Text('查询当前列表'),
                    ),
                  ],
                ),
                if (hiddenSelected > 0)
                  Text(
                    '另有 $hiddenSelected 首已选歌曲不在当前筛选中，仍会参与批量操作。',
                    style: theme.textTheme.bodySmall,
                  ),
                if (controller.selectedCount > 0) ...[
                  BulkActionPanel(
                    controller: controller,
                    onQueryStart: widget.onOpenTasks,
                  ),
                  TextButton.icon(
                    onPressed: widget.onOpenTasks,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('前往补全任务，逐首确认资料'),
                  ),
                ],
                const SizedBox(height: 12),
                Semantics(
                  header: true,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          query.isNotEmpty ? '搜索结果' : '歌曲列表',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      Text(
                        '${tracks.length} 首',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (tracks.isEmpty)
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.search_off_outlined,
              title: query.isEmpty ? '这个分类里还没有歌曲' : '没有找到匹配的歌曲',
              description: query.isEmpty
                  ? '可以切换分类，查看音乐库中的其他歌曲。'
                  : '试试其他歌名、歌手、专辑或文件名，也可以清除筛选查看全部歌曲。',
              action: OutlinedButton.icon(
                onPressed: _resetSearch,
                icon: const Icon(Icons.filter_alt_off_outlined),
                label: const Text('查看全部歌曲'),
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: horizontal),
            sliver: SliverList.builder(
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final track = tracks[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TrackTile(
                    track: track,
                    selectionMode: selectionMode,
                    selected: controller.selectedTrackIds.contains(track.id),
                    onSelectionChanged: controller.canOperate
                        ? () => controller.toggleTrackSelection(track.id)
                        : null,
                    onTap: !controller.canOperate
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => TrackDetailPage(
                                track: track,
                                controller: controller,
                              ),
                            ),
                          ),
                  ),
                );
              },
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _LibraryOverview extends StatelessWidget {
  const _LibraryOverview({
    required this.total,
    required this.checked,
    required this.complete,
    required this.isDeviceLibrary,
  });

  final int total;
  final int checked;
  final int complete;
  final bool isDeviceLibrary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isDeviceLibrary ? '系统音乐库' : '我的音乐收藏',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$total 首歌曲',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    for (final label in ['已检查 $checked 首', '资料完整 $complete 首'])
                      Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (MediaQuery.textScalerOf(context).scale(14) < 21) ...[
            const SizedBox(width: 12),
            ExcludeSemantics(
              child: Icon(
                Icons.library_music_outlined,
                size: 40,
                color: colors.onPrimaryContainer,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.onTap,
    required this.selectionMode,
    required this.selected,
    this.onSelectionChanged,
  });
  final AudioTrack track;
  final VoidCallback? onTap;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (statusIcon, statusText, statusColor) = track.readError != null
        ? (Icons.error_outline, '标签读取异常', colors.error)
        : !track.detailsLoaded
        ? (Icons.schedule_outlined, '待检查文件标签', colors.onSurfaceVariant)
        : track.missingFields.isNotEmpty
        ? (
            Icons.auto_fix_high_outlined,
            '缺少${track.missingFields.map((field) => field.label).join('、')}',
            colors.primary,
          )
        : (Icons.check_circle_outline, '资料完整', colors.primary);
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Card(
        child: InkWell(
          onTap: selectionMode ? onSelectionChanged : onTap,
          onLongPress: onSelectionChanged,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (selectionMode)
                  Checkbox(
                    key: ValueKey('select-track-${track.id}'),
                    value: selected,
                    semanticLabel: '选择 ${track.displayTitle}',
                    onChanged: onSelectionChanged == null
                        ? null
                        : (_) => onSelectionChanged!(),
                  ),
                ExcludeSemantics(
                  child: TrackArtwork(path: track.artworkPath, size: 52),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${hasText(track.artist) ? track.artist : '歌手未知'} · ${track.extension} · ${formatDuration(track.durationMs)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ExcludeSemantics(
                            child: Icon(
                              statusIcon,
                              size: 16,
                              color: statusColor,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              statusText,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: statusColor,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                ExcludeSemantics(
                  child: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
