import 'package:flutter/material.dart';

import '../../shared/widgets/translation_privacy.dart';
import '../library/library_controller.dart';

class OnDeviceTranslationSettings extends StatefulWidget {
  const OnDeviceTranslationSettings({super.key, required this.controller});
  final LibraryController controller;
  @override
  State<OnDeviceTranslationSettings> createState() =>
      _OnDeviceTranslationSettingsState();
}

class _OnDeviceTranslationSettingsState
    extends State<OnDeviceTranslationSettings> {
  bool _changing = false;
  Future<void> _change(bool value) async {
    if (_changing || !widget.controller.canOperate) return;
    setState(() => _changing = true);
    try {
      if (value && !await showTranslationPrivacy(context)) return;
      if (!mounted) return;
      await widget.controller.updateSettings(
        widget.controller.settings.copyWith(onDeviceTranslationEnabled: value),
      );
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const ValueKey('on-device-translation'),
    title: const Text('本机机器翻译补充'),
    subtitle: const Text('没有来源译文时，使用已下载的 Google Translate 模型；首次启用会说明数据与下载。'),
    value: widget.controller.settings.onDeviceTranslationEnabled,
    onChanged: widget.controller.canOperate && !_changing ? _change : null,
  );
}
