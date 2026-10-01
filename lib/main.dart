import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/audio_fixer_app.dart';
import 'core/services/audio_importer.dart';
import 'core/services/completion_service.dart';
import 'core/services/device_music_library.dart';
import 'core/services/sources/online_sources.dart';
import 'core/storage/library_store.dart';
import 'features/library/library_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    AudioFixerApp(
      controller: LibraryController(
        store: JsonLibraryStore(getApplicationSupportDirectory),
        picker: SystemAudioPicker(),
        importer: LocalAudioImporter(getApplicationSupportDirectory),
        completion: CompletionService(sources: createOnlineSources()),
        deviceLibrary: AndroidMusicLibrary(getApplicationSupportDirectory),
      ),
    ),
  );
}
