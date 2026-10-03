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

/// Optional capability for upgrading/rechecking imported private audio copies.
abstract interface class AudioDetailsImporter {
  Future<AudioTrack> readDetails(AudioTrack track);
}

class LocalAudioImporter implements AudioImporter, AudioDetailsImporter {
  LocalAudioImporter(this.directoryProvider);
  final DirectoryProvider directoryProvider;

  @override
  Future<AudioTrack> readDetails(AudioTrack track) async {
    if (track.isDeviceTrack ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(track.id) ||
        track.localPath.isEmpty) {
      return track.withReadError('只能重新读取本应用保留的音频副本。');
    }
    try {
      final root = await directoryProvider();
      final audioDirectory = Directory(p.join(root.path, 'audio'));
      final expectedPath = p.normalize(
        p.absolute(p.join(audioDirectory.path, '${track.id}.audio')),
      );
      if (!p.equals(p.normalize(p.absolute(track.localPath)), expectedPath) ||
          await FileSystemEntity.type(expectedPath, followLinks: false) !=
              FileSystemEntityType.file) {
        return track.withReadError('音频副本路径无效或文件已不存在，请重新导入。');
      }
      // Resolving the app root supports normal platform directory aliases;
      // a redirected audio directory or file must not expand read access.
      final resolvedRoot = await root.resolveSymbolicLinks();
      final resolvedDirectory = await audioDirectory.resolveSymbolicLinks();
      final source = File(expectedPath);
      final resolvedFile = await source.resolveSymbolicLinks();
      if (!p.equals(resolvedDirectory, p.join(resolvedRoot, 'audio')) ||
          !p.equals(
            resolvedFile,
            p.join(resolvedDirectory, '${track.id}.audio'),
          )) {
        return track.withReadError('音频副本路径已变化，请重新导入。');
      }
      if (await source.length() > 512 * 1024 * 1024) {
        return track.withReadError('音频超过 512 MiB，目前无法读取完整标签。');
      }
      return await readTrackTags(track, resolvedFile, root.path);
    } on FileSystemException {
      return track.withReadError('无法读取保留的音频副本，文件可能已移动或删除，请重新导入。');
    }
  }

  @override
  Future<void> prune(Set<String> retainedIds) async {
    final root = await directoryProvider();
    // Keep every cover revision for retained tracks: an open review can still
    // reference a previous cover. Remove all owned revisions with an orphan.
    final ownedFile = RegExp(
      r'^([a-f0-9]{64})\.(?:audio|(?:[a-f0-9]{64}\.)?cover)$',
    );
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
