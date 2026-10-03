import 'package:flutter/material.dart';

import '../../core/models/app_settings.dart';
import '../../core/models/audio_track.dart';
import '../../shared/widgets/notice_panel.dart';
import '../library/library_controller.dart';
import 'audio_inventory_tool.dart';
import 'library_filters.dart';
import 'on_device_translation_settings.dart';
import '../../shared/widgets/translation_privacy.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    this.inventoryServiceFactory,
  });
  final LibraryController controller;
  final AudioInventoryServiceFactory? inventoryServiceFactory;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final horizontal = MediaQuery.sizeOf(context).width < 360 ? 16.0 : 24.0;
    return ListView(
      key: const PageStorageKey('settings'),
      padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 32),
      children: [
        const _SectionTitle('音乐库排除规则'),
        LibraryFilterSettings(controller: controller),
        const SizedBox(height: 28),
        const _SectionTitle('本机工具'),
        AudioInventoryToolCard(
          controller: controller,
          serviceFactory: inventoryServiceFactory,
        ),
        const SizedBox(height: 28),
        const _SectionTitle(
          '缺失项补全设置',
          description: '用于“仅补全缺失信息”；默认自动检索会查询所有可用来源字段，再逐项确认。',
        ),
        Card(
          child: Column(
            children: [
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
              const _InsetDivider(),
              SwitchListTile(
                title: const Text('歌词'),
                subtitle: const Text('纯文本或带时间轴的歌词'),
                value: settings.lyrics,
                onChanged: controller.canOperate
                    ? (value) => controller.updateSettings(
                        settings.copyWith(lyrics: value),
                      )
                    : null,
              ),
              const _InsetDivider(),
              SwitchListTile(
                key: const ValueKey('include-chinese-translation'),
                title: const Text('附加中文翻译'),
                subtitle: const Text('候选页默认附加来源已有译文，可单独关闭。已确认的选择保持不变。'),
                value: settings.includeChineseTranslation,
                onChanged: controller.canOperate
                    ? (value) => controller.updateSettings(
                        settings.copyWith(includeChineseTranslation: value),
                      )
                    : null,
              ),
              const _InsetDivider(),
              OnDeviceTranslationSettings(controller: controller),
              const _InsetDivider(),
              SwitchListTile(
                title: const Text('专辑封面'),
                subtitle: const Text('专辑封面候选图片'),
                value: settings.artwork,
                onChanged: controller.canOperate
                    ? (value) => controller.updateSettings(
                        settings.copyWith(artwork: value),
                      )
                    : null,
              ),
            ],
          ),
        ),
        if (settings.enabledFields.isEmpty) ...[
          const SizedBox(height: 12),
          const NoticePanel(
            icon: Icons.info_outline,
            title: '补全项目已全部关闭',
            message: '仅补全缺失信息已关闭；自动检索并修复仍可使用。',
          ),
        ],
        const SizedBox(height: 28),
        const _SectionTitle('外观', description: '跟随系统或选择适合你的主题。'),
        DropdownButtonFormField<AppTheme>(
          key: ValueKey(settings.theme),
          initialValue: settings.theme,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '主题'),
          items: const [
            DropdownMenuItem(value: AppTheme.system, child: Text('跟随系统')),
            DropdownMenuItem(value: AppTheme.light, child: Text('浅色')),
            DropdownMenuItem(value: AppTheme.dark, child: Text('深色')),
          ],
          onChanged: controller.canOperate
              ? (value) {
                  if (value != null) {
                    controller.updateSettings(settings.copyWith(theme: value));
                  }
                }
              : null,
        ),
        const SizedBox(height: 28),
        const _SectionTitle(
          '数据源',
          description: '查询会复用本机缓存。同一来源顺序请求；限流后暂停，不连续重试。',
        ),
        Card(
          child: Column(
            children: [
              for (final group in [
                (
                  '音乐资料',
                  Icons.album_outlined,
                  {AudioField.title, AudioField.artist, AudioField.album},
                ),
                ('歌词服务', Icons.lyrics_outlined, {AudioField.lyrics}),
                ('封面服务', Icons.image_outlined, {AudioField.artwork}),
              ])
                ListTile(
                  leading: Icon(group.$2, color: colors.primary),
                  title: Text(group.$1),
                  subtitle: Text(_sourceNames(group.$3)),
                ),
              if (controller.completion.sources.isNotEmpty) ...[
                const _InsetDivider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: controller.canOperate
                          ? controller.checkSourceConnections
                          : null,
                      icon: const Icon(Icons.network_check),
                      label: const Text('测试数据源连接'),
                    ),
                  ),
                ),
              ],
              for (final result in controller.sourceConnections.entries)
                _ConnectionResult(name: result.key, message: result.value),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const NoticePanel(
          icon: Icons.info_outline,
          title: '网易云音乐为实验性来源',
          message: '使用公开匿名只读接口，不是官方 OpenAPI。接口可能变更或限制访问；失败时保留其他来源。优先获取来源已有中文译文；可启用本机机器翻译补充，不上传整首歌词到翻译服务。',
        ),
        const SizedBox(height: 12),
        const NoticePanel(
          icon: Icons.privacy_tip_outlined,
          title: '不上传音频，确认后再保存',
          message: '检索时仅发送歌名、歌手、专辑和时长。默认自动查询元数据、封面与歌词，也可只补缺失项。来源返回的资料须逐项核对，已有值与候选值会对比显示；确认后保存原文件或导出副本。未选资料保留。原位保存可能需要系统授权。',
        ),
        const SizedBox(height: 28),
        const NoticePanel(
          icon: Icons.translate,
          title: 'Google Translate 本机翻译与隐私',
          message: '本机模型可在下载后离线翻译。ML Kit SDK 会向 Google 发送设备/应用信息、安装标识、语言配置和使用/性能指标；歌词正文与译文在设备上处理。每个模型约 30 MB，下载由你确认，仅使用 Wi-Fi。',
        ),
        const GoogleTranslationDisclaimer(),
        const SizedBox(height: 28),
        const _SectionTitle('关于 Audio Fixer'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Audio Fixer', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '0.4.1 · 自动检索元数据与封面',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '授权后自动读取 Android 系统音乐库。歌曲保留在原位置，刷新时同步新增和移除的歌曲。\n\n查看资料时临时读取文件，结束后清理临时副本；封面与目录缓存在应用内。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ],
            ),
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
    return names.isEmpty ? '尚未接入' : names.join('、');
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.description});
  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.titleMedium),
          ),
          if (description != null) ...[
            const SizedBox(height: 6),
            Text(
              description!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InsetDivider extends StatelessWidget {
  const _InsetDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 20),
    child: Divider(),
  );
}

class _ConnectionResult extends StatelessWidget {
  const _ConnectionResult({required this.name, required this.message});
  final String name;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final success = message == '连接测试通过';
    final pending = message == '测试中…';
    return ListTile(
      leading: Icon(
        success
            ? Icons.check_circle_outline
            : pending
            ? Icons.schedule_outlined
            : Icons.error_outline,
        color: success
            ? colors.primary
            : pending
            ? colors.onSurfaceVariant
            : colors.error,
      ),
      title: Text(name),
      subtitle: Text(message),
    );
  }
}
