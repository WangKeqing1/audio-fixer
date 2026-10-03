import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/audio_track.dart';
import '../standard_audio_tags.dart' show standardVorbisFieldKeys;

typedef _FlacBlock = ({int type, Uint8List bytes});

const _fieldKeys = standardVorbisFieldKeys;

const _ordinalFields = {
  AudioField.trackNumber,
  AudioField.trackTotal,
  AudioField.discNumber,
  AudioField.discTotal,
};

Uint8List _uint32(int value, [Endian endian = Endian.big]) =>
    (ByteData(4)..setUint32(0, value, endian)).buffer.asUint8List();

class _Comment {
  _Comment(this.raw);

  factory _Comment.text(String key, String value) =>
      _Comment(Uint8List.fromList(utf8.encode('$key=$value')));

  final Uint8List raw;

  int get _equals => raw.indexOf(61);

  String? get key {
    final equals = _equals;
    if (equals < 1) return null;
    final bytes = raw.sublist(0, equals);
    // Unknown or invalid keys stay opaque and are copied byte for byte.
    if (bytes.any((byte) => byte < 0x20 || byte > 0x7d)) return null;
    return ascii.decode(bytes).toUpperCase();
  }

  String get originalKey => ascii.decode(raw.sublist(0, _equals));
  String get value => utf8.decode(raw.sublist(_equals + 1));
}

void _requireReplace(
  AudioField field,
  String oldValue,
  Set<AudioField> replaceFields,
) {
  if (oldValue.trim().isNotEmpty && !replaceFields.contains(field)) {
    throw const FormatException('FLAC 中已有该项资料，已停止覆盖。');
  }
}

int _ordinal(String value) {
  final trimmed = value.trim();
  final parsed = int.tryParse(trimmed);
  if (!RegExp(r'^\d{1,10}$').hasMatch(trimmed) ||
      parsed == null ||
      parsed > 0xffffffff) {
    throw const FormatException('FLAC 曲目或碟片编号格式不受支持。');
  }
  return parsed;
}

/// Change only the requested half of a number/total pair. A total stored in
/// TRACKNUMBER=2/12 must survive changing the number, and vice versa.
List<_Comment> _replaceOrdinalPair(
  List<_Comment> comments,
  AudioField numberField,
  AudioField totalField,
  Map<AudioField, String> values,
  Set<AudioField> replaceFields,
) {
  final setNumber = values.containsKey(numberField);
  final setTotal = values.containsKey(totalField);
  if (!setNumber && !setTotal) return comments;
  final numberKeys = _fieldKeys[numberField]!;
  final totalKeys = _fieldKeys[totalField]!;
  final retained = <_Comment>[];
  final inferredTotals = <String>[];
  final explicitTotals = <String>[];
  for (final comment in comments) {
    if (numberKeys.contains(comment.key)) {
      final value = comment.value;
      final parts = value.split('/');
      if (parts.length > 2) {
        throw const FormatException('FLAC 曲目或碟片编号格式不受支持。');
      }
      if (parts.length == 2) {
        // Do not guess at malformed combined tags or discard an unknown half.
        _ordinal(parts[0]);
        _ordinal(parts[1]);
        if (setTotal) {
          _requireReplace(totalField, parts[1], replaceFields);
        } else if (setNumber) {
          inferredTotals.add(parts[1].trim());
        }
      }
      if (setNumber) {
        _requireReplace(numberField, parts.first, replaceFields);
      } else if (setTotal && parts.length == 2) {
        retained.add(_Comment.text(comment.originalKey, parts.first.trim()));
      } else {
        retained.add(comment);
      }
    } else if (totalKeys.contains(comment.key)) {
      if (setTotal) {
        _requireReplace(totalField, comment.value, replaceFields);
      } else {
        retained.add(comment);
        if (comment.value.trim().isNotEmpty) {
          explicitTotals.add(comment.value.trim());
        }
      }
    } else {
      retained.add(comment);
    }
  }
  if (setNumber) {
    retained.add(_Comment.text(numberKeys.first, values[numberField]!));
  }
  if (setTotal) {
    retained.add(_Comment.text(totalKeys.first, values[totalField]!));
  } else if (inferredTotals.isNotEmpty) {
    final totals = [...inferredTotals, ...explicitTotals].map(_ordinal).toSet();
    if (totals.length != 1) {
      throw const FormatException('FLAC 总曲目数或总碟片数存在冲突，已停止导出。');
    }
    if (explicitTotals.isEmpty) {
      retained.add(_Comment.text(totalKeys.first, inferredTotals.first));
    }
  }
  return retained;
}

/// Validate the complete picture before using its type to decide what to remove.
int _pictureType(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var cursor = 0;
  int read32() {
    if (cursor + 4 > bytes.length) {
      throw const FormatException('FLAC 封面资料不完整。');
    }
    final result = data.getUint32(cursor);
    cursor += 4;
    return result;
  }

  void skip(int size) {
    if (size > bytes.length - cursor) {
      throw const FormatException('FLAC 封面资料不完整。');
    }
    cursor += size;
  }

  final type = read32();
  skip(read32()); // MIME type
  skip(read32()); // Description
  skip(16); // Width, height, depth and indexed colors
  final imageSize = read32();
  skip(imageSize);
  if (cursor != bytes.length || (type == 3 && imageSize == 0)) {
    throw const FormatException('FLAC 封面资料格式不受支持。');
  }
  return type;
}

Uint8List _rewriteComments(
  Uint8List old,
  Map<AudioField, String> values,
  Set<AudioField> replaceFields,
) {
  final data = ByteData.sublistView(old);
  if (old.length < 8) throw const FormatException('Vorbis 注释不完整。');
  final vendorSize = data.getUint32(0, Endian.little);
  if (vendorSize > old.length - 8) {
    throw const FormatException('Vorbis 注释不完整。');
  }
  final countOffset = 4 + vendorSize;
  final count = data.getUint32(countOffset, Endian.little);
  var comments = <_Comment>[];
  var cursor = countOffset + 4;
  for (var i = 0; i < count; i++) {
    if (cursor + 4 > old.length) throw const FormatException('Vorbis 注释不完整。');
    final length = data.getUint32(cursor, Endian.little);
    cursor += 4;
    if (length > old.length - cursor) {
      throw const FormatException('Vorbis 注释不完整。');
    }
    comments.add(_Comment(old.sublist(cursor, cursor + length)));
    cursor += length;
  }
  if (cursor != old.length) {
    throw const FormatException('Vorbis 注释包含未知尾部数据，已停止导出。');
  }
  for (final entry in values.entries) {
    if (entry.key == AudioField.artwork || _ordinalFields.contains(entry.key)) {
      continue;
    }
    final keys = _fieldKeys[entry.key]!;
    comments = comments.where((comment) {
      if (!keys.contains(comment.key)) return true;
      _requireReplace(entry.key, comment.value, replaceFields);
      return false;
    }).toList();
    comments.add(_Comment.text(keys.first, entry.value));
  }
  comments = _replaceOrdinalPair(
    comments,
    AudioField.trackNumber,
    AudioField.trackTotal,
    values,
    replaceFields,
  );
  comments = _replaceOrdinalPair(
    comments,
    AudioField.discNumber,
    AudioField.discTotal,
    values,
    replaceFields,
  );
  if (values.containsKey(AudioField.artwork)) {
    comments = comments.where((comment) {
      if (comment.key == 'COVERART' && comment.value.trim().isNotEmpty) {
        throw const FormatException('FLAC 旧式封面无法安全区分类型，已停止导出。');
      }
      if (comment.key != 'METADATA_BLOCK_PICTURE') return true;
      final picture = base64.decode(comment.value);
      if (_pictureType(picture) != 3) return true;
      _requireReplace(AudioField.artwork, 'front cover', replaceFields);
      return false;
    }).toList();
  }
  final result = BytesBuilder(copy: false)
    ..add(old.sublist(0, countOffset))
    ..add(_uint32(comments.length, Endian.little));
  for (final comment in comments) {
    result
      ..add(_uint32(comment.raw.length, Endian.little))
      ..add(comment.raw);
  }
  return result.takeBytes();
}

/// Preserve unrelated raw comments, metadata blocks and audio frames. Existing
/// values may be changed only for the explicitly reviewed [replaceFields].
Future<void> addMissingFlacTags(
  File copy,
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? artworkMime, {
  Set<AudioField> replaceFields = const {},
}) async {
  if (values.isEmpty) return;
  for (final field in _ordinalFields) {
    if (values.containsKey(field) && _ordinal(values[field]!) == 0) {
      throw const FormatException('FLAC 曲目或碟片编号必须大于零。');
    }
  }
  final reader = await copy.open();
  final blocks = <_FlacBlock>[];
  late int audioStart;
  try {
    if (String.fromCharCodes(await reader.read(4)) != 'fLaC') {
      throw const FormatException('FLAC 文件标识无效。');
    }
    var last = false;
    var comments = 0;
    var streamInfos = 0;
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
      if (type == 0) streamInfos++;
      blocks.add((type: type, bytes: bytes));
    }
    if (blocks.isEmpty ||
        blocks.first.type != 0 ||
        blocks.first.bytes.length != 34 ||
        streamInfos != 1 ||
        comments > 1) {
      throw const FormatException('无法安全编辑此 FLAC 元数据结构。');
    }
    audioStart = await reader.position();
  } finally {
    await reader.close();
  }

  var commentIndex = blocks.indexWhere((block) => block.type == 4);
  if (commentIndex < 0 && values.keys.any((key) => key != AudioField.artwork)) {
    final vendor = utf8.encode('AudioFixer/0.2.0');
    final empty =
        (BytesBuilder()
              ..add(_uint32(vendor.length, Endian.little))
              ..add(vendor)
              ..add(_uint32(0, Endian.little)))
            .takeBytes();
    commentIndex = blocks.length;
    blocks.add((type: 4, bytes: empty));
  }
  if (commentIndex >= 0) {
    blocks[commentIndex] = (
      type: 4,
      bytes: _rewriteComments(
        blocks[commentIndex].bytes,
        values,
        replaceFields,
      ),
    );
  }
  if (values.containsKey(AudioField.artwork)) {
    if (artwork == null || artwork.isEmpty || artworkMime == null) {
      throw const FormatException('封面未准备好。');
    }
    blocks.removeWhere((block) {
      if (block.type != 6 || _pictureType(block.bytes) != 3) return false;
      _requireReplace(AudioField.artwork, 'front cover', replaceFields);
      return true;
    });
    final mime = ascii.encode(artworkMime);
    final picture = BytesBuilder(copy: false)
      ..add(_uint32(3))
      ..add(_uint32(mime.length))
      ..add(mime)
      ..add(_uint32(0)) // description
      ..add(_uint32(0))
      ..add(_uint32(0)) // dimensions unspecified
      ..add(_uint32(0))
      ..add(_uint32(0)) // depth and indexed colors unspecified
      ..add(_uint32(artwork.length))
      ..add(artwork);
    blocks.add((type: 6, bytes: picture.takeBytes()));
  }
  if (blocks.any((block) => block.bytes.length > 0xffffff)) {
    throw const FormatException('FLAC 标签过大。');
  }
  final staging = File('${copy.path}.tagging');
  try {
    final output = staging.openWrite();
    try {
      output.add(ascii.encode('fLaC'));
      for (var i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        final size = block.bytes.length;
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
