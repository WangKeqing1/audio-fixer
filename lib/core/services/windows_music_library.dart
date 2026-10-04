import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import 'audio_importer.dart';
import 'audio_tag_reader.dart';
import 'device_artwork_cache.dart';
import 'device_music_library.dart';
import 'windows_file_access.dart';

/// Folder-scoped Windows library. Junctions/symlinks are not followed and no
/// drive root, Downloads, or other unselected location is scanned implicitly.
class WindowsMusicLibrary implements FolderMusicLibrary, DeviceArtworkSource {
  WindowsMusicLibrary(this.access);
  final WindowsFileAccess access;
  int _revision = 0;
  int lastScanErrors = 0;

  List<String> get folders => access.roots;
  @override
  Future<bool> chooseFolder() => access.chooseLibraryFolder();

  @override
  int get artworkRevision => _revision;

  @override
  Future<AudioLibraryPermission> permissionStatus() async {
    await access.initialize();
    return access.roots.isEmpty
        ? AudioLibraryPermission.notRequested
        : AudioLibraryPermission.granted;
  }

  @override
  Future<AudioLibraryPermission> requestPermission() async =>
      await chooseFolder()
      ? AudioLibraryPermission.granted
      : await permissionStatus();

  @override
  Future<void> openSettings() async {
    await chooseFolder();
  }

  @override
  Future<List<AudioTrack>> querySongs() async {
    await access.initialize();
    final tracks = <String, AudioTrack>{};
    lastScanErrors = 0;
    for (final root in access.roots) {
      final queue = <Directory>[Directory(root)];
      while (queue.isNotEmpty) {
        final directory = queue.removeLast();
        try {
          if (!p.equals(
            await directory.resolveSymbolicLinks(),
            directory.path,
          )) {
            continue;
          }
          await for (final entity in directory.list(followLinks: false)) {
            if (entity is Directory) {
              queue.add(entity);
            } else if (entity is File &&
                supportedAudioExtensions.contains(
                  p.extension(entity.path).toLowerCase().replaceFirst('.', ''),
                )) {
              try {
                final file = await access.sourceFile(entity.uri.toString());
                final stat = await file.stat();
                final uri = file.uri.toString();
                tracks.putIfAbsent(
                  uri,
                  () => AudioTrack(
                    id: 'windows:${sha256.convert(utf8.encode(uri)).toString()}',
                    fileName: p.basename(file.path),
                    localPath: file.path,
                    contentUri: uri,
                    sizeBytes: stat.size,
                    importedAt: stat.changed,
                    dateModifiedMs: stat.modified.millisecondsSinceEpoch,
                    volumeName: 'windows:$root',
                    relativePath:
                        p.relative(file.parent.path, from: root) == '.'
                        ? ''
                        : p
                              .relative(file.parent.path, from: root)
                              .replaceAll('\\', '/'),
                    detailsLoaded: false,
                  ),
                );
              } on FileSystemException {
                lastScanErrors++;
              } on PlatformException {
                lastScanErrors++;
              }
            }
          }
        } on FileSystemException {
          lastScanErrors++;
        }
      }
    }
    if (lastScanErrors > 0) {
      // A disconnected root is an error, never evidence to delete its catalog.
      throw PlatformException(
        code: 'read_failed',
        message: '无法读取所选音乐文件夹，请确认磁盘已连接且可访问',
      );
    }
    _revision++;
    return tracks.values.toList()..sort(
      (a, b) => a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase()),
    );
  }

  @override
  Future<AudioTrack> readDetails(AudioTrack track) async {
    try {
      final file = await access.sourceFile(track.contentUri ?? '');
      if (await file.length() > 512 * 1024 * 1024) {
        return track.withReadError('音频超过 512 MiB，目前无法读取完整标签。');
      }
      final directory = await access.directoryProvider();
      return await readTrackTags(track, file.path, directory.path);
    } on FileSystemException {
      return track.withReadError('无法读取音频，文件可能已移动或删除，请刷新音乐库。');
    } on PlatformException catch (error) {
      return track.withReadError(error.message ?? '无法读取所选文件夹中的音频');
    }
  }

  @override
  Future<Uint8List?> readArtworkThumbnail(AudioTrack track) async {
    final details = await readDetails(track);
    final path = details.artworkPath;
    if (path == null || details.readError != null) return null;
    final file = File(path);
    if (await file.length() > 4 * 1024 * 1024) return null;
    return file.readAsBytes();
  }
}
