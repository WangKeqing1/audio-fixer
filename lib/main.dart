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
  Directory? sourceCache;
  try {
    final support = await getApplicationSupportDirectory();
    sourceCache = Directory('${support.path}/source-cache');
  } catch (_) {
    // Cache persistence is optional. Still launch the app so the catalog can
    // display its own recoverable storage error instead of a blank startup.
  }
  final artworkStore = LocalArtworkStore(getApplicationSupportDirectory);
  final windowsAccess = Platform.isWindows
      ? WindowsFileAccess(getApplicationSupportDirectory)
      : null;
  final windowsLibrary = windowsAccess == null
      ? null
      : WindowsMusicLibrary(windowsAccess);
  runApp(
    AudioFixerApp(
      controller: LibraryController(
        store: JsonLibraryStore(getApplicationSupportDirectory),
        picker: SystemAudioPicker(),
        artworkPicker: SystemArtworkPicker(artworkStore),
        importer: LocalAudioImporter(getApplicationSupportDirectory),
        completion: CompletionService(
          sources: createOnlineSources(cacheDirectory: sourceCache),
          translator: Platform.isWindows
              ? null
              : PlatformLyricsTranslator(cacheDirectory: sourceCache),
        ),
        deviceLibrary:
            windowsLibrary ??
            AndroidMusicLibrary(getApplicationSupportDirectory),
        inventoryBackendFactory: windowsLibrary == null
            ? null
            : () =>
                  WindowsAudioInventoryBackend(windowsLibrary, windowsAccess!),
        exporter: SafeAudioCopyExporter(
          Platform.isWindows
              ? getApplicationSupportDirectory
              : getTemporaryDirectory,
          channel: windowsAccess == null
              ? const MethodChannel('audio_fixer/device_library')
              : WindowsFileMethodChannel(windowsAccess),
          localArtworkLoader: artworkStore.read,
        ),
      ),
    ),
  );
}
