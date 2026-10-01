import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../models/audio_track.dart';
import '../../models/completion_task.dart';
import '../../storage/library_store.dart';
import 'audio_payload.dart';
import 'mp3_tag_overlay.dart';
import 'flac_tag_overlay.dart';
import 'mp4_tag_overlay.dart';

abstract interface class AudioCopyExporter {
  bool supports(AudioTrack track);
  Future<String?> export(AudioTrack track, List<FieldSuggestion> selected);
}

class ExportException implements Exception {
  const ExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Every edit is made to a temporary copy. Android's system save dialog creates
/// a new document; no write permission or writable handle to the source is used.
class SafeAudioCopyExporter implements AudioCopyExporter {
  SafeAudioCopyExporter(
    this.cacheDirectory, {
    this.channel = const MethodChannel('audio_fixer/device_library'),
  });
  final DirectoryProvider cacheDirectory;
  final MethodChannel channel;
  static const supportedExtensions = {'mp3', 'flac', 'm4a', 'mp4'};

  @override
  bool supports(AudioTrack track) =>
      supportedExtensions.contains(track.extension.toLowerCase());

  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    if (!supports(track)) {
      throw const ExportException('此格式暂不支持安全导出，目前支持 MP3、FLAC 和 M4A/MP4。');
    }
    String? readCopy;
    Directory? work;
    try {
      final sourcePath = track.isDeviceTrack
          ? readCopy = await channel.invokeMethod<String>('copyForRead', {
              'uri': track.contentUri,
            })
          : track.localPath;
      if (sourcePath == null || sourcePath.isEmpty) {
        throw const ExportException('无法读取原音频，请刷新音乐库后重试。');
      }
      final root = Directory(
        p.join((await cacheDirectory()).path, 'tagged_exports'),
      );
      await root.create(recursive: true);
      work = await root.createTemp('export_');
      final extension = track.extension.toLowerCase();
      final output = p.join(work.path, 'tagged.$extension');
      final values = <AudioField, String>{};
      Uint8List? artwork;
      for (final candidate in selected) {
        if (values.containsKey(candidate.field)) {
          throw const ExportException('同一字段只能选择一个候选。');
        }
        if (!hasText(candidate.value)) {
          throw const ExportException('候选内容为空，请重新查询。');
        }
        values[candidate.field] = candidate.value;
        if (candidate.field == AudioField.artwork) {
          artwork = await _downloadArtwork(candidate.value);
        }
      }
      await prepareTaggedCopy(
        sourcePath: sourcePath,
        outputPath: output,
        extension: extension,
        values: values,
        artwork: artwork,
        expectedTrack: track,
      );
      return await channel.invokeMethod<String>('exportAudioCopy', {
        'path': output,
        'fileName':
            '${p.basenameWithoutExtension(track.fileName)}-fixed.$extension',
        'mimeType': switch (extension) {
          'mp3' => 'audio/mpeg',
          'flac' => 'audio/flac',
          _ => 'audio/mp4',
        },
      });
    } finally {
      if (readCopy != null) {
        try {
          await channel.invokeMethod<void>('releaseReadCopy', {
            'path': readCopy,
          });
        } catch (_) {
          /* best-effort cache cleanup */
        }
      }
      if (work != null) {
        try {
          if (await work.exists()) await work.delete(recursive: true);
        } catch (_) {
          /* cleanup must not hide a saved export */
        }
      }
    }
  }
}

/// Public for reproducible offline fixture tests. Does not mutate [sourcePath].
Future<void> prepareTaggedCopy({
  required String sourcePath,
  required String outputPath,
  required String extension,
  required Map<AudioField, String> values,
  Uint8List? artwork,
  AudioTrack? expectedTrack,
}) => Isolate.run(() async {
  if (!SafeAudioCopyExporter.supportedExtensions.contains(
    extension.toLowerCase(),
  )) {
    throw const ExportException('此格式暂不支持安全导出。');
  }
  if (values.isEmpty) throw const ExportException('请至少选择一项要写入的资料。');
  final source = File(sourcePath);
  final output = File(outputPath);
  if (await source.resolveSymbolicLinks() ==
      p.normalize(p.absolute(outputPath))) {
    throw const ExportException('输出不能覆盖原音频。');
  }
  if (await output.exists()) throw const ExportException('输出文件已存在，请选择新的副本。');
  if (await source.length() > 512 * 1024 * 1024) {
    throw const ExportException('音频超过 512 MiB，暂不支持导出。');
  }
  final beforeFile = await sha256.bind(source.openRead()).first;
  final beforeAudio = await audioPayloadDigest(source, extension);
  final original = readMetadata(source, getImage: true);
  if (extension.toLowerCase() == 'mp3') {
    original.trackNumber ??= legacyMp3TrackNumber(source);
    if (!hasText(original.lyrics)) original.lyrics = customMp3Lyrics(source);
  }
  if (expectedTrack != null && expectedTrack.detailsLoaded) {
    String? normalized(String? value) => hasText(value) ? value!.trim() : null;
    if (normalized(original.title) != normalized(expectedTrack.title) ||
        normalized(original.artist) != normalized(expectedTrack.artist) ||
        normalized(original.album) != normalized(expectedTrack.album) ||
        (original.duration != null &&
            expectedTrack.durationMs != null &&
            (original.duration!.inMilliseconds - expectedTrack.durationMs!)
                    .abs() >
                1000)) {
      throw const ExportException('原文件资料已变化，请重新读取并查询后再导出。');
    }
  }
  for (final entry in values.entries) {
    if (!hasText(entry.value)) throw const ExportException('候选内容不能为空。');
    final existing = switch (entry.key) {
      AudioField.title => original.title,
      AudioField.artist => original.artist,
      AudioField.album => original.album,
      AudioField.lyrics => original.lyrics,
      AudioField.artwork => original.pictures.isEmpty ? null : 'embedded',
    };
    if (hasText(existing)) {
      throw ExportException('${entry.key.label}已存在，已停止以避免覆盖。请重新读取歌曲资料。');
    }
  }
  if (values.containsKey(AudioField.artwork) &&
      (artwork == null || artwork.isEmpty)) {
    throw const ExportException('封面下载未完成，未导出音频。');
  }
  await output.parent.create(recursive: true);
  try {
    await source.copy(output.path);
    if (extension.toLowerCase() == 'mp3') {
      await addMissingMp3Tags(
        output,
        values,
        artwork,
        artwork == null ? null : _imageMime(artwork),
      );
    } else if (extension.toLowerCase() == 'flac') {
      await addMissingFlacTags(
        output,
        values,
        artwork,
        artwork == null ? null : _imageMime(artwork),
      );
    } else {
      await addMissingMp4Tags(
        output,
        values,
        artwork,
        artwork == null ? null : _imageMime(artwork),
      );
    }
    final result = readMetadata(output, getImage: true);
    if (extension.toLowerCase() == 'mp3' && !hasText(result.lyrics)) {
      result.lyrics = customMp3Lyrics(output);
    }
    for (final entry in values.entries) {
      final actual = switch (entry.key) {
        AudioField.title => result.title,
        AudioField.artist => result.artist,
        AudioField.album => result.album,
        AudioField.lyrics => result.lyrics,
        AudioField.artwork =>
          result.pictures.isNotEmpty &&
                  sha256.convert(result.pictures.first.bytes) ==
                      sha256.convert(artwork!)
              ? entry.value
              : null,
      };
      if (actual != entry.value) {
        throw ExportException('${entry.key.label}写入校验失败，未导出音频。');
      }
    }
    // Check the unmodified common fields as well as the encoded audio payload.
    if ((!values.containsKey(AudioField.title) &&
            result.title != original.title) ||
        (!values.containsKey(AudioField.artist) &&
            result.artist != original.artist) ||
        (!values.containsKey(AudioField.album) &&
            result.album != original.album) ||
        (!values.containsKey(AudioField.lyrics) &&
            result.lyrics != original.lyrics) ||
        result.year != original.year ||
        result.albumArtist != original.albumArtist ||
        result.language != original.language ||
        result.trackNumber != original.trackNumber ||
        result.trackTotal != original.trackTotal ||
        result.discNumber != original.discNumber ||
        result.totalDisc != original.totalDisc ||
        result.sampleRate != original.sampleRate ||
        jsonEncode(result.genres) != jsonEncode(original.genres) ||
        jsonEncode(result.performers) != jsonEncode(original.performers) ||
        jsonEncode(
              result.chapters
                  .map((v) => [v.start.inMicroseconds, v.title])
                  .toList(),
            ) !=
            jsonEncode(
              original.chapters
                  .map((v) => [v.start.inMicroseconds, v.title])
                  .toList(),
            ) ||
        (!values.containsKey(AudioField.artwork) &&
            result.pictures
                    .map((v) => sha256.convert(v.bytes).toString())
                    .join(',') !=
                original.pictures
                    .map((v) => sha256.convert(v.bytes).toString())
                    .join(','))) {
      throw const ExportException('已有资料发生变化，已停止导出。');
    }
    if (await audioPayloadDigest(output, extension) != beforeAudio ||
        await sha256.bind(source.openRead()).first != beforeFile) {
      throw const ExportException('音频完整性校验失败，已停止导出。');
    }
  } catch (_) {
    if (await output.exists()) await output.delete();
    rethrow;
  }
});

String _imageMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  throw const ExportException('封面格式不受支持，仅支持 JPEG 和 PNG。');
}

Future<Uint8List> _downloadArtwork(String value) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await (() async {
      var uri = Uri.parse(value);
      for (var redirect = 0; redirect < 6; redirect++) {
        if (uri.scheme != 'https' ||
            uri.hasPort ||
            uri.userInfo.isNotEmpty ||
            !(uri.host == 'coverartarchive.org' ||
                uri.host == 'archive.org' ||
                uri.host.endsWith('.archive.org'))) {
          throw const ExportException('封面来源地址不受信任，未下载。');
        }
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          if (location == null) throw const ExportException('封面地址跳转异常。');
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          throw const ExportException('封面下载失败，请稍后重试。');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 10 * 1024 * 1024) {
            throw const ExportException('封面超过 10 MiB，已停止下载。');
          }
          bytes.add(chunk);
        }
        final result = bytes.takeBytes();
        _imageMime(result);
        return result;
      }
      throw const ExportException('封面跳转过多，已停止下载。');
    })().timeout(const Duration(seconds: 30));
  } finally {
    client.close(force: true);
  }
}
