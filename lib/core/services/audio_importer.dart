import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import '../storage/library_store.dart';
import 'audio_tag_reader.dart';

const supportedAudioExtensions = ['mp3', 'flac', 'm4a', 'ogg', 'opus', 'wav'];

class AudioSelection {
  const AudioSelection({required this.name, required this.openRead});
  final String name;
  final Stream<List<int>> Function() openRead;
}

abstract interface class AudioPicker {
  Future<List<AudioSelection>> pick();
}

class SystemAudioPicker implements AudioPicker {
  @override
  Future<List<AudioSelection>> pick() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedAudioExtensions,
    );
    return files
        .map(
          (file) =>
              AudioSelection(name: file.name, openRead: file.readAsByteStream),
        )
        .toList();
  }
}

abstract interface class AudioImporter {
  Future<AudioTrack> import(AudioSelection selection);
  Future<void> prune(Set<String> retainedIds);
}

class LocalAudioImporter implements AudioImporter {
  LocalAudioImporter(this.directoryProvider);
  final DirectoryProvider directoryProvider;

  @override
  Future<void> prune(Set<String> retainedIds) async {
    final root = await directoryProvider();
    final ownedFile = RegExp(r'^([a-f0-9]{64})\.(audio|cover)$');
    for (final name in ['audio', 'artwork']) {
      final directory = Directory(p.join(root.path, name));
      if (!await directory.exists()) continue;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) {
          final match = ownedFile.firstMatch(p.basename(entity.path));
          if (match != null && !retainedIds.contains(match.group(1))) {
            await entity.delete();
          }
        } else if (name == 'audio' &&
            entity is Directory &&
            p.basename(entity.path).startsWith('import-')) {
          // Startup cleanup of interrupted copies. Only our known staging
          // filenames are removed, and unknown contents are left untouched.
          await for (final staged in entity.list(followLinks: false)) {
            if (staged is File &&
                supportedAudioExtensions.any(
                  (ext) => p.basename(staged.path) == 'source.$ext',
                )) {
              await staged.delete();
            }
          }
          if (await entity.list().isEmpty) await entity.delete();
        }
      }
    }
  }

  @override
  Future<AudioTrack> import(AudioSelection selection) async {
    final extension = p.extension(selection.name).toLowerCase();
    if (!supportedAudioExtensions.contains(extension.replaceFirst('.', ''))) {
      throw const FormatException('暂不支持此文件格式');
    }
    final directory = await directoryProvider();
    final audioDirectory = Directory(p.join(directory.path, 'audio'));
    await audioDirectory.create(recursive: true);
    final staging = await audioDirectory.createTemp('import-');
    try {
      final temporary = File(p.join(staging.path, 'source$extension'));
      final sink = temporary.openWrite();
      try {
        // Android's picker yields Stream<Uint8List>. IOSink.addStream accepts
        // those chunks without Stream.pipe's runtime consumer-type narrowing.
        await sink.addStream(selection.openRead());
      } finally {
        await sink.close();
      }
      final size = await temporary.length();
      if (size == 0) throw const FormatException('文件为空');
      final id = (await sha256.bind(temporary.openRead()).first).toString();
      // Container recognition uses file bytes; a renamed extension must not
      // create a second copy of the same content.
      final localFile = File(p.join(audioDirectory.path, '$id.audio'));
      if (!await localFile.exists()) await temporary.rename(localFile.path);

      // The parser is synchronous. Run it off the UI isolate for large files.
      return await readTrackTags(
        AudioTrack(
          id: id,
          fileName: selection.name,
          localPath: localFile.path,
          sizeBytes: size,
          importedAt: DateTime.now(),
        ),
        localFile.path,
        directory.path,
      );
    } finally {
      // Only this newly created staging directory is ever removed.
      await staging.delete(recursive: true);
    }
  }
}
