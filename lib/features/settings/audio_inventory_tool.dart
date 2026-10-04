import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/audio_inventory_service.dart';
import '../../core/services/device_music_library.dart';
import '../../shared/widgets/notice_panel.dart';
import '../library/library_controller.dart';

typedef AudioInventoryServiceFactory = AudioInventoryService Function();

class AudioInventoryToolCard extends StatelessWidget {
  const AudioInventoryToolCard({
    super.key,
    required this.controller,
    this.serviceFactory,
  });

  final LibraryController controller;
  final AudioInventoryServiceFactory? serviceFactory;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: const ValueKey('open-audio-inventory'),
      leading: const Icon(Icons.description_outlined),
      title: const Text('导出音频清单 TXT'),
      subtitle: Text(
        controller.usesFolderLibrary
            ? '读取音乐文件夹，生成可自行查看和发送的清单'
            : '读取系统收录且已授权的音频，生成可自行查看和发送的清单',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => AudioInventoryToolPage(
            controller: controller,
            serviceFactory: serviceFactory,
          ),
        ),
      ),
    ),
  );
}

class AudioInventoryToolPage extends StatefulWidget {
  const AudioInventoryToolPage({
    super.key,
    required this.controller,
    this.serviceFactory,
  });

  final LibraryController controller;
  final AudioInventoryServiceFactory? serviceFactory;

  @override
  State<AudioInventoryToolPage> createState() => _AudioInventoryToolPageState();
}

class _AudioInventoryToolPageState extends State<AudioInventoryToolPage> {
  late final AudioInventoryService _service =
      widget.serviceFactory?.call() ??
      AudioInventoryService(
        backend: widget.controller.inventoryBackendFactory?.call(),
      );
  bool _starting = false;
  bool _authorizing = false;
  bool _permissionRechecked = false;
  bool _leaving = false;
  String? _operationError;

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _run({bool retry = false}) async {
    if (_leaving ||
        _starting ||
        _service.isRunning ||
        !widget.controller.canOperate) {
      return;
    }
    setState(() {
      _starting = true;
      _operationError = null;
      _permissionRechecked = false;
    });
    try {
      final result = await widget.controller
          .runInventoryOperation<AudioInventoryResult?>(() async {
            if (!mounted || _leaving) return null;
            return retry ? _service.retrySave() : _service.exportInventory();
          });
      if (!mounted) return;
      if (result == null) {
        _operationError = widget.controller.notice ?? '清单操作尚未开始，请等待其他任务结束后重试。';
      }
    } catch (_) {
      if (mounted) {
        _operationError = '清单操作未完成，请检查音频权限和可用空间后重试。';
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _authorize() async {
    if (_authorizing || !widget.controller.canOperate) return;
    setState(() => _authorizing = true);
    try {
      await widget.controller.authorizeLibrary();
      if (mounted) setState(() => _permissionRechecked = true);
    } finally {
      if (mounted) setState(() => _authorizing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, _service]),
    builder: (context, _) {
      final controller = widget.controller;
      final result = _service.result;
      final needsPermission =
          (controller.usesDeviceLibrary &&
              controller.libraryPermission != AudioLibraryPermission.granted) ||
          (result?.status == AudioInventoryStatus.permissionDenied &&
              !_permissionRechecked);
      final busy = _starting || _service.isRunning || _authorizing;
      final canStart = controller.canOperate && !busy && !needsPermission;
      return PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _leaving = true;
            unawaited(_service.cancel());
          }
        },
        child: Scaffold(
          key: const ValueKey('audio-inventory-page'),
          appBar: AppBar(title: const Text('导出音频清单 TXT')),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const NoticePanel(
                    icon: Icons.audio_file_outlined,
                    title: '导出前请了解清单内容',
                    message: '清单包含原文件名、相对目录和存储卷，以及系统索引与文件内常用标签中的歌名、歌手、专辑等字段、时长和大小。文件标签读取失败也会列出，并注明原因。\n\n清单可能透露文件命名和目录结构，发送前请先查看。清单不包含音频内容、歌词全文或封面图片。',
                  ),
                  const SizedBox(height: 12),
                  NoticePanel(
                    icon: Icons.folder_open_outlined,
                    title: controller.usesFolderLibrary
                        ? '覆盖已添加的音乐文件夹'
                        : '覆盖当前授权可见的系统音频',
                    message: controller.usesFolderLibrary
                        ? '包含已添加音乐文件夹及子文件夹中的音频，也包含被列表筛选排除的文件。不会扫描其他位置，不会改变排除规则或原音频。文件链接、无法读取的位置和不支持的格式可能不在清单内。'
                        : '包含系统媒体库收录的音频，包括被本应用排除的文件夹、60 秒以下短音频，以及未被系统标为“音乐”的音频。读取内部和当前已挂载的外部存储卷。\n\n未被系统收录的文件、其他应用私有目录和没有读取权限的内容可能不在清单内，不能保证覆盖设备上的全部文件。不会更改排除规则或原音频。',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    controller.usesFolderLibrary
                        ? '生成和保存不需要联网。完成后选择目标文件夹，会创建新的 TXT 文件，不覆盖已有清单，不自动上传。离开此页会取消操作。'
                        : '生成和保存不需要联网。完成后由系统让你选择 TXT 保存位置，不会自动上传或分享。离开此页会取消进行中的操作，并清理应用内的临时清单。',
                  ),
                  if (needsPermission) ...[
                    const SizedBox(height: 20),
                    const NoticePanel(
                      icon: Icons.lock_outline,
                      title: '需要音频读取权限',
                      message: '请先授权访问系统音频。授权后可重新生成清单；权限受限时不能将结果视为设备全部音频。',
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const ValueKey('authorize-audio-inventory'),
                      onPressed: controller.canOperate && !busy
                          ? _authorize
                          : null,
                      icon: const Icon(Icons.folder_shared_outlined),
                      label: Text(
                        controller.libraryPermission ==
                                AudioLibraryPermission.blocked
                            ? '打开系统设置授权'
                            : '授权读取音频',
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (_service.isRunning || _starting) ...[
                    _InventoryProgress(service: _service),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const ValueKey('cancel-audio-inventory'),
                      onPressed: _service.isRunning && !_service.isCancelling
                          ? _service.cancel
                          : null,
                      icon: const Icon(Icons.close),
                      label: Text(_service.isCancelling ? '正在取消…' : '取消导出'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_operationError case final message?) ...[
                    NoticePanel(
                      icon: Icons.error_outline,
                      title: '清单操作未完成',
                      message: message,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (result != null && !busy) ...[
                    _InventoryResult(result: result),
                    const SizedBox(height: 12),
                  ],
                  if (!controller.canOperate && !busy) ...[
                    const Text('应用正在处理其他任务，结束后即可生成清单。'),
                    const SizedBox(height: 12),
                  ],
                  if (_service.canRetrySave && !needsPermission) ...[
                    FilledButton.icon(
                      key: const ValueKey('retry-audio-inventory-save'),
                      onPressed: canStart ? () => _run(retry: true) : null,
                      icon: const Icon(Icons.save_as_outlined),
                      label: const Text('重新选择保存位置'),
                    ),
                    const SizedBox(height: 8),
                    const Text('完整清单暂时保留，可直接重试保存；离开此页后需要重新生成。'),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.icon(
                    key: const ValueKey('start-audio-inventory'),
                    onPressed: canStart ? _run : null,
                    icon: const Icon(Icons.description_outlined),
                    label: Text(result == null ? '生成并选择保存位置' : '重新生成清单'),
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

class _InventoryProgress extends StatelessWidget {
  const _InventoryProgress({required this.service});
  final AudioInventoryService service;

  @override
  Widget build(BuildContext context) {
    final label = switch (service.phase) {
      AudioInventoryPhase.scanning => '正在读取音频索引和文件标签…',
      AudioInventoryPhase.choosingDestination => '请在系统窗口选择 TXT 保存位置…',
      AudioInventoryPhase.saving => '正在保存 TXT，请稍候…',
      AudioInventoryPhase.cancelling => '正在取消并清理临时文件…',
      _ => '正在准备音频清单…',
    };
    final fraction =
        service.phase == AudioInventoryPhase.scanning && service.total > 0
        ? (service.scanned / service.total).clamp(0.0, 1.0)
        : null;
    return Semantics(
      liveRegion: true,
      child: Column(
        key: const ValueKey('audio-inventory-progress'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 10),
          Text(
            '已读取 ${service.scanned} / ${service.total < 0 ? '总数统计中' : service.total} 条 · 文件标签读取失败 ${service.readFailures} 条',
          ),
          if (service.progressWarning case final warning?) ...[
            const SizedBox(height: 8),
            Text(warning),
          ],
        ],
      ),
    );
  }
}

class _InventoryResult extends StatelessWidget {
  const _InventoryResult({required this.result});
  final AudioInventoryResult result;

  @override
  Widget build(BuildContext context) {
    final title = switch (result.status) {
      AudioInventoryStatus.saved => 'TXT 已保存',
      AudioInventoryStatus.cancelled => '导出已取消',
      AudioInventoryStatus.permissionDenied => '音频权限不可用',
      AudioInventoryStatus.busy => '另一个清单操作仍在进行',
      AudioInventoryStatus.failed => 'TXT 未能完整保存',
    };
    final messages = <String>[
      if (result.isSaved) '文件：${result.fileName}',
      if (result.message?.trim().isNotEmpty == true) result.message!,
      if (result.isSaved)
        '共记录 ${result.scanned} 条音频，文件标签读取成功 ${result.metadataSuccess} 条，读取失败 ${result.unreadable} 条。',
      if (result.isSaved && result.unreadable > 0)
        '读取失败的音频仍保留系统索引和失败说明；这些记录的文件标签不完整。',
      if (result.isSaved && result.coveragePartial)
        '清单覆盖不完整${result.volumeErrors > 0 ? '：${result.volumeErrors} 个存储卷未能完整读取' : ''}，请查看 TXT 中的覆盖范围说明。',
      if (result.possiblePartialDocument)
        '目标位置可能留下不完整的 TXT 文件，请先核对并删除该残留文件，再重新选择位置保存。',
      if (!result.isSaved &&
          result.message?.trim().isNotEmpty != true &&
          !result.possiblePartialDocument)
        '尚未确认清单完整保存。可重新尝试；原音频没有被修改。',
      if (result.isSaved) '可在刚才选择的位置打开 TXT，检查后自行发送。',
    ];
    return NoticePanel(
      key: const ValueKey('audio-inventory-result'),
      icon: result.isSaved ? Icons.task_alt : Icons.info_outline,
      title: title,
      message: messages.join('\n\n'),
    );
  }
}
