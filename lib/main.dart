import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app/audio_fixer_app.dart';
import 'core/services/audio_importer.dart';
import 'core/services/artwork_picker.dart';
import 'core/services/completion_service.dart';
import 'core/services/device_music_library.dart';
import 'core/services/windows_file_access.dart';
import 'core/services/windows_file_method_channel.dart';
import 'core/services/windows_music_library.dart';
import 'core/services/windows_audio_inventory_backend.dart';
import 'core/services/lyrics_translation_service.dart';
import 'core/services/export/audio_copy_exporter.dart';
import 'core/services/sources/online_sources.dart';
import 'core/storage/library_store.dart';
import 'features/library/library_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Use one canonical support path for every Windows service. TEMP/profile
  // providers may contain valid 8.3 aliases; staging must match its allowlist.
  Future<Directory> supportDirectory() async {
    final directory = await getApplicationSupportDirectory();
    if (!Platform.isWindows) return directory;
    await directory.create(recursive: true);
    return Directory(await directory.resolveSymbolicLinks());
  }

  Directory? sourceCache;
  try {
    final support = await supportDirectory();
    sourceCache = Directory('${support.path}/source-cache');
  } catch (_) {
    // Cache persistence is optional. Still launch the app so the catalog can
    // display its own recoverable storage error instead of a blank startup.
  }
  final artworkStore = LocalArtworkStore(supportDirectory);
  final windowsAccess = Platform.isWindows
      ? WindowsFileAccess(supportDirectory)
      : null;
  final windowsLibrary = windowsAccess == null
      ? null
      : WindowsMusicLibrary(windowsAccess);
  runApp(
    AudioFixerApp(
      controller: LibraryController(
        store: JsonLibraryStore(supportDirectory),
        picker: SystemAudioPicker(),
        artworkPicker: SystemArtworkPicker(artworkStore),
        importer: LocalAudioImporter(supportDirectory),
        completion: CompletionService(
          sources: createOnlineSources(cacheDirectory: sourceCache),
          translator: Platform.isWindows
              ? null
              : PlatformLyricsTranslator(cacheDirectory: sourceCache),
        ),
        deviceLibrary: windowsLibrary ?? AndroidMusicLibrary(supportDirectory),
        inventoryBackendFactory: windowsLibrary == null
            ? null
            : () =>
                  WindowsAudioInventoryBackend(windowsLibrary, windowsAccess!),
        exporter: SafeAudioCopyExporter(
          Platform.isWindows ? supportDirectory : getTemporaryDirectory,
          channel: windowsAccess == null
              ? const MethodChannel('audio_fixer/device_library')
              : WindowsFileMethodChannel(windowsAccess),
          localArtworkLoader: artworkStore.read,
        ),
      ),
    ),
  );
}
