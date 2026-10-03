import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../models/audio_track.dart';
import '../../models/audio_field_validation.dart';
import '../standard_audio_tags.dart';
import '../sources/netease_lyrics_source.dart' show isNeteaseArtworkUri;
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

/// Optional original-file writer. A null result means consent was cancelled.
abstract interface class AudioOriginalSaver {
  bool supportsOriginal(AudioTrack track);
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  );
}

/// Optional batch consent. Only reviewed/eligible originals may be passed.
/// This requests access without changing any audio and returns false on cancel.
abstract interface class AudioBatchOriginalSaver {
  Future<bool> authorizeOriginalWrites(List<AudioTrack> tracks);
}

/// A retained recovery version; [id] is opaque except native's "original".
class RecoveryAudioVersion {
  const RecoveryAudioVersion({
    required this.id,
    required this.label,
    required this.sha256,
    required this.sizeBytes,
    this.exportedUri,
  });
  final String id;
  final String label;
  final String sha256;
  final int sizeBytes;
  final String? exportedUri;
  factory RecoveryAudioVersion.fromMap(Map<Object?, Object?> data) =>
      RecoveryAudioVersion(
        id: data['id'] as String,
        label: data['label'] as String,
        sha256: data['sha256'] as String,
        sizeBytes: (data['sizeBytes'] as num).toInt(),
        exportedUri: data['exportedUri'] as String?,
      );
}

/// Structured recovery choices. UI must use flags, not translated notice text.
class OriginalRecoveryState {
  const OriginalRecoveryState({
    required this.status,
    required this.targetUri,
    required this.canRestore,
    required this.canFinish,
    required this.versions,
  });
  final String status;
  final String targetUri;
  final bool canRestore;
  final bool canFinish;
  final List<RecoveryAudioVersion> versions;
  factory OriginalRecoveryState.fromMap(Map<Object?, Object?> data) =>
      OriginalRecoveryState(
        status: data['status'] as String,
        targetUri: data['targetUri'] as String,
        canRestore: data['canRestore'] == true,
        canFinish: data['canFinish'] == true,
        versions: (data['versions'] as List<Object?>)
            .map(
              (value) => RecoveryAudioVersion.fromMap(
                Map<Object?, Object?>.from(value! as Map),
              ),
            )
            .toList(growable: false),
      );
}

/// Rechecking/regranting permission never authorizes replacing unknown content.
abstract interface class AudioOriginalRecovery {
  Future<String?> retryOriginalRecovery();
  Future<OriginalRecoveryState?> getOriginalRecoveryState();
  Future<String?> restoreOriginalBackup();
  Future<String?> exportOriginalRecoveryVersion(String versionId);
  Future<void> finishOriginalRecovery();
}

/// A batch chooses one destination tree and then creates separate verified files.
abstract interface class AudioBatchExporter {
  Future<String?> chooseExportDirectory();
  Future<String?> exportToDirectory(
    AudioTrack track,
    List<FieldSuggestion> selected,
    String directoryUri,
  );
}

/// Optional native lifecycle recovery; simple exporters/mocks need not implement it.
abstract interface class AudioExportRecovery {
  Future<String?> recoverInterruptedExport();
  Future<void> acknowledgeExportRecovery();
  Future<void> confirmExportRecorded(String uri);
}

class ExportException implements Exception {
  const ExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Tags are prepared and verified on a temporary copy before native storage
/// handles consent, backup, source-race checks, destination verification/recovery.
class SafeAudioCopyExporter
    implements
        AudioCopyExporter,
        AudioOriginalSaver,
        AudioBatchOriginalSaver,
        AudioOriginalRecovery,
        AudioBatchExporter,
        AudioExportRecovery {
  SafeAudioCopyExporter(
    this.cacheDirectory, {
    this.channel = const MethodChannel('audio_fixer/device_library'),
    this.localArtworkLoader,
  });
  final DirectoryProvider cacheDirectory;
  final MethodChannel channel;

  /// Supplied by the scoped artwork picker; this exporter never reads arbitrary
  /// file URIs. The loader owns the allowlist of immutable imported covers.
  final Future<Uint8List> Function(String)? localArtworkLoader;
  static const supportedExtensions = {'mp3', 'flac', 'm4a', 'mp4'};

  @override
  Future<String?> recoverInterruptedExport() =>
      channel.invokeMethod<String>('recoverExport');

  @override
  Future<void> acknowledgeExportRecovery() =>
      channel.invokeMethod<void>('acknowledgeExportRecovery');

  @override
  Future<void> confirmExportRecorded(String uri) =>
      channel.invokeMethod<void>('confirmExportRecorded', {'uri': uri});

  @override
  bool supports(AudioTrack track) =>
      supportedExtensions.contains(track.extension.toLowerCase());

  @override
  bool supportsOriginal(AudioTrack track) =>
      supports(track) && track.isDeviceTrack;

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    if (!supportsOriginal(track)) {
      throw const ExportException('旧版导入副本使用固定内容标识，不能覆盖；请导出新的音频副本。');
    }
    return _save(track, selected, original: true);
  }

  @override
  Future<bool> authorizeOriginalWrites(List<AudioTrack> tracks) async =>
      await channel.invokeMethod<bool>('authorizeOriginalWrites', {
        'uris': tracks
            .where((track) => track.isDeviceTrack)
            .map((track) => track.contentUri!)
            .toSet()
            .toList(),
      }) ??
      false;

  @override
  Future<String?> retryOriginalRecovery() =>
      channel.invokeMethod<String>('retryOriginalRecovery');

  @override
  Future<OriginalRecoveryState?> getOriginalRecoveryState() async {
    final value = await channel.invokeMapMethod<Object?, Object?>(
      'getOriginalRecoveryState',
    );
    return value == null ? null : OriginalRecoveryState.fromMap(value);
  }

  @override
  Future<String?> restoreOriginalBackup() =>
      channel.invokeMethod<String>('restoreOriginalBackup');

  @override
  Future<String?> exportOriginalRecoveryVersion(String versionId) =>
      channel.invokeMethod<String>('exportOriginalRecoveryVersion', {
        'versionId': versionId,
      });

  @override
  Future<void> finishOriginalRecovery() =>
      channel.invokeMethod<void>('finishOriginalRecovery');

  @override
  Future<String?> chooseExportDirectory() =>
      channel.invokeMethod<String>('chooseExportDirectory');

  @override
  Future<String?> exportToDirectory(
    AudioTrack track,
    List<FieldSuggestion> selected,
    String directoryUri,
  ) => _save(track, selected, directoryUri: directoryUri);

  @override
  Future<String?> export(AudioTrack track, List<FieldSuggestion> selected) =>
      _save(track, selected);

  Future<String?> _save(
    AudioTrack track,
    List<FieldSuggestion> selected, {
    bool original = false,
    String? directoryUri,
  }) async {
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
      final replaceFields = <AudioField>{};
      Uint8List? artwork;
      for (final candidate in selected) {
        if (values.containsKey(candidate.field)) {
          throw const ExportException('同一字段只能选择一个候选。');
        }
        if (!hasText(candidate.value)) {
          throw const ExportException('候选内容为空，请重新查询。');
        }
        values[candidate.field] = candidate.value;
        if (candidate.replaceExisting) replaceFields.add(candidate.field);
        if (candidate.field == AudioField.artwork) {
          if (Uri.tryParse(candidate.value)?.scheme == 'file') {
            final loader = localArtworkLoader;
            if (loader == null) throw const ExportException('本地封面未授权，请重新选择图片。');
            artwork = await loader(candidate.value);
            _imageMime(artwork);
          } else {
            artwork = await loadRemoteArtwork(candidate.value);
          }
        }
      }
      // This is the exact source snapshot used to generate the verified tags.
      // Native compares it again against the live original immediately before
      // opening a truncating writer, including after an Android consent dialog.
      final sourceSha256 =
          (await sha256.bind(File(sourcePath).openRead()).first).toString();
      await prepareTaggedCopy(
        sourcePath: sourcePath,
        outputPath: output,
        extension: extension,
        values: values,
        artwork: artwork,
        expectedTrack: track,
        replaceFields: replaceFields,
      );
      return await channel.invokeMethod<String>(
        original
            ? 'saveAudioOriginal'
            : directoryUri != null
            ? 'exportAudioToDirectory'
            : 'exportAudioCopy',
        {
          if (original) ...{
            'sourceUri': track.contentUri,
            'sourcePath': track.isDeviceTrack ? null : track.localPath,
            'sourceSha256': sourceSha256,
          },
          'directoryUri': ?directoryUri,
          'path': output,
          'fileName':
              '${p.basenameWithoutExtension(track.fileName)}-fixed.$extension',
          'mimeType': switch (extension) {
            'mp3' => 'audio/mpeg',
            'flac' => 'audio/flac',
            _ => 'audio/mp4',
          },
        },
      );
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
  Set<AudioField> replaceFields = const {},
}) async {
  // Native codecs are available on the caller's UI isolate. Decode before the
  // byte-only tagging isolate so a CRC-valid but corrupt image cannot replace
  // a good cover, and bound original dimensions before allocating pixels.
  if (values.containsKey(AudioField.artwork) && artwork != null) {
    await _validateArtworkPixels(artwork);
  }
  await Isolate.run(() async {
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
    final originalTags = readStandardAudioTags(source);
    String? normalized(AudioField field, String? value) {
      if (!hasText(value)) return null;
      return field.isNumeric
          ? int.tryParse(value!.trim())?.toString()
          : value!.trim();
    }

    Picture? displayedArtwork(AudioMetadata metadata) {
      if (metadata.pictures.isEmpty) return null;
      return metadata.pictures.firstWhere(
        (picture) => picture.pictureType == PictureType.coverFront,
        orElse: () => metadata.pictures.first,
      );
    }

    String? artworkHash(AudioMetadata metadata) {
      final picture = displayedArtwork(metadata);
      return picture == null || picture.bytes.isEmpty
          ? null
          : sha256.convert(picture.bytes).toString();
    }

    String? currentValue(AudioField field) => field == AudioField.artwork
        ? artworkHash(original)
        : originalTags.valueOf(field);
    if (replaceFields.any((field) => !values.containsKey(field))) {
      throw const ExportException('覆盖授权包含未选择的字段。');
    }
    if (replaceFields.isNotEmpty &&
        (expectedTrack == null ||
            !expectedTrack.detailsLoaded ||
            expectedTrack.readError != null)) {
      throw const ExportException('替换资料前请重新读取歌曲，确认当前内容。');
    }
    if (expectedTrack != null && expectedTrack.detailsLoaded) {
      // Keep the identity check for normal fills; additionally check every edited
      // field against the reviewed snapshot before allowing a replacement.
      final checked = {
        AudioField.title,
        AudioField.artist,
        AudioField.album,
        ...values.keys,
      };
      for (final field in checked) {
        if (field == AudioField.artwork) {
          final expectedHash = expectedTrack.artworkSha256;
          if ((hasText(expectedTrack.artworkPath) && expectedHash == null) ||
              expectedHash != artworkHash(original)) {
            throw const ExportException('原文件封面已变化或缺少校验信息，请重新读取后再保存。');
          }
        } else if (normalized(field, originalTags.valueOf(field)) !=
            normalized(field, expectedTrack.valueOf(field))) {
          throw const ExportException('原文件资料已变化，请重新读取并查询后再导出。');
        }
      }
      if (original.duration != null &&
          expectedTrack.durationMs != null &&
          (original.duration!.inMilliseconds - expectedTrack.durationMs!)
                  .abs() >
              1000) {
        throw const ExportException('原文件资料已变化，请重新读取并查询后再导出。');
      }
    }
    for (final entry in values.entries) {
      final error = validateAudioFieldValue(entry.key, entry.value);
      if (error != null) throw ExportException(error);
      if (hasText(currentValue(entry.key)) &&
          !replaceFields.contains(entry.key)) {
        throw ExportException('${entry.key.label}已存在，已停止以避免覆盖。请重新读取歌曲资料。');
      }
    }
    for (final (number, total) in const [
      (AudioField.trackNumber, AudioField.trackTotal),
      (AudioField.discNumber, AudioField.discTotal),
    ]) {
      if (!values.containsKey(number) && !values.containsKey(total)) continue;
      final index = int.tryParse(
        values[number] ?? originalTags.valueOf(number) ?? '',
      );
      final count = int.tryParse(
        values[total] ?? originalTags.valueOf(total) ?? '',
      );
      if (index != null && count != null && index > count) {
        throw ExportException('${number.label}不能大于${total.label}。');
      }
    }
    if (values.containsKey(AudioField.artwork)) {
      if (artwork == null || artwork.isEmpty) {
        throw const ExportException('封面下载未完成，未导出音频。');
      }
      _imageMime(artwork);
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
          replaceFields: replaceFields,
        );
      } else if (extension.toLowerCase() == 'flac') {
        await addMissingFlacTags(
          output,
          values,
          artwork,
          artwork == null ? null : _imageMime(artwork),
          replaceFields: replaceFields,
        );
      } else {
        await addMissingMp4Tags(
          output,
          values,
          artwork,
          artwork == null ? null : _imageMime(artwork),
          replaceFields: replaceFields,
        );
      }
      final result = readMetadata(output, getImage: true);
      final resultTags = readStandardAudioTags(output);
      for (final entry in values.entries) {
        final actual = entry.key == AudioField.artwork
            ? (artworkHash(result) == sha256.convert(artwork!).toString()
                  ? entry.value
                  : null)
            : resultTags.valueOf(entry.key);
        if (normalized(entry.key, actual) !=
            normalized(entry.key, entry.value)) {
          throw ExportException('${entry.key.label}写入校验失败，未导出音频。');
        }
      }
      // Verify every untouched common field with the same format-aware reader
      // used for review, not the dependency's lossy cross-format projection.
      for (final field in AudioField.values) {
        if (field == AudioField.artwork || values.containsKey(field)) continue;
        if (resultTags.valueOf(field) != originalTags.valueOf(field)) {
          throw ExportException('未选择的${field.label}发生变化，已停止导出。');
        }
      }
      String picturesDigest(Iterable<Picture> pictures) => pictures
          .map(
            (picture) =>
                '${picture.pictureType.index}:${picture.mimetype}:${sha256.convert(picture.bytes)}',
          )
          .join(',');
      final artworkSelected = values.containsKey(AudioField.artwork);
      // MP4 covr has no role; its first picture is the displayed cover. MP3/FLAC
      // replace all type-3 fronts and preserve every other picture exactly.
      Iterable<Picture> preservedPictures(AudioMetadata metadata) {
        if (!artworkSelected) return metadata.pictures;
        if (extension.toLowerCase() == 'm4a' ||
            extension.toLowerCase() == 'mp4') {
          return metadata.pictures.skip(1);
        }
        return metadata.pictures.where(
          (picture) => picture.pictureType != PictureType.coverFront,
        );
      }

      if (result.language != original.language ||
          result.sampleRate != original.sampleRate ||
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
          picturesDigest(preservedPictures(result)) !=
              picturesDigest(preservedPictures(original))) {
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
}

Future<void> _validateArtworkPixels(Uint8List bytes) async {
  _imageMime(bytes);
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width <= 0 ||
        descriptor.height <= 0 ||
        descriptor.width > 8192 ||
        descriptor.height > 8192 ||
        descriptor.width * descriptor.height > 16000000) {
      throw const ExportException('封面尺寸过大，请选择不超过 1600 万像素的图片。');
    }
    codec = await descriptor.instantiateCodec(targetWidth: 1, targetHeight: 1);
    final frame = await codec.getNextFrame();
    frame.image.dispose();
  } on ExportException {
    rethrow;
  } catch (_) {
    throw const ExportException('封面图片已损坏，无法解码，请重新选择图片。');
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

String _imageMime(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
    throw const ExportException('封面为空或超过 10 MiB，未写入。');
  }
  bool dimensions(int width, int height) =>
      width > 0 &&
      height > 0 &&
      width <= 16384 &&
      height <= 16384 &&
      width * height <= 40000000;
  if (bytes.length >= 8 &&
      bytes.take(8).join(',') == '137,80,78,71,13,10,26,10') {
    final data = ByteData.sublistView(bytes);
    var cursor = 8;
    var header = false;
    var pixels = false;
    while (cursor + 12 <= bytes.length) {
      final length = data.getUint32(cursor);
      final end = cursor + 12 + length;
      if (end > bytes.length) break;
      final type = ascii.decode(
        bytes.sublist(cursor + 4, cursor + 8),
        allowInvalid: true,
      );
      var crc = 0xffffffff;
      for (var i = cursor + 4; i < cursor + 8 + length; i++) {
        crc ^= bytes[i];
        for (var bit = 0; bit < 8; bit++) {
          crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
        }
      }
      if ((crc ^ 0xffffffff) != data.getUint32(cursor + 8 + length)) break;
      if (!header) {
        if (type != 'IHDR' ||
            length != 13 ||
            !dimensions(
              data.getUint32(cursor + 8),
              data.getUint32(cursor + 12),
            )) {
          break;
        }
        header = true;
      } else if (type == 'IHDR') {
        break;
      }
      if (type == 'IDAT' && length > 0) pixels = true;
      if (type == 'IEND') {
        if (length == 0 && header && pixels && end == bytes.length) {
          return 'image/png';
        }
        break;
      }
      cursor = end;
    }
    throw const ExportException('PNG 封面损坏或尺寸过大，请重新选择图片。');
  }
  if (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    var cursor = 2;
    var frame = false;
    var scan = false;
    while (cursor < bytes.length) {
      if (bytes[cursor++] != 0xff) break;
      while (cursor < bytes.length && bytes[cursor] == 0xff) {
        cursor++;
      }
      if (cursor >= bytes.length) break;
      final marker = bytes[cursor++];
      if (marker == 0xd9) {
        if (frame && scan && cursor == bytes.length) return 'image/jpeg';
        break;
      }
      if (marker == 0x00 ||
          marker == 0xd8 ||
          (marker >= 0xd0 && marker <= 0xd7)) {
        break;
      }
      if (cursor + 2 > bytes.length) break;
      final length = (bytes[cursor] << 8) | bytes[cursor + 1];
      if (length < 2 || cursor + length > bytes.length) break;
      if (const {0xc0, 0xc1, 0xc2}.contains(marker)) {
        if (length < 8 ||
            !dimensions(
              (bytes[cursor + 5] << 8) | bytes[cursor + 6],
              (bytes[cursor + 3] << 8) | bytes[cursor + 4],
            )) {
          break;
        }
        frame = true;
      }
      cursor += length;
      if (marker == 0xda) {
        if (!frame) break;
        scan = true;
        // Walk entropy-coded bytes, preserving stuffed FF bytes and restart
        // markers; the next real marker is checked by the outer loop.
        while (cursor < bytes.length) {
          if (bytes[cursor] != 0xff) {
            cursor++;
            continue;
          }
          if (cursor + 1 >= bytes.length) break;
          final next = bytes[cursor + 1];
          if (next == 0 || (next >= 0xd0 && next <= 0xd7)) {
            cursor += 2;
            continue;
          }
          break;
        }
      }
    }
    throw const ExportException('JPEG 封面损坏或尺寸过大，请重新选择图片。');
  }
  throw const ExportException('封面格式不受支持，仅支持 JPEG 和 PNG。');
}

/// Loads only approved remote artwork sources, checking each redirect and
/// bounding bytes, image format and dimensions for preview and writing alike.
Future<Uint8List> loadRemoteArtwork(String value) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await (() async {
      var uri = Uri.parse(value);
      for (var redirect = 0; redirect < 6; redirect++) {
        final archiveUri =
            uri.scheme == 'https' &&
            !uri.hasPort &&
            uri.userInfo.isEmpty &&
            (uri.host == 'coverartarchive.org' ||
                uri.host == 'archive.org' ||
                uri.host.endsWith('.archive.org'));
        if (!archiveUri && !isNeteaseArtworkUri(uri)) {
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
        await _validateArtworkPixels(result);
        return result;
      }
      throw const ExportException('封面跳转过多，已停止下载。');
    })().timeout(const Duration(seconds: 30));
  } finally {
    client.close(force: true);
  }
}
