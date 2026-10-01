import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/audio_track.dart';

typedef _FlacBlock = ({int type, Uint8List bytes});

/// Preserve every existing metadata entry/block and frame; append only reviewed
/// fields to the original Vorbis comment block and add a cover when requested.
Future<void> addMissingFlacTags(
  File copy,
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? artworkMime,
) async {
  final reader = await copy.open();
  final blocks = <_FlacBlock>[];
  late int audioStart;
  try {
    if (String.fromCharCodes(await reader.read(4)) != 'fLaC') {
      throw const FormatException('FLAC 文件标识无效。');
    }
    var last = false;
    var comments = 0;
    while (!last) {
      final header = await reader.read(4);
      if (header.length != 4) throw const FormatException('FLAC 标签不完整。');
      last = header[0] & 0x80 != 0;
      final type = header[0] & 0x7f;
      final size = (header[1] << 16) | (header[2] << 8) | header[3];
      final bytes = await reader.read(size);
      if (bytes.length != size || type == 127) {
        throw const FormatException('FLAC 标签不完整。');
      }
      if (type == 4) comments++;
      blocks.add((type: type, bytes: bytes));
    }
    if (blocks.isEmpty || blocks.first.type != 0 || comments > 1) {
      throw const FormatException('无法安全编辑此 FLAC 元数据结构。');
    }
    audioStart = await reader.position();
  } finally {
    await reader.close();
  }

  Uint8List uint32(int value, [Endian endian = Endian.big]) =>
      (ByteData(4)..setUint32(0, value, endian)).buffer.asUint8List();
  final fields = values.entries
      .where((entry) => entry.key != AudioField.artwork)
      .toList();
  if (fields.isNotEmpty) {
    var index = blocks.indexWhere((block) => block.type == 4);
    Uint8List old;
    if (index < 0) {
      final vendor = utf8.encode('AudioFixer/0.2.0');
      old =
          (BytesBuilder()
                ..add(uint32(vendor.length, Endian.little))
                ..add(vendor)
                ..add(uint32(0, Endian.little)))
              .takeBytes();
      index = blocks.length;
      blocks.add((type: 4, bytes: old));
    } else {
      old = blocks[index].bytes;
    }
    final data = ByteData.sublistView(old);
    if (old.length < 8) throw const FormatException('Vorbis 注释不完整。');
    final vendorSize = data.getUint32(0, Endian.little);
    if (vendorSize > old.length - 8) {
      throw const FormatException('Vorbis 注释不完整。');
    }
    final countOffset = 4 + vendorSize;
    final count = data.getUint32(countOffset, Endian.little);
    final selectedKeys = fields
        .map(
          (entry) => switch (entry.key) {
            AudioField.title => 'TITLE',
            AudioField.artist => 'ARTIST',
            AudioField.album => 'ALBUM',
            AudioField.lyrics => 'LYRICS',
            AudioField.artwork => 'METADATA_BLOCK_PICTURE',
          },
        )
        .toSet();
    final retained = <Uint8List>[];
    var cursor = countOffset + 4;
    for (var i = 0; i < count; i++) {
      if (cursor + 4 > old.length) throw const FormatException('Vorbis 注释不完整。');
      final start = cursor;
      final length = data.getUint32(cursor, Endian.little);
      cursor += 4 + length;
      if (cursor > old.length) throw const FormatException('Vorbis 注释不完整。');
      final raw = old.sublist(start + 4, cursor);
      final equals = raw.indexOf(61);
      if (equals >= 0 &&
          selectedKeys.contains(
            ascii
                .decode(raw.sublist(0, equals), allowInvalid: true)
                .toUpperCase(),
          )) {
        if (utf8.decode(raw.sublist(equals + 1)).trim().isNotEmpty) {
          throw const FormatException('FLAC 中已有该项资料，已停止覆盖。');
        }
        // Empty fields are replaceable, all other raw comments are retained.
        continue;
      }
      retained.add(old.sublist(start, cursor));
    }
    if (cursor != old.length) {
      throw const FormatException('Vorbis 注释包含未知尾部数据，已停止导出。');
    }
    final result = BytesBuilder(copy: false)
      ..add(old.sublist(0, countOffset))
      ..add(uint32(retained.length + fields.length, Endian.little));
    for (final raw in retained) {
      result.add(raw);
    }
    for (final field in fields) {
      final key = switch (field.key) {
        AudioField.title => 'TITLE',
        AudioField.artist => 'ARTIST',
        AudioField.album => 'ALBUM',
        AudioField.lyrics => 'LYRICS',
        AudioField.artwork => throw StateError(
          'Artwork is a separate FLAC block',
        ),
      };
      final entry = utf8.encode('$key=${field.value}');
      result
        ..add(uint32(entry.length, Endian.little))
        ..add(entry);
    }
    blocks[index] = (type: 4, bytes: result.takeBytes());
  }
  if (values.containsKey(AudioField.artwork)) {
    if (artwork == null || artworkMime == null) {
      throw const FormatException('封面未准备好。');
    }
    final mime = ascii.encode(artworkMime);
    final picture = BytesBuilder(copy: false)
      ..add(uint32(3))
      ..add(uint32(mime.length))
      ..add(mime)
      ..add(uint32(0)) // description
      ..add(uint32(0))
      ..add(uint32(0)) // dimensions unspecified
      ..add(uint32(0))
      ..add(uint32(0)) // depth and indexed colors unspecified
      ..add(uint32(artwork.length))
      ..add(artwork);
    blocks.add((type: 6, bytes: picture.takeBytes()));
  }
  final staging = File('${copy.path}.tagging');
  try {
    final output = staging.openWrite();
    try {
      output.add(ascii.encode('fLaC'));
      for (var i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        final size = block.bytes.length;
        if (size > 0xffffff) throw const FormatException('FLAC 标签过大。');
        output.add([
          block.type | (i == blocks.length - 1 ? 0x80 : 0),
          (size >> 16) & 255,
          (size >> 8) & 255,
          size & 255,
        ]);
        output.add(block.bytes);
      }
      await output.addStream(copy.openRead(audioStart));
      await output.flush();
    } finally {
      await output.close();
    }
    await staging.rename(copy.path);
  } finally {
    if (await staging.exists()) await staging.delete();
  }
}
