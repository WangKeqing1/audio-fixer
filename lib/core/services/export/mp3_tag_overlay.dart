import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../../models/audio_track.dart';

/// Add only missing fields; leave all original frames, unknown/private tags,
/// ID3v1/APEv2 tails and MPEG bytes exactly as they were. Complex ID3 headers
/// fail closed instead of rewriting structures this adapter does not support.
Future<void> addMissingMp3Tags(
  File copy,
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? artworkMime,
) async {
  final reader = await copy.open();
  var version = 4;
  var oldSize = 0;
  var skip = 0;
  var framesEnd = 0;
  var removedSize = 0;
  final retainedFrames = <(int, int)>[];
  final selectedIds = values.keys
      .map(
        (field) => switch (field) {
          AudioField.title => 'TIT2',
          AudioField.artist => 'TPE1',
          AudioField.album => 'TALB',
          AudioField.lyrics => 'USLT',
          AudioField.artwork => 'APIC',
        },
      )
      .toSet();
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
        var blankCustomLyrics = false;
        if (id == 'TXXX' && values.containsKey(AudioField.lyrics)) {
          if (frame[8] != 0 || frame[9] != 0 || frameSize > 1024 * 1024) {
            throw const FormatException('自定义 ID3 标签编码不明，已停止导出。');
          }
          final custom = _customText(await reader.read(frameSize));
          if (custom != null &&
              _lyricKeys.contains(custom.$1.toUpperCase().trim())) {
            if (custom.$2.replaceAll('\x00', '').trim().isNotEmpty) {
              throw const FormatException('已有自定义内嵌歌词，已停止覆盖。');
            }
            blankCustomLyrics = true;
          }
          await reader.setPosition(framesEnd + 10);
        }
        if (blankCustomLyrics) {
          removedSize += 10 + frameSize;
        } else if (selectedIds.contains(id)) {
          if (frame[8] != 0 ||
              frame[9] != 0 ||
              frameSize > 1024 * 1024 ||
              !_blankFrame(id, await reader.read(frameSize))) {
            throw const FormatException('ID3 中已有该项资料或编码不明，已停止覆盖。');
          }
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
      final textFrames = <String, String?>{
        'TIT2': values.containsKey(AudioField.title) ? null : original.songName,
        'TPE1': values.containsKey(AudioField.artist)
            ? null
            : original.leadPerformer,
        'TALB': values.containsKey(AudioField.album) ? null : original.album,
        'TYER': original.year?.toString(),
        'TRCK': legacyMp3TrackNumber(copy)?.toString(),
        'TCON': original.genres.isEmpty ? null : original.genres.join('/'),
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
      for (final comment in original.comments) {
        if (hasText(comment.text)) {
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
  for (final entry in values.entries) {
    final id = switch (entry.key) {
      AudioField.title => 'TIT2',
      AudioField.artist => 'TPE1',
      AudioField.album => 'TALB',
      AudioField.lyrics => 'USLT',
      AudioField.artwork => 'APIC',
    };
    final body = BytesBuilder(copy: false)..addByte(encoding);
    switch (entry.key) {
      case AudioField.lyrics:
        body
          ..add(ascii.encode('und'))
          ..add(terminator)
          ..add(encoded(entry.value));
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
        body.add(encoded(entry.value));
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

bool _blankFrame(String id, Uint8List bytes) {
  if (id == 'APIC' || bytes.isEmpty || bytes[0] > 3) return false;
  final encoding = bytes[0];
  var start = 1;
  if (id == 'USLT') {
    if (bytes.length < 5) return false;
    start = 4;
    if (encoding == 0 || encoding == 3) {
      final end = bytes.indexOf(0, start);
      if (end < 0) return false;
      start = end + 1;
    } else {
      while (start + 1 < bytes.length &&
          !(bytes[start] == 0 && bytes[start + 1] == 0)) {
        start += 2;
      }
      if (start + 1 >= bytes.length) return false;
      start += 2;
    }
  }
  try {
    var content = bytes.sublist(start);
    String text;
    if (encoding == 0) {
      text = latin1.decode(content);
    } else if (encoding == 3) {
      text = utf8.decode(content);
    } else {
      var endian = Endian.big;
      if (encoding == 1) {
        if (content.length < 2) return content.isEmpty;
        if (content[0] == 0xff && content[1] == 0xfe) {
          endian = Endian.little;
        } else if (!(content[0] == 0xfe && content[1] == 0xff)) {
          return false;
        }
        content = content.sublist(2);
      }
      if (content.length.isOdd) return false;
      final data = ByteData.sublistView(content);
      text = String.fromCharCodes([
        for (var i = 0; i < content.length; i += 2) data.getUint16(i, endian),
      ]);
    }
    return text.replaceAll('\x00', '').trim().isEmpty;
  } on FormatException {
    return false;
  }
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
