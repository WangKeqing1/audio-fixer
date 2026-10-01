import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/services/device_music_library.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/track_artwork.dart';
import 'library_controller.dart';
import 'track_detail_page.dart';

enum _LibraryFilter { all, incomplete, readError }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.controller});
  final LibraryController controller;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _search = TextEditingController();
  _LibraryFilter _filter = _LibraryFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

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
          title: '允许访问设备音乐',
          description: blocked
              ? '请在系统设置中允许访问音乐和音频。授权后会自动显示系统音乐库。'
              : '授权访问音乐和音频后，自动显示设备上的歌曲，无需逐个导入。',
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
    if (controller.libraryError != null) {
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
    if (controller.tracks.isEmpty) {
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
    final tracks = controller.tracks.where((track) {
      final matchesFilter = switch (_filter) {
        _LibraryFilter.all => true,
        _LibraryFilter.incomplete => track.needsCompletion,
        _LibraryFilter.readError => track.readError != null,
      };
      return matchesFilter &&
          '${track.fileName} ${track.title ?? ''} ${track.artist ?? ''} ${track.album ?? ''}'
              .toLowerCase()
              .contains(query);
    }).toList();

    return CustomScrollView(
      key: const PageStorageKey('library'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${controller.tracks.length} 首音频 · 系统音乐库',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '搜索歌名、歌手或文件名',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: query.isEmpty
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
                        label: Text(switch (filter) {
                          _LibraryFilter.all => '全部',
                          _LibraryFilter.incomplete => '待补全',
                          _LibraryFilter.readError => '读取异常',
                        }),
                        selected: filter == _filter,
                        onSelected: (_) => setState(() => _filter = filter),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (tracks.isEmpty)
          const SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.search_off_outlined,
              title: '没有符合条件的音频',
              description: '试试其他关键词，或切换到「全部」。',
            ),
          )
        else
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return _TrackTile(
                track: track,
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
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.track, required this.onTap});
  final AudioTrack track;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      leading: TrackArtwork(path: track.artworkPath),
      title: Text(
        track.displayTitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${hasText(track.artist) ? track.artist : '歌手未知'} · ${track.extension} · ${formatDuration(track.durationMs)}',
            ),
            const SizedBox(height: 4),
            Text(
              track.readError != null
                  ? '标签读取异常'
                  : !track.detailsLoaded
                  ? '待检查文件标签'
                  : track.needsCompletion
                  ? '缺少${track.missingFields.map((field) => field.label).join('、')}'
                  : '资料完整',
              style: TextStyle(
                color: track.readError != null ? colors.error : colors.primary,
              ),
            ),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
