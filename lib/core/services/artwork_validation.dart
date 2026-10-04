import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import '../models/audio_track.dart';

/// Validates only a local extracted cache, never changes tag identity or treats
/// a cache problem as evidence that the audio file has no embedded picture.
Future<AudioTrack> validateTrackArtwork(AudioTrack track) async {
  if (!hasText(track.artworkPath)) {
    return track.withArtworkValidation(
      valid: false,
      error:
          track.artworkError ??
          (hasText(track.artworkSha256)
              ? '封面缓存不可用；请重新读取，尚不能确认内嵌封面是否缺失。'
              : null),
    );
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    final file = File(track.artworkPath!);
    final length = await file.length();
    if (length <= 0 || length > 10 * 1024 * 1024) {
      return track.withArtworkValidation(
        valid: false,
        error: '封面缓存为空或过大，无法显示；请重新读取或手动更换封面。',
      );
    }
    final bytes = await file.readAsBytes();
    if (hasText(track.artworkSha256) &&
        sha256.convert(bytes).toString() != track.artworkSha256) {
      return track.withArtworkValidation(
        valid: false,
        error: '封面缓存与读取记录不一致；请重新读取，原文件封面保持不变。',
      );
    }
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width <= 0 ||
        descriptor.height <= 0 ||
        descriptor.width > 8192 ||
        descriptor.height > 8192 ||
        descriptor.width * descriptor.height > 16000000) {
      return track.withArtworkValidation(
        valid: false,
        error: '封面尺寸过大，无法显示；原文件封面保持不变。',
      );
    }
    codec = await descriptor.instantiateCodec(
      targetWidth: 64,
      targetHeight: 64,
    );
    final frame = await codec.getNextFrame();
    frame.image.dispose();
    return track.withArtworkValidation(valid: true);
  } on FileSystemException {
    return track.withArtworkValidation(
      valid: false,
      error: '封面缓存无法读取或已不存在；请重新读取，尚不能确认内嵌封面是否缺失。',
    );
  } catch (_) {
    return track.withArtworkValidation(
      valid: false,
      error: '已读到封面数据，但图片无法解码；请重新读取或手动更换封面。',
    );
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
