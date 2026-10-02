import 'package:flutter/material.dart';

import '../../core/models/audio_folder.dart';
import '../library/library_controller.dart';

Future<void> openLibraryFilters(
  BuildContext context,
  LibraryController controller,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(title: const Text('音乐库排除规则')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [LibraryFilterSettings(controller: controller)],
          ),
        ),
      ),
    ),
  ),
);

class LibraryExclusionSummary extends StatelessWidget {
  const LibraryExclusionSummary({super.key, required this.controller});
  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final active =
        settings.excludeShortAudio || settings.excludedFolders.isNotEmpty;
    return OutlinedButton.icon(
      key: const ValueKey('library-exclusion-summary'),
      onPressed: () => openLibraryFilters(context, controller),
      icon: Icon(active ? Icons.filter_alt : Icons.filter_alt_outlined),
      label: Text(
        active
            ? '排除规则已开启 · 隐藏 ${controller.excludedTrackCount} 首'
            : '排除文件夹 / 短音频',
      ),
    );
  }
}

class LibraryFilterSettings extends StatelessWidget {
  const LibraryFilterSettings({super.key, required this.controller});
  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('只从音乐库和批量操作中排除，不移动或删除原文件。设置会自动保留。'),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                key: const ValueKey('exclude-short-audio'),
                title: const Text('排除 60 秒以下音频'),
                subtitle: const Text(
                  '仅排除短于 60 秒的音频，正好 60 秒仍保留。时长未知的音频暂时保留，读取后再判断。',
                ),
                value: settings.excludeShortAudio,
                onChanged: controller.canOperate
                    ? (value) => controller.updateSettings(
                        settings.copyWith(excludeShortAudio: value),
                      )
                    : null,
              ),
              const Divider(indent: 16, endIndent: 16),
              ListTile(
                key: const ValueKey('manage-excluded-folders'),
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('排除文件夹'),
                subtitle: Text(
                  '已选择 ${settings.excludedFolders.length} 个文件夹，包含其子文件夹',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: controller.canOperate
                    ? () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) =>
                              ExcludedFoldersPage(controller: controller),
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '系统目录 ${controller.allTracks.length} 首 · 当前显示 ${controller.tracks.length} 首 · 已排除 ${controller.excludedTrackCount} 首',
          key: const ValueKey('exclusion-counts'),
        ),
        if (controller.unknownDurationCount > 0) ...[
          const SizedBox(height: 8),
          Text('显示中的 ${controller.unknownDurationCount} 首时长未知，暂未按时长排除。'),
        ],
        if (controller.unknownFolderCount > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${controller.unknownFolderCount} 首没有可用文件夹信息，暂未按文件夹排除。刷新音乐库可重新获取。',
          ),
        ],
        if (settings.excludedFolders.isNotEmpty ||
            settings.excludeShortAudio) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('reset-library-exclusions'),
            onPressed: controller.canOperate
                ? () => controller.updateSettings(
                    settings.copyWith(
                      excludeShortAudio: false,
                      excludedFolders: const [],
                    ),
                  )
                : null,
            icon: const Icon(Icons.filter_alt_off_outlined),
            label: const Text('关闭全部排除规则'),
          ),
        ],
      ],
    );
  }
}

class ExcludedFoldersPage extends StatefulWidget {
  const ExcludedFoldersPage({super.key, required this.controller});
  final LibraryController controller;

  @override
  State<ExcludedFoldersPage> createState() => _ExcludedFoldersPageState();
}

class _ExcludedFoldersPageState extends State<ExcludedFoldersPage> {
  late final Set<AudioFolder> _selected = widget
      .controller
      .settings
      .excludedFolders
      .toSet();
  final _search = TextEditingController();
  bool _saving = false;
  bool _saveFailed = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !widget.controller.canOperate) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    final desired = _selected.toList();
    await widget.controller.updateSettings(
      widget.controller.settings.copyWith(excludedFolders: desired),
    );
    if (!mounted) return;
    final actual = widget.controller.settings.excludedFolders.toSet();
    if (actual.length == _selected.length && actual.containsAll(_selected)) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _saveFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final query = _search.text.trim().toLowerCase();
    final folders = controller.folderChoices
        .where((folder) => folder.label.toLowerCase().contains(query))
        .toList();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ScaffoldMessenger(
        child: Scaffold(
          key: const ValueKey('folder-filter-page'),
          appBar: AppBar(title: const Text('排除文件夹')),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  Expanded(
                    child: CustomScrollView(
                      key: const ValueKey('exclude-folder-list'),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_saveFailed) ...[
                                  Text(
                                    '排除规则未能保存，请重试；原文件未修改。',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                const Text(
                                  '勾选后会排除这个文件夹及全部子文件夹。不同存储卷分别设置；原文件不受影响。',
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  key: const ValueKey(
                                    'search-excluded-folders',
                                  ),
                                  controller: _search,
                                  onChanged: (_) => setState(() {}),
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) =>
                                      FocusScope.of(context).unfocus(),
                                  decoration: const InputDecoration(
                                    hintText: '搜索文件夹路径',
                                    prefixIcon: Icon(Icons.search),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (folders.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                query.isEmpty
                                    ? '尚无可用文件夹。授权并刷新系统音乐库后再试。'
                                    : '没有匹配的文件夹',
                              ),
                            ),
                          )
                        else
                          SliverList.builder(
                            itemCount: folders.length,
                            itemBuilder: (_, index) {
                              final folder = folders[index];
                              final inherited = _selected.any(
                                (parent) =>
                                    parent != folder && parent.contains(folder),
                              );
                              final count = controller.allTracks
                                  .where(
                                    (track) =>
                                        track.folder != null &&
                                        folder.contains(track.folder!),
                                  )
                                  .length;
                              return CheckboxListTile(
                                key: ValueKey('exclude-folder-${folder.id}'),
                                title: Text(folder.label),
                                subtitle: Text(
                                  inherited
                                      ? '已由上级文件夹排除'
                                      : count == 0
                                      ? '暂无歌曲，仍保留此排除规则'
                                      : '$count 首（含子文件夹）',
                                ),
                                value: inherited || _selected.contains(folder),
                                onChanged:
                                    _saving ||
                                        !controller.canOperate ||
                                        inherited
                                    ? null
                                    : (value) => setState(() {
                                        if (value == true) {
                                          _selected.add(folder);
                                        } else {
                                          _selected.remove(folder);
                                        }
                                      }),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.45,
                    ),
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            TextButton(
                              key: const ValueKey('clear-excluded-folders'),
                              onPressed: _saving
                                  ? null
                                  : () => setState(_selected.clear),
                              child: const Text('清空'),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                key: const ValueKey('apply-folder-exclusions'),
                                onPressed: _saving || !controller.canOperate
                                    ? null
                                    : _save,
                                child: Text(
                                  _saving
                                      ? '正在保存…'
                                      : '应用 ${_selected.length} 个排除规则',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
