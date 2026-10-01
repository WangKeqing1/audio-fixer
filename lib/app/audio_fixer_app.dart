import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/models/app_settings.dart';
import '../features/library/library_controller.dart';
import 'app_shell.dart';
import 'app_theme.dart';

class AudioFixerApp extends StatefulWidget {
  const AudioFixerApp({super.key, required this.controller});
  final LibraryController controller;

  @override
  State<AudioFixerApp> createState() => _AudioFixerAppState();
}

class _AudioFixerAppState extends State<AudioFixerApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.initialize();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => MaterialApp(
      title: 'Audio Fixer',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: switch (widget.controller.settings.theme) {
        AppTheme.system => ThemeMode.system,
        AppTheme.light => ThemeMode.light,
        AppTheme.dark => ThemeMode.dark,
      },
      home: AppShell(controller: widget.controller),
    ),
  );
}
