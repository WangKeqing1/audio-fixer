import 'package:flutter/material.dart';

import '../../core/models/app_settings.dart';
import '../../core/models/audio_track.dart';
import '../library/library_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});
  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    return ListView(
      key: const PageStorageKey('settings'),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const _SectionTitle('补全内容'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text('仅查询缺失的项目，保留已有信息。'),
        ),
        SwitchListTile(
          title: const Text('元数据'),
          subtitle: const Text('歌名、歌手、专辑'),
          value: settings.metadata,
          onChanged: controller.canOperate
              ? (value) => controller.updateSettings(
                  settings.copyWith(metadata: value),
                )
              : null,
        ),
        SwitchListTile(
          title: const Text('歌词'),
          subtitle: const Text('纯文本或带时间轴的歌词'),
          value: settings.lyrics,
          onChanged: controller.canOperate
              ? (value) =>
                    controller.updateSettings(settings.copyWith(lyrics: value))
              : null,
        ),
        SwitchListTile(
          title: const Text('专辑封面'),
          value: settings.artwork,
          onChanged: controller.canOperate
              ? (value) =>
                    controller.updateSettings(settings.copyWith(artwork: value))
              : null,
        ),
        if (settings.enabledFields.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text('所有补全项目已关闭，开启至少一项后可以创建任务。'),
          ),
        const Divider(height: 32),
        const _SectionTitle('外观'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: DropdownButtonFormField<AppTheme>(
            key: ValueKey(settings.theme),
            initialValue: settings.theme,
            decoration: const InputDecoration(labelText: '主题'),
            items: const [
              DropdownMenuItem(value: AppTheme.system, child: Text('跟随系统')),
              DropdownMenuItem(value: AppTheme.light, child: Text('浅色')),
              DropdownMenuItem(value: AppTheme.dark, child: Text('深色')),
            ],
            onChanged: controller.canOperate
                ? (value) {
                    if (value != null) {
                      controller.updateSettings(
                        settings.copyWith(theme: value),
                      );
                    }
                  }
                : null,
          ),
        ),
        const Divider(height: 32),
        const _SectionTitle('数据源'),
        for (final group in [
          ('音乐资料', {AudioField.title, AudioField.artist, AudioField.album}),
          ('歌词服务', {AudioField.lyrics}),
          ('封面服务', {AudioField.artwork}),
        ])
          ListTile(
            title: Text(group.$1),
            subtitle: Text(_sourceNames(group.$2)),
          ),
        if (controller.completion.sources.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: controller.canOperate
                  ? controller.checkSourceConnections
                  : null,
              icon: const Icon(Icons.network_check),
              label: const Text('测试数据源连接'),
            ),
          ),
          for (final result in controller.sourceConnections.entries)
            ListTile(title: Text(result.key), subtitle: Text(result.value)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text('补全时会发送歌名、歌手、专辑和时长进行检索，不上传音频。查询结果作为候选展示，原文件保持不变。'),
          ),
        ],
        const Divider(height: 32),
        const _SectionTitle('关于 Audio Fixer'),
        const ListTile(
          leading: Icon(Icons.library_music_outlined),
          title: Text('Audio Fixer'),
          subtitle: Text('0.1.2 · 在线资料查询'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            '授权后自动读取安卓系统音乐库。歌曲保留在原位置，刷新时同步新增和移除的歌曲。\n\n查看资料时会临时读取文件，读取结束后清理临时副本；封面与目录缓存在应用内。在线候选可在补全任务中查看，音频标签写入将在后续接入。',
          ),
        ),
      ],
    );
  }

  String _sourceNames(Set<AudioField> fields) {
    final names = controller.completion.sources
        .where(
          (source) => source.supportedFields.intersection(fields).isNotEmpty,
        )
        .map((source) => source.name)
        .toList();
    return names.isEmpty ? '尚未接入' : '已接入 · ${names.join('、')}';
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
