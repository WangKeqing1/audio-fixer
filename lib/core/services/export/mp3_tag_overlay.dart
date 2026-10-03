import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../../models/audio_track.dart';

/// Edit only explicitly selected standard frames. Existing values require
/// [replaceFields]; unknown/private frames, other picture types, ID3v1/APEv2
/// tails and MPEG bytes remain exact. Complex ID3 headers fail closed.
Future<void> addMissingMp3Tags(
  File copy,
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? artworkMime, {
  Set<AudioField> replaceFields = const {},
}) async {
  final reader = await copy.open();
  var version = 4;
  var oldSize = 0;
  var skip = 0;
  var framesEnd = 0;
  var removedSize = 0;
  final retainedFrames = <(int, int)>[];
  final selectedIds = values.keys.expand(_fieldIds).toSet();
  final pairs = <String, (String?, String?)>{};
  final pairCounts = <String, int>{};
  final primaryCounts = <String, int>{};
  final logicalText = <AudioField, String>{};
  void recordLogical(AudioField field, String text) {
    final normalized = text.replaceAll('\x00', '').trim();
    if (normalized.isEmpty) return;
    final previous = logicalText[field];
    if (previous != null && previous != normalized) {
      throw FormatException('${field.label}包含相互冲突的标签，无法安全替换。');
    }
    logicalText[field] = normalized;
  }

  void singlePrimary(String id) {
    primaryCounts[id] = (primaryCounts[id] ?? 0) + 1;
    if (primaryCounts[id]! > 1) {
      throw const FormatException('ID3 包含多个语言或重复的歌词/备注，无法安全替换。');
    }
  }

  try {
    final header = await reader.read(10);
    if (header.length >= 3 && String.fromCharCodes(header.take(3)) == 'ID3') {
      if (header.length != 10 ||
          ![3, 4].contains(header[3]) ||
          header[4] != 0 ||
          header[5] != 0 ||
          header.sublist(6).any((v) => v > 127)) {
        throw const FormatException('此 ID3 标签含暂不支持的版本或扩展标记，未生成副本。');
      }
      version = header[3];
      oldSize =
          (header[6] << 21) | (header[7] << 14) | (header[8] << 7) | header[9];
      if (oldSize > await reader.length() - 10) {
        throw const FormatException('ID3 标签不完整。');
      }
      skip = 10;
      framesEnd = 10;
      while (framesEnd < 10 + oldSize) {
        await reader.setPosition(framesEnd);
        final remaining = 10 + oldSize - framesEnd;
        final frame = await reader.read(remaining < 10 ? remaining : 10);
        if (frame.every((byte) => byte == 0)) break;
        if (frame.length != 10 ||
            !frame
                .take(4)
                .every(
                  (byte) =>
                      (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57),
                )) {
          throw const FormatException('ID3 帧结构不受支持，已停止导出。');
        }
        final frameSize = version == 4
            ? (frame[4] << 21) | (frame[5] << 14) | (frame[6] << 7) | frame[7]
            : ByteData.sublistView(frame).getUint32(4);
        if ((version == 4 && frame.sublist(4, 8).any((byte) => byte > 127)) ||
            frameSize < 1 ||
            framesEnd + 10 + frameSize > 10 + oldSize) {
          throw const FormatException('ID3 帧不完整，已停止导出。');
        }
        final id = String.fromCharCodes(frame.take(4));
        var remove = false;
        if (selectedIds.contains(id) ||
            (id == 'TXXX' &&
                (values.containsKey(AudioField.lyrics) ||
                    values.containsKey(AudioField.comment)))) {
          // Never reinterpret compressed, encrypted, grouped or unsynchronised
          // selected frames. Every unrelated raw frame is retained unchanged.
          if (frame[8] != 0 || frame[9] != 0 || frameSize > 16 * 1024 * 1024) {
            throw const FormatException('目标 ID3 标签编码不受支持，已停止导出。');
          }
          final body = await reader.read(frameSize);
          if (id == 'TXXX') {
            final custom = _customText(body);
            if (custom == null) {
              throw const FormatException('自定义 ID3 标签编码不明，已停止导出。');
            }
            final key = custom.$1.toUpperCase().trim();
            if (_lyricKeys.contains(key) &&
                values.containsKey(AudioField.lyrics)) {
              recordLogical(AudioField.lyrics, custom.$2);
              _allowExisting(custom.$2, AudioField.lyrics, replaceFields);
              remove = true;
            } else if (key == 'COMMENT' &&
                values.containsKey(AudioField.comment)) {
              recordLogical(AudioField.comment, custom.$2);
              _allowExisting(custom.$2, AudioField.comment, replaceFields);
              remove = true;
            }
          } else if (id == 'APIC') {
            final type = _pictureType(body);
            if (type == 3) {
              if (!replaceFields.contains(AudioField.artwork)) {
                throw const FormatException('已有内嵌封面，已停止覆盖。');
              }
              remove = true;
            }
          } else if (id == 'COMM') {
            final comment = _describedText(body);
            // Described comments may be replay gain / application data. Only
            // the ordinary empty-description comment is the common field.
            if (comment.$1.replaceAll('\x00', '').trim().isEmpty) {
              singlePrimary('COMM');
              recordLogical(AudioField.comment, comment.$2);
              _allowExisting(comment.$2, AudioField.comment, replaceFields);
              remove = true;
            }
          } else if (id == 'TRCK' || id == 'TPOS') {
            pairCounts[id] = (pairCounts[id] ?? 0) + 1;
            if (pairCounts[id] != 1) {
              throw const FormatException('ID3 编号标签重复，已停止导出。');
            }
            final pair = _numberPair(_decodeText(body));
            final number = id == 'TRCK'
                ? AudioField.trackNumber
                : AudioField.discNumber;
            final total = id == 'TRCK'
                ? AudioField.trackTotal
                : AudioField.discTotal;
            if (values.containsKey(number)) {
              _allowExisting(pair.$1, number, replaceFields);
            }
            if (values.containsKey(total)) {
              _allowExisting(pair.$2, total, replaceFields);
            }
            pairs[id] = pair;
            remove = true;
          } else {
            final field = values.keys.firstWhere(
              (field) => _fieldIds(field).contains(id),
            );
            late String text;
            if (id == 'USLT') {
              final lyrics = _describedText(body);
              if (lyrics.$1.replaceAll('\x00', '').trim().isNotEmpty) {
                throw const FormatException('ID3 歌词含独立描述或翻译版本，无法安全替换。');
              }
              singlePrimary('USLT');
              text = lyrics.$2;
              recordLogical(AudioField.lyrics, text);
            } else {
              text = _decodeText(body);
            }
            _allowExisting(text, field, replaceFields);
            remove = true;
          }
        }
        if (remove) {
          removedSize += 10 + frameSize;
        } else {
          retainedFrames.add((framesEnd, framesEnd + 10 + frameSize));
        }
        framesEnd += 10 + frameSize;
      }
    }
  } finally {
    await reader.close();
  }

  Uint8List encoded(String text) {
    if (version == 4) return Uint8List.fromList(utf8.encode(text));
    final result = ByteData(2 + text.codeUnits.length * 2)
      ..setUint16(0, 0xfeff, Endian.little);
    for (var i = 0; i < text.codeUnits.length; i++) {
      result.setUint16(2 + i * 2, text.codeUnits[i], Endian.little);
    }
    return result.buffer.asUint8List();
  }

  final frames = BytesBuilder(copy: false);
  final encoding = version == 4 ? 3 : 1;
  final terminator = version == 4 ? <int>[0] : <int>[0xff, 0xfe, 0, 0];
  void addFrame(String id, BytesBuilder body) {
    final length = body.length;
    final header = ByteData(10);
    for (var index = 0; index < 4; index++) {
      header.setUint8(index, id.codeUnitAt(index));
    }
    if (version == 4) {
      for (var index = 0; index < 4; index++) {
        header.setUint8(4 + index, (length >> ((3 - index) * 7)) & 127);
      }
    } else {
      header.setUint32(4, length);
    }
    frames
      ..add(header.buffer.asUint8List())
      ..add(body.takeBytes());
  }

  if (skip == 0) {
    final original = readAllMetadata(copy);
    if (original is Mp3Metadata) {
      final legacyValues = <AudioField, String?>{
        AudioField.title: original.songName,
        AudioField.artist: original.leadPerformer,
        AudioField.album: original.album,
        AudioField.year: original.year?.toString(),
        AudioField.genre: original.genres.isEmpty
            ? null
            : original.genres.join('/'),
        AudioField.trackNumber: legacyMp3TrackNumber(copy)?.toString(),
        AudioField.comment: original.comments
            .map((comment) => comment.text)
            .join('\n'),
      };
      for (final field in values.keys) {
        _allowExisting(legacyValues[field], field, replaceFields);
      }
      final textFrames = <String, String?>{
        'TIT2': values.containsKey(AudioField.title) ? null : original.songName,
        'TPE1': values.containsKey(AudioField.artist)
            ? null
            : original.leadPerformer,
        'TALB': values.containsKey(AudioField.album) ? null : original.album,
        'TYER': values.containsKey(AudioField.year)
            ? null
            : original.year?.toString(),
        'TRCK':
            values.containsKey(AudioField.trackNumber) ||
                values.containsKey(AudioField.trackTotal)
            ? null
            : legacyMp3TrackNumber(copy)?.toString(),
        'TCON': values.containsKey(AudioField.genre) || original.genres.isEmpty
            ? null
            : original.genres.join('/'),
      };
      for (final entry in textFrames.entries) {
        if (hasText(entry.value)) {
          addFrame(
            entry.key,
            BytesBuilder(copy: false)
              ..addByte(encoding)
              ..add(encoded(entry.value!)),
          );
        }
      }
      if (values.containsKey(AudioField.trackNumber) ||
          values.containsKey(AudioField.trackTotal)) {
        pairs['TRCK'] = (legacyMp3TrackNumber(copy)?.toString(), null);
      }
      for (final comment in original.comments) {
        if (!values.containsKey(AudioField.comment) && hasText(comment.text)) {
          addFrame(
            'COMM',
            BytesBuilder(copy: false)
              ..addByte(encoding)
              ..add(ascii.encode('und'))
              ..add(terminator)
              ..add(encoded(comment.text)),
          );
        }
      }
    }
  }
  final writtenPairs = <String>{};
  for (final entry in values.entries) {
    var value = entry.value;
    final id = entry.key == AudioField.year
        ? (version == 4 ? 'TDRC' : 'TYER')
        : _fieldIds(entry.key).first;
    if (id == 'TRCK' || id == 'TPOS') {
      if (!writtenPairs.add(id)) continue;
      final number = id == 'TRCK'
          ? AudioField.trackNumber
          : AudioField.discNumber;
      final total = id == 'TRCK' ? AudioField.trackTotal : AudioField.discTotal;
      final old = pairs[id];
      final nextNumber = values[number] ?? old?.$1;
      final nextTotal = values[total] ?? old?.$2;
      value = nextTotal == null
          ? (nextNumber ?? '0')
          : '${nextNumber ?? '0'}/$nextTotal';
    }
    final body = BytesBuilder(copy: false)..addByte(encoding);
    switch (entry.key) {
      case AudioField.lyrics:
      case AudioField.comment:
        body
          ..add(ascii.encode('und'))
          ..add(terminator)
          ..add(encoded(value));
      case AudioField.artwork:
        if (artwork == null || artworkMime == null) {
          throw const FormatException('封面未准备好。');
        }
        body
          ..add(ascii.encode(artworkMime))
          ..addByte(0)
          ..addByte(3)
          ..add(terminator)
          ..add(artwork);
      default:
        body.add(encoded(value));
    }
    addFrame(id, body);
  }
  final tagSize = oldSize - removedSize + frames.length;
  if (tagSize > 0x0fffffff) throw const FormatException('ID3 标签过大。');
  final header = <int>[
    0x49,
    0x44,
    0x33,
    version,
    0,
    0,
    (tagSize >> 21) & 127,
    (tagSize >> 14) & 127,
    (tagSize >> 7) & 127,
    tagSize & 127,
  ];
  final staging = File('${copy.path}.tagging');
  try {
    final output = staging.openWrite();
    try {
      output.add(header);
      for (final (start, end) in retainedFrames) {
        await output.addStream(copy.openRead(start, end));
      }
      output.add(frames.takeBytes());
      await output.addStream(copy.openRead(skip == 0 ? 0 : framesEnd));
      await output.flush();
    } finally {
      await output.close();
    }
    await staging.rename(copy.path);
  } finally {
    if (await staging.exists()) await staging.delete();
  }
}

/// The dependency does not expose ID3v1.1 track numbers; retain this byte when
/// introducing ID3v2 so players that prefer v2 do not lose the legacy value.
int? legacyMp3TrackNumber(File file) {
  final reader = file.openSync();
  try {
    if (reader.lengthSync() < 128) return null;
    if (String.fromCharCodes(reader.readSync(3)) == 'ID3') return null;
    reader.setPositionSync(reader.lengthSync() - 128);
    final tag = reader.readSync(128);
    if (String.fromCharCodes(tag.take(3)) == 'TAG' &&
        tag[125] == 0 &&
        tag[126] > 0) {
      return tag[126];
    }
    return null;
  } finally {
    reader.closeSync();
  }
}

Iterable<String> _fieldIds(AudioField field) => switch (field) {
  AudioField.title => const ['TIT2'],
  AudioField.artist => const ['TPE1'],
  AudioField.album => const ['TALB'],
  AudioField.albumArtist => const ['TPE2'],
  AudioField.year => const ['TDRC', 'TYER', 'TRDA'],
  AudioField.genre => const ['TCON'],
  AudioField.trackNumber || AudioField.trackTotal => const ['TRCK'],
  AudioField.discNumber || AudioField.discTotal => const ['TPOS'],
  AudioField.composer => const ['TCOM'],
  AudioField.comment => const ['COMM'],
  AudioField.lyrics => const ['USLT'],
  AudioField.artwork => const ['APIC'],
};

void _allowExisting(
  String? text,
  AudioField field,
  Set<AudioField> replaceFields,
) {
  if (hasText(text?.replaceAll('\x00', '')) && !replaceFields.contains(field)) {
    throw FormatException('${field.label}已存在，未允许覆盖。');
  }
}

String _decodeText(Uint8List bytes) {
  if (bytes.isEmpty || bytes[0] > 3) {
    throw const FormatException('ID3 文字编码不受支持。');
  }
  return _decodeEncoded(
    bytes.sublist(1),
    bytes[0],
  ).replaceAll('\x00', '').trim();
}

String _decodeEncoded(Uint8List content, int encoding, {Endian? inherited}) {
  if (encoding == 0) return latin1.decode(content);
  if (encoding == 3) return utf8.decode(content);
  var endian = inherited ?? Endian.big;
  if (encoding == 1 && content.isNotEmpty) {
    if (content.length >= 2 && content[0] == 0xff && content[1] == 0xfe) {
      endian = Endian.little;
      content = content.sublist(2);
    } else if (content.length >= 2 &&
        content[0] == 0xfe &&
        content[1] == 0xff) {
      endian = Endian.big;
      content = content.sublist(2);
    } else if (inherited == null) {
      throw const FormatException('ID3 UTF-16 字节序不明。');
    }
  }
  if (content.length.isOdd) throw const FormatException('ID3 字符串不完整。');
  final data = ByteData.sublistView(content);
  return String.fromCharCodes([
    for (var i = 0; i < content.length; i += 2) data.getUint16(i, endian),
  ]);
}

(String, String) _describedText(Uint8List bytes) {
  if (bytes.length < 5 || bytes[0] > 3) {
    throw const FormatException('ID3 注释或歌词不完整。');
  }
  final encoding = bytes[0];
  final end = _terminatorEnd(bytes, 4, encoding);
  final step = encoding == 1 || encoding == 2 ? 2 : 1;
  final description = bytes.sublist(4, end - step);
  final endian = encoding == 1 && description.length >= 2
      ? (description[0] == 0xff && description[1] == 0xfe
            ? Endian.little
            : Endian.big)
      : null;
  return (
    _decodeEncoded(description, encoding),
    _decodeEncoded(bytes.sublist(end), encoding, inherited: endian),
  );
}

int _terminatorEnd(Uint8List bytes, int start, int encoding) {
  final step = encoding == 1 || encoding == 2 ? 2 : 1;
  for (var end = start; end + step <= bytes.length; end += step) {
    if (bytes[end] == 0 && (step == 1 || bytes[end + 1] == 0)) {
      return end + step;
    }
  }
  throw const FormatException('ID3 字符串未结束。');
}

int _pictureType(Uint8List bytes) {
  if (bytes.length < 5 || bytes[0] > 3) {
    throw const FormatException('ID3 封面结构不完整。');
  }
  final mimeEnd = bytes.indexOf(0, 1);
  if (mimeEnd < 2 || mimeEnd + 1 >= bytes.length) {
    throw const FormatException('ID3 封面类型不明。');
  }
  final imageStart = _terminatorEnd(bytes, mimeEnd + 2, bytes[0]);
  if (imageStart >= bytes.length) throw const FormatException('ID3 封面内容为空。');
  return bytes[mimeEnd + 1];
}

(String?, String?) _numberPair(String value) {
  if (!hasText(value)) return (null, null);
  if (!RegExp(r'^\d+(?:/\d+)?$').hasMatch(value)) {
    throw const FormatException('ID3 编号格式不受支持。');
  }
  final parts = value.split('/');
  final number = int.parse(parts.first);
  final total = parts.length == 2 ? int.parse(parts.last) : null;
  return (
    number > 0 ? number.toString() : null,
    total != null && total > 0 ? total.toString() : null,
  );
}

const _lyricKeys = {
  'LYRICS',
  'UNSYNCEDLYRICS',
  'UNSYNCED LYRICS',
  'LRC',
  'USLT',
};

String? customMp3Lyrics(File file) {
  final metadata = readAllMetadata(file, getImage: false);
  if (metadata is! Mp3Metadata) return null;
  for (final entry in metadata.customMetadata.entries) {
    if (_lyricKeys.contains(entry.key.toUpperCase().trim())) {
      final text = entry.value.replaceAll('\x00', '').trim();
      if (text.isNotEmpty) return text;
    }
  }
  return null;
}

(String, String)? _customText(Uint8List bytes) {
  if (bytes.isEmpty || bytes[0] > 3) return null;
  final encoding = bytes[0];
  var end = 1;
  final step = encoding == 1 || encoding == 2 ? 2 : 1;
  while (end + step <= bytes.length) {
    if (bytes[end] == 0 && (step == 1 || bytes[end + 1] == 0)) break;
    end += step;
  }
  if (end + step > bytes.length) return null;
  final little = bytes.length >= 3 && bytes[1] == 0xff && bytes[2] == 0xfe;
  String decode(Uint8List value) {
    if (encoding == 0) return latin1.decode(value);
    if (encoding == 3) return utf8.decode(value);
    var endian = little ? Endian.little : Endian.big;
    if (value.length >= 2 &&
        ((value[0] == 0xff && value[1] == 0xfe) ||
            (value[0] == 0xfe && value[1] == 0xff))) {
      endian = value[0] == 0xff ? Endian.little : Endian.big;
      value = value.sublist(2);
    }
    if (value.length.isOdd) throw const FormatException('ID3 字符串不完整。');
    final data = ByteData.sublistView(value);
    return String.fromCharCodes([
      for (var i = 0; i < value.length; i += 2) data.getUint16(i, endian),
    ]);
  }

  try {
    return (decode(bytes.sublist(1, end)), decode(bytes.sublist(end + step)));
  } on FormatException {
    return null;
  }
}
