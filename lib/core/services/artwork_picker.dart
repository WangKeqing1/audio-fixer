import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../storage/library_store.dart';

const maximumArtworkBytes = 10 * 1024 * 1024;

class ArtworkException implements Exception {
  const ArtworkException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class ArtworkPicker {
  Future<String?> pickArtwork();
}

/// The document picker grants access only to the explicitly chosen image.
class SystemArtworkPicker implements ArtworkPicker {
  SystemArtworkPicker(this.store, {this.chooseFile = _choose});
  final LocalArtworkStore store;
  final Future<PlatformFile?> Function() chooseFile;
  static Future<PlatformFile?> _choose() => FilePicker.pickFile(
    dialogTitle: '选择 JPEG 或 PNG 封面',
    type: FileType.custom,
    allowedExtensions: const ['jpg', 'jpeg', 'png'],
  );

  @override
  Future<String?> pickArtwork() async {
    final file = await chooseFile();
    if (file == null) return null;
    if (!const {'file', 'content'}.contains(file.uri.scheme)) {
      throw const ArtworkException('请选择本机 JPEG 或 PNG 图片。');
    }
    final size = file.lengthSync();
    if (size != null && size > maximumArtworkBytes) {
      throw const ArtworkException('封面不能超过 10 MiB。');
    }
    return store.importArtwork(file.readAsByteStream());
  }
}

/// Content-addressed, immutable review assets. Never reads arbitrary file URIs
/// and never edits or removes the user's original selected image.
class LocalArtworkStore {
  LocalArtworkStore(this.directoryProvider);
  final DirectoryProvider directoryProvider;

  Future<Directory> _ownedDirectory() async {
    final support = await directoryProvider();
    await support.create(recursive: true);
    final supportPath = await support.resolveSymbolicLinks();
    final directory = Directory(p.join(supportPath, 'manual_artwork'));
    await directory.create();
    final ownedPath = await directory.resolveSymbolicLinks();
    if (!p.isWithin(supportPath, ownedPath)) {
      throw const ArtworkException('封面存储位置异常，未写入。');
    }
    return Directory(ownedPath);
  }

  Future<String> importArtwork(Stream<List<int>> stream) async {
    final bytes = await _readBounded(stream);
    final extension = await _validateImage(bytes);
    final digest = sha256.convert(bytes).toString();
    final directory = await _ownedDirectory();
    final target = File(p.join(directory.path, '$digest.$extension'));
    final existingType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (existingType != FileSystemEntityType.notFound) {
      if (existingType != FileSystemEntityType.file ||
          sha256.convert(await _readBounded(target.openRead())).toString() !=
              digest) {
        throw const ArtworkException('已有封面副本校验失败，请重新选择图片。');
      }
      return target.uri.toString();
    }
    final staging = await directory.createTemp('import-');
    try {
      final temporary = File(p.join(staging.path, 'image'));
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
      return target.uri.toString();
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<Uint8List> read(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'file' ||
        uri.host.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ArtworkException('所选封面位置无效，请重新选择。');
    }
    final directory = await _ownedDirectory();
    final path = uri.toFilePath();
    final file = File(path);
    final match = RegExp(r'^([a-f0-9]{64})\.(jpg|png)$')
        .firstMatch(p.basename(path));
    if (match == null ||
        p.dirname(path) != directory.path ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != path) {
      throw const ArtworkException('封面必须是本应用保存的已选择图片，请重新选择。');
    }
    final bytes = await _readBounded(file.openRead());
    if (sha256.convert(bytes).toString() != match.group(1)) {
      throw const ArtworkException('所选封面已变化，请重新选择后确认。');
    }
    final extension = await _validateImage(bytes);
    if (extension != match.group(2)) {
      throw const ArtworkException('封面格式校验失败，请重新选择。');
    }
    return bytes;
  }
}

Future<Uint8List> _readBounded(Stream<List<int>> stream) async {
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (buffer.length + chunk.length > maximumArtworkBytes) {
      throw const ArtworkException('封面不能超过 10 MiB。');
    }
    buffer.add(chunk);
  }
  if (buffer.isEmpty) throw const ArtworkException('所选图片为空。');
  return buffer.takeBytes();
}

Future<String> _validateImage(Uint8List bytes) async {
  final png =
      bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47;
  final jpeg =
      bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff;
  if (!png && !jpeg) throw const ArtworkException('封面仅支持 JPEG 和 PNG 图片。');
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
      throw const ArtworkException('封面尺寸过大，请选择不超过 1600 万像素的图片。');
    }
    codec = await descriptor.instantiateCodec(
      targetWidth: 64,
      targetHeight: 64,
    );
    final frame = await codec.getNextFrame();
    frame.image.dispose();
  } on ArtworkException {
    rethrow;
  } catch (_) {
    throw const ArtworkException('图片无法解码，请选择完整的 JPEG 或 PNG 图片。');
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
  return png ? 'png' : 'jpg';
}
