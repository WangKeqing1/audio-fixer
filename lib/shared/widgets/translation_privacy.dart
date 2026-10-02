import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _translationChannel = MethodChannel('audio_fixer/lyrics_translation');

Future<void> _openTranslationInfo(BuildContext context, String url) async {
  try {
    await _translationChannel.invokeMethod<void>('openInfoLink', {'url': url});
  } catch (_) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('参考链接'),
        content: SelectableText(url),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

/// Must be shown before the app invokes the local language identifier or asks
/// ML Kit to download a model. Declining does not initialize the SDK here.
Future<bool> showTranslationPrivacy(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启用本机机器翻译？'),
        scrollable: true,
        content: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '没有来源译文时，使用 Google Translate 的 ML Kit 本机模型补充中文翻译。歌词和译文在设备上处理，不上传到 Google 翻译服务器。',
            ),
            SizedBox(height: 12),
            Text(
              'SDK 会向 Google 发送设备与应用信息、安装标识、语言配置及使用/性能指标。首次使用某种语言需要下载模型，约 30 MB/语言，仅在 Wi-Fi 下进行；下载前会再次列出所需模型。',
            ),
            SizedBox(height: 12),
            Text('机器翻译可能误解歌词，尤其是隐喻和多语言歌词。会明确标注机器翻译，仍需你确认后才保存；你可随时关闭。'),
            SizedBox(height: 8),
            TranslationHelpLinks(),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不启用'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('启用 Google Translate'),
          ),
        ],
      ),
    ) ??
    false;

class TranslationHelpLinks extends StatelessWidget {
  const TranslationHelpLinks({super.key});
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      TextButton(
        onPressed: () => _openTranslationInfo(
          context,
          'https://developers.google.com/ml-kit/terms',
        ),
        child: const Text('SDK 条款与隐私'),
      ),
      TextButton(
        onPressed: () => _openTranslationInfo(
          context,
          'https://developers.google.com/ml-kit/android-data-disclosure',
        ),
        child: const Text('数据说明'),
      ),
      TextButton(
        onPressed: () => _openTranslationInfo(
          context,
          'https://developers.google.com/ml-kit/language/translation',
        ),
        child: const Text('翻译说明'),
      ),
    ],
  );
}

class GoogleTranslationDisclaimer extends StatelessWidget {
  const GoogleTranslationDisclaimer({super.key});
  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const PageStorageKey('google-translation-disclaimer'),
    tilePadding: EdgeInsets.zero,
    title: const Text('机器翻译说明与免责声明'),
    children: const [
      Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Google Translate 的本机模型用于帮助理解原文，机器翻译不能替代人工翻译。非英语之间的翻译可能经过英语中转，准确性会受影响。\n\n'
          'THIS SERVICE MAY CONTAIN TRANSLATIONS POWERED BY GOOGLE. GOOGLE DISCLAIMS ALL WARRANTIES RELATED TO THE TRANSLATIONS, EXPRESS OR IMPLIED, INCLUDING ANY WARRANTIES OF ACCURACY, RELIABILITY, AND ANY IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.',
        ),
      ),
      TranslationHelpLinks(),
    ],
  );
}

class GoogleTranslationAttribution extends StatelessWidget {
  const GoogleTranslationAttribution({super.key});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: InkWell(
      onTap: () =>
          _openTranslationInfo(context, 'https://translate.google.com/'),
      child: ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Image.asset(
            'assets/google_translate/greyscale_regular_3x.png',
            width: 180,
            semanticLabel: 'powered by Google Translate',
            fit: BoxFit.contain,
          ),
        ),
      ),
    ),
  );
}
