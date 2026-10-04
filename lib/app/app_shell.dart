import 'dart:async';

import 'package:flutter/material.dart';

import '../features/library/library_controller.dart';
import '../features/library/library_page.dart';
import '../features/settings/settings_page.dart';
import '../features/tasks/tasks_page.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/formatters.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final LibraryController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _selected = 0;
  int _libraryNavigationRevision = 0;
  int _noticeRevision = 0;
  String? _inlineNotice;
  Timer? _noticeTimer;
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
    if (state != AppLifecycleState.resumed) {
      unawaited(widget.controller.preview.stop());
    }
    if (state == AppLifecycleState.resumed &&
        widget.controller.usesDeviceLibrary &&
        widget.controller.canOperate) {
      widget.controller.refreshLibrary();
    }
  }

  void _selectTab(int value) {
    if (_selected != value) _libraryNavigationRevision++;
    if (_selected == 0 && value != 0) {
      unawaited(widget.controller.preview.stop());
    }
    setState(() => _selected = value);
  }

  void _showNotice() {
    final controller = widget.controller;
    if (_noticeRevision == controller.noticeRevision) return;
    _noticeRevision = controller.noticeRevision;
    final message = controller.notice;
    if (message == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _noticeTimer?.cancel();
      setState(() => _inlineNotice = message);
      _noticeTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _inlineNotice = null);
      });
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_showNotice);
    _noticeTimer?.cancel();
    unawaited(widget.controller.preview.stop());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final wide = MediaQuery.sizeOf(context).width >= 1000;
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
              LibraryPage(
                controller: controller,
                isActive: _selected == 0,
                navigationToken: () =>
                    _selected == 0 ? _libraryNavigationRevision : null,
                onOpenTasks: () => _selectTab(1),
              ),
              TasksPage(
                controller: controller,
                onOpenSettings: () => _selectTab(2),
              ),
              SettingsPage(controller: controller),
            ],
          );

    return PopScope(
      canPop: _selected == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _selectTab(0);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_labels[_selected]),
          actions: [
            if (_selected == 0 && controller.usesFolderLibrary)
              IconButton(
                key: const ValueKey('choose-music-folder'),
                tooltip: '添加音乐文件夹',
                onPressed: controller.canOperate
                    ? controller.chooseLibraryFolder
                    : null,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            if (_selected == 0 && controller.usesDeviceLibrary)
              IconButton(
                tooltip: controller.usesFolderLibrary ? '刷新音乐文件夹' : '刷新系统音乐库',
                onPressed: controller.canOperate
                    ? controller.refreshLibrary
                    : null,
                icon: const Icon(Icons.refresh),
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: wide,
          child: Column(
            children: [
              if (_inlineNotice case final message?)
                _OperationNotice(
                  message: message,
                  onClose: () {
                    _noticeTimer?.cancel();
                    setState(() => _inlineNotice = null);
                  },
                ),
              if (controller.recoveryNotice != null ||
                  controller.originalRecoveryState != null)
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) =>
                        _RecoveryDialog(controller: controller),
                  ),
                  icon: const Icon(Icons.restore),
                  label: Text(
                    controller.exportRecoveryNotice == null &&
                            controller.originalRecoveryState == null
                        ? '已从备份恢复目录 · 查看说明'
                        : '恢复提醒 · 查看说明',
                  ),
                ),
              if (controller.isBusy && !controller.isLoading) ...[
                const LinearProgressIndicator(),
                if (controller.progress != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Expanded(child: Text(controller.progress!)),
                        if (controller.batchOperation?.isRunning == true &&
                            !controller.isCompleting)
                          TextButton(
                            onPressed: controller.batchOperation!.stopRequested
                                ? null
                                : controller.stopBatch,
                            child: const Text('停止'),
                          ),
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
                    Offstage(
                      offstage: !wide,
                      child: NavigationRail(
                        selectedIndex: _selected,
                        labelType: NavigationRailLabelType.all,
                        onDestinationSelected: _selectTab,
                        destinations: [
                          for (var index = 0; index < _labels.length; index++)
                            NavigationRailDestination(
                              icon: Icon(_icons[index]),
                              label: Text(_labels[index]),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: wide ? 1 : 0,
                      child: const VerticalDivider(width: 1),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: _selected == 0 ? double.infinity : 1200,
                          ),
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
                onDestinationSelected: _selectTab,
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

/// Operation messages reserve space above content instead of obscuring pinned
/// selection controls. The full message remains available in a readable dialog.
class _OperationNotice extends StatelessWidget {
  const _OperationNotice({required this.message, required this.onClose});
  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('operation-notice'),
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          IconButton(
            tooltip: '查看完整提示',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('操作提示'),
                content: SingleChildScrollView(child: Text(message)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: '关闭提示',
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    ),
  );
}

class _RecoveryDialog extends StatelessWidget {
  const _RecoveryDialog({required this.controller});
  final LibraryController controller;

  Future<void> _restore(BuildContext context) async {
    final target = controller.originalRecoveryState?.targetUri;
    if (target == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复原始备份并替换当前文件？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '当前文件可能已被其他应用更换。继续后会先单独保留当前不同的文件，再用原始备份替换它。两个版本都会保留，可在恢复页分别导出。',
              ),
              const SizedBox(height: 12),
              const Text('将替换此文件：'),
              SelectableText(target),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-restore-original'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保留两个版本并恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !context.mounted ||
        !controller.canOperate ||
        controller.originalRecoveryState?.targetUri != target ||
        controller.originalRecoveryState?.canRestore != true) {
      return;
    }
    await controller.restoreOriginalBackup();
  }

  Future<void> _finish(BuildContext context) async {
    final route = ModalRoute.of(context);
    final target = controller.originalRecoveryState?.targetUri;
    if (target == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保留当前文件并结束恢复？'),
        content: const SingleChildScrollView(
          child: Text(
            '当前文件不会更改，已经导出的副本也会保留。结束后会删除应用内的本次恢复备份和记录，无法撤销。请确认已经核对并保留所需版本。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续保留备份'),
          ),
          FilledButton(
            key: const ValueKey('confirm-finish-recovery'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('结束恢复并删除内部备份'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !context.mounted ||
        !controller.canOperate ||
        controller.originalRecoveryState?.targetUri != target ||
        controller.originalRecoveryState?.canFinish != true) {
      return;
    }
    await controller.finishOriginalRecovery();
    if (context.mounted &&
        route?.isCurrent == true &&
        controller.originalRecoveryState == null &&
        controller.recoveryNotice == null) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final recovery = controller.originalRecoveryState;
      return AlertDialog(
        title: Text(
          recovery != null
              ? '原文件恢复'
              : controller.exportRecoveryNotice == null
              ? '本地目录已恢复'
              : '恢复提醒',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                controller.recoveryNotice ??
                    (recovery == null ? '恢复处理已完成。' : '恢复记录中仍有音频版本，请核对后决定。'),
              ),
              if (recovery != null) ...[
                const SizedBox(height: 16),
                const Text('当前文件可能已被其他应用更换，不会自动覆盖。可先导出保留的版本，再选择恢复原始备份或保留当前文件。'),
                const SizedBox(height: 12),
                const Text('文件位置'),
                SelectableText(recovery.targetUri),
                const SizedBox(height: 12),
                for (final version in recovery.versions)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            version.label,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(formatFileSize(version.sizeBytes)),
                          if (version.exportedUri != null) ...[
                            const Text('此版本已导出'),
                            SelectableText(version.exportedUri!),
                          ],
                          TextButton.icon(
                            key: ValueKey('export-recovery-${version.id}'),
                            onPressed: controller.canOperate
                                ? () => controller
                                      .exportOriginalRecoveryVersion(version.id)
                                : null,
                            icon: const Icon(Icons.save_alt),
                            label: Text('导出${version.label}'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!recovery.canFinish) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '结束恢复前，请先导出未保存在当前文件中的备份版本。所有需要保留的版本安全保存后，才能清理内部备份。',
                  ),
                ],
                if (controller.isBusy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(controller.progress ?? '正在处理，请稍候…'),
                ],
              ],
            ],
          ),
        ),
        actions: [
          if (recovery != null) ...[
            OutlinedButton.icon(
              key: const ValueKey('retry-original-recovery'),
              onPressed:
                  controller.canOperate && controller.canRetryOriginalRecovery
                  ? controller.retryOriginalRecovery
                  : null,
              icon: const Icon(Icons.refresh),
              label: const Text('重新检查权限与恢复状态'),
            ),
            FilledButton.icon(
              key: const ValueKey('restore-original-backup'),
              onPressed: controller.canOperate && recovery.canRestore
                  ? () => _restore(context)
                  : null,
              icon: const Icon(Icons.restore),
              label: const Text('恢复原始备份'),
            ),
            TextButton(
              key: const ValueKey('finish-original-recovery'),
              onPressed: controller.canOperate && recovery.canFinish
                  ? () => _finish(context)
                  : null,
              child: const Text('保留当前文件并结束恢复'),
            ),
          ] else if (controller.exportRecoveryNotice != null)
            TextButton(
              onPressed: controller.canOperate
                  ? () async {
                      await controller.acknowledgeExportRecovery();
                      if (context.mounted &&
                          controller.recoveryNotice == null) {
                        Navigator.pop(context);
                      }
                    }
                  : null,
              child: const Text('已查看保存结果'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              recovery != null
                  ? '稍后决定'
                  : controller.exportRecoveryNotice == null
                  ? '知道了'
                  : '关闭',
            ),
          ),
        ],
      );
    },
  );
}
