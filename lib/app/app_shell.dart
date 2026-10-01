import 'package:flutter/material.dart';

import '../features/library/library_controller.dart';
import '../features/library/library_page.dart';
import '../features/settings/settings_page.dart';
import '../features/tasks/tasks_page.dart';
import '../shared/widgets/empty_state.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final LibraryController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _selected = 0;
  int _noticeRevision = 0;
  static const _labels = ['音乐库', '补全任务', '设置'];
  static const _icons = [
    Icons.library_music_outlined,
    Icons.auto_fix_high_outlined,
    Icons.tune_outlined,
  ];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_showNotice);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        widget.controller.usesDeviceLibrary &&
        widget.controller.canOperate) {
      widget.controller.refreshLibrary();
    }
  }

  void _showNotice() {
    final controller = widget.controller;
    if (_noticeRevision == controller.noticeRevision) return;
    _noticeRevision = controller.noticeRevision;
    final message = controller.notice;
    if (message == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_showNotice);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final content = controller.isLoading
        ? const Center(child: CircularProgressIndicator())
        : controller.loadError != null
        ? SingleChildScrollView(
            child: EmptyState(
              icon: Icons.folder_off_outlined,
              title: '本地目录暂时不可用',
              description: controller.loadError!,
              action: FilledButton.icon(
                onPressed: controller.initialize,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ),
          )
        : IndexedStack(
            index: _selected,
            children: [
              LibraryPage(controller: controller),
              TasksPage(
                controller: controller,
                onOpenSettings: () => setState(() => _selected = 2),
              ),
              SettingsPage(controller: controller),
            ],
          );

    return PopScope(
      canPop: _selected == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selected = 0);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_labels[_selected]),
          actions: [
            if (_selected == 0 && controller.usesDeviceLibrary)
              IconButton(
                tooltip: '刷新系统音乐库',
                onPressed: controller.canOperate
                    ? controller.refreshLibrary
                    : null,
                icon: const Icon(Icons.refresh),
              ),
            if (_selected == 0)
              IconButton(
                tooltip: '补全全部缺失信息',
                onPressed:
                    controller.canOperate &&
                        controller.incompleteCount > 0 &&
                        controller.settings.enabledFields.isNotEmpty
                    ? () async {
                        await controller.complete();
                        if (mounted) setState(() => _selected = 1);
                      }
                    : null,
                icon: const Icon(Icons.auto_fix_high_outlined),
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: wide,
          child: Column(
            children: [
              if (controller.isBusy && !controller.isLoading) ...[
                const LinearProgressIndicator(),
                if (controller.progress != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Expanded(child: Text(controller.progress!)),
                        if (controller.isCompleting)
                          TextButton(
                            onPressed: controller.completionStopRequested
                                ? null
                                : controller.stopCompletion,
                            child: const Text('停止'),
                          ),
                      ],
                    ),
                  ),
              ],
              Expanded(
                child: Row(
                  children: [
                    if (wide) ...[
                      NavigationRail(
                        selectedIndex: _selected,
                        labelType: NavigationRailLabelType.all,
                        onDestinationSelected: (value) =>
                            setState(() => _selected = value),
                        destinations: [
                          for (var index = 0; index < _labels.length; index++)
                            NavigationRailDestination(
                              icon: Icon(_icons[index]),
                              label: Text(_labels[index]),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1000),
                          child: content,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: _selected,
                onDestinationSelected: (value) =>
                    setState(() => _selected = value),
                destinations: [
                  for (var index = 0; index < _labels.length; index++)
                    NavigationDestination(
                      icon: Icon(_icons[index]),
                      label: _labels[index],
                    ),
                ],
              ),
      ),
    );
  }
}
