import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../features/library/library_controller.dart';

/// A reversible catalog annotation, separate from approving or writing tags.
class InstrumentalControl extends StatelessWidget {
  const InstrumentalControl({
    super.key,
    required this.track,
    required this.controller,
    this.enabled = true,
  });

  final AudioTrack track;
  final LibraryController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            track.isInstrumental ? '纯音乐（仅本应用）' : '这是一首纯音乐？',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(
            track.isInstrumental
                ? '已跳过歌词查询与翻译，也不再提示歌词缺失。此标记仅保存在本应用，不修改音频文件或已有歌词，可随时取消。'
                : '检索不到歌词不一定是纯音乐。确认这首歌曲无需歌词时，可手动设置；仅保存在本应用，不修改音频文件或已有歌词。',
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: ValueKey('instrumental-${track.id}'),
            onPressed: enabled && controller.canOperate
                ? () => controller.setTrackInstrumental(
                    track.id,
                    !track.isInstrumental,
                  )
                : null,
            icon: Icon(track.isInstrumental ? Icons.undo : Icons.piano),
            label: Text(track.isInstrumental ? '取消纯音乐标记' : '设为纯音乐'),
          ),
        ],
      ),
    ),
  );
}
