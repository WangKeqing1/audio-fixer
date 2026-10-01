import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';

// Only plain Dart values enter the isolate; native streams/handles stay outside.
Future<AudioTrack> readTrackTags(AudioTrack track, String path, String root) =>
    Isolate.run(() => _read(track, path, root));

AudioTrack _read(AudioTrack track, String path, String root) {
  try {
    final metadata = readMetadata(File(path), getImage: true);
    String? artworkPath;
    if (metadata.pictures.isNotEmpty) {
      final picture = metadata.pictures.firstWhere(
        (picture) => picture.pictureType == PictureType.coverFront,
        orElse: () => metadata.pictures.first,
      );
      if (picture.bytes.isNotEmpty) {
        final directory = Directory(
          p.join(root, track.isDeviceTrack ? 'device_artwork' : 'artwork'),
        );
        directory.createSync(recursive: true);
        final key = track.isDeviceTrack
            ? sha256.convert(utf8.encode(track.id)).toString()
            : track.id;
        final file = File(p.join(directory.path, '$key.cover'));
        file.writeAsBytesSync(picture.bytes, flush: true);
        artworkPath = file.path;
      }
    }
    return track.withDetails(
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      year: metadata.year != null && metadata.year!.year > 0
          ? metadata.year!.year
          : null,
      durationMs: metadata.duration?.inMilliseconds ?? track.durationMs,
      lyrics: metadata.lyrics,
      artworkPath: artworkPath,
    );
  } catch (_) {
    return track.withReadError('标签读取失败，文件可能损坏或包含暂不支持的标签。');
  }
}
