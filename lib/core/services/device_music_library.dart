import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/audio_track.dart';
import '../storage/library_store.dart';
import 'audio_tag_reader.dart';
import 'device_artwork_cache.dart';

enum AudioLibraryPermission { notRequested, denied, blocked, granted }

abstract interface class DeviceMusicLibrary {
  Future<AudioLibraryPermission> permissionStatus();
  Future<AudioLibraryPermission> requestPermission();
  Future<void> openSettings();
  Future<List<AudioTrack>> querySongs();
  Future<AudioTrack> readDetails(AudioTrack track);
}

class AndroidMusicLibrary implements DeviceMusicLibrary, DeviceArtworkSource {
  AndroidMusicLibrary(
    this.directoryProvider, {
    this.channel = const MethodChannel('audio_fixer/device_library'),
  });

  final DirectoryProvider directoryProvider;
  final MethodChannel channel;
  int _artworkRevision = 0;

  @override
  int get artworkRevision => _artworkRevision;

  @override
  Future<Uint8List?> readArtworkThumbnail(AudioTrack track) async {
    if (!track.isDeviceTrack) return null;
    return channel.invokeMethod<Uint8List>('readArtworkThumbnail', {
      'uri': track.contentUri,
    });
  }

  Future<AudioLibraryPermission> _permission(String method) async =>
      AudioLibraryPermission.values.byName(
        await channel.invokeMethod<String>(method) ?? 'denied',
      );

  @override
  Future<AudioLibraryPermission> permissionStatus() =>
      _permission('permissionStatus');
  @override
  Future<AudioLibraryPermission> requestPermission() =>
      _permission('requestPermission');
  @override
  Future<void> openSettings() => channel.invokeMethod<void>('openSettings');

  @override
  Future<List<AudioTrack>> querySongs() async {
    final rows = await channel.invokeListMethod<dynamic>('querySongs');
    if (rows == null) throw const FormatException('系统音乐库没有返回有效数据');
    final tracks = rows.map((row) {
      final data = Map<String, dynamic>.from(row as Map);
      final uri = Uri.parse(data['contentUri'] as String);
      if (uri.scheme != 'content' || uri.authority != 'media') {
        throw const FormatException('系统音频地址无效');
      }
      return AudioTrack(
        id: data['id'] as String,
        fileName: data['fileName'] as String,
        contentUri: uri.toString(),
        sizeBytes: data['sizeBytes'] as int,
        importedAt: DateTime.fromMillisecondsSinceEpoch(
          data['dateAddedMs'] as int? ?? 0,
        ),
        dateModifiedMs: data['dateModifiedMs'] as int,
        title: data['title'] as String?,
        artist: data['artist'] as String?,
        album: data['album'] as String?,
        year: data['year'] as int?,
        durationMs: data['durationMs'] as int?,
        indexedDurationMs: data['durationMs'] as int?,
        volumeName: data['volumeName'] as String?,
        relativePath: data['relativePath'] as String?,
        detailsLoaded: false,
      );
    }).toList();
    // Refresh also retries absent/unsupported thumbnails, even if Android's
    // coarse modification timestamp has not advanced yet.
    _artworkRevision++;
    return tracks;
  }

  @override
  Future<AudioTrack> readDetails(AudioTrack track) async {
    String? path;
    try {
      path = await channel.invokeMethod<String>('copyForRead', {
        'uri': track.contentUri,
      });
      if (path == null) throw const FormatException('无法打开音频');
      final directory = await directoryProvider();
      return await readTrackTags(track, path, directory.path);
    } on PlatformException catch (error) {
      if (error.code == 'permission_denied') rethrow;
      if (error.code == 'read_too_large') {
        return track.withReadError('音频超过 512 MiB，目前无法读取完整标签。');
      }
      return track.withReadError('无法读取此音频。文件可能已移动、删除或暂时不可用，请刷新音乐库后重试。');
    } finally {
      if (path != null) {
        try {
          await channel.invokeMethod<void>('releaseReadCopy', {'path': path});
        } catch (error) {
          debugPrint('Temporary audio cleanup deferred: $error');
        }
      }
    }
  }
}
