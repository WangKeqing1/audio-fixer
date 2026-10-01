import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/app_settings.dart';
import '../models/audio_track.dart';
import '../models/completion_task.dart';

typedef DirectoryProvider = Future<Directory> Function();

class LibrarySnapshot {
  const LibrarySnapshot({
    this.tracks = const [],
    this.tasks = const [],
    this.settings = const AppSettings(),
  });

  final List<AudioTrack> tracks;
  final List<CompletionTask> tasks;
  final AppSettings settings;

  Map<String, Object> toJson() => {
    'version': 1,
    'tracks': tracks.map((track) => track.toJson()).toList(),
    'tasks': tasks.map((task) => task.toJson()).toList(),
    'settings': settings.toJson(),
  };

  factory LibrarySnapshot.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('不支持的本地目录版本');
    }
    return LibrarySnapshot(
      tracks: (json['tracks'] as List)
          .map((item) => AudioTrack.fromJson(item as Map<String, dynamic>))
          .toList(),
      tasks: (json['tasks'] as List)
          .map((item) => CompletionTask.fromJson(item as Map<String, dynamic>))
          .toList(),
      settings: AppSettings.fromJson(json['settings'] as Map<String, dynamic>),
    );
  }
}

abstract interface class LibraryStore {
  Future<LibrarySnapshot> load();
  Future<void> save(LibrarySnapshot snapshot);
}

class JsonLibraryStore implements LibraryStore {
  JsonLibraryStore(this.directoryProvider);
  final DirectoryProvider directoryProvider;

  Future<File> _file() async {
    final directory = await directoryProvider();
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'library.json'));
  }

  @override
  Future<LibrarySnapshot> load() async {
    final file = await _file();
    if (!await file.exists()) return const LibrarySnapshot();
    // Corrupt data must surface as an error, not silently become an empty library.
    return LibrarySnapshot.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> save(LibrarySnapshot snapshot) async {
    final file = await _file();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    await temporary.rename(file.path);
  }
}
