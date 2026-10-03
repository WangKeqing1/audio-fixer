import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../models/audio_track.dart';

// Shared with the preserving FLAC writer so a readable alias never looks absent
// during review while the write layer correctly considers it an existing tag.
const standardVorbisFieldKeys = <AudioField, List<String>>{
  AudioField.title: ['TITLE'],
  AudioField.artist: ['ARTIST'],
  AudioField.album: ['ALBUM'],
  AudioField.albumArtist: ['ALBUMARTIST', 'ALBUM_ARTIST', 'ALBUM ARTIST'],
  AudioField.year: ['DATE', 'YEAR'],
  AudioField.genre: ['GENRE'],
  AudioField.trackNumber: ['TRACKNUMBER', 'TRACK', 'ITUNES_CDDB_TRACKNUMBER'],
  AudioField.trackTotal: ['TRACKTOTAL', 'TOTALTRACKS'],
  AudioField.discNumber: ['DISCNUMBER', 'DISC'],
  AudioField.discTotal: ['DISCTOTAL', 'TOTALDISCS'],
  AudioField.composer: ['COMPOSER'],
  AudioField.comment: ['COMMENT', 'DESCRIPTION'],
  AudioField.lyrics: ['LYRICS', 'UNSYNCEDLYRICS'],
};

/// A display/read-back view, never a serialization source for untouched tags.
/// Writers must retain raw unselected frames/atoms, including repeated values.
class StandardAudioTags {
  StandardAudioTags(Map<AudioField, String?> values, List<String> warnings)
    : _values = Map.unmodifiable(values),
      warnings = List.unmodifiable(warnings);

  final Map<AudioField, String?> _values;
  final List<String> warnings;
  String? valueOf(AudioField field) => _values[field];
  String? get title => valueOf(AudioField.title);
  String? get artist => valueOf(AudioField.artist);
  String? get album => valueOf(AudioField.album);
  String? get albumArtist => valueOf(AudioField.albumArtist);
  String? get genre => valueOf(AudioField.genre);
  String? get composer => valueOf(AudioField.composer);
  String? get comment => valueOf(AudioField.comment);
  String? get lyrics => valueOf(AudioField.lyrics);
  int? _number(AudioField field) => int.tryParse(valueOf(field) ?? '');
  int? get year => _number(AudioField.year);
  int? get trackNumber => _number(AudioField.trackNumber);
  int? get trackTotal => _number(AudioField.trackTotal);
  int? get discNumber => _number(AudioField.discNumber);
  int? get discTotal => _number(AudioField.discTotal);
}

StandardAudioTags readStandardAudioTags(File file, {Object? metadata}) {
  final tags = metadata ?? readAllMetadata(file, getImage: false);
  final values = <AudioField, String?>{};
  final warnings = <String>[];
  void text(AudioField field, String? value) => values[field] = _clean(value);
  void number(AudioField field, int? value) {
    values[field] = value != null && value > 0 ? value.toString() : null;
  }

  void many(AudioField field, Iterable<String> entries) {
    final nonempty = entries.map(_clean).whereType<String>().toList();
    values[field] = nonempty.isEmpty ? null : nonempty.join('; ');
    if (nonempty.length > 1) {
      warnings.add('${field.label}含多个值；此处合并显示，未修改时保留原始标签。');
    }
  }

  switch (tags) {
    case Mp3Metadata():
      text(AudioField.title, tags.songName);
      // TPE2 is the album artist/band, not a substitute for TPE1.
      text(AudioField.artist, tags.leadPerformer ?? tags.originalArtist);
      text(AudioField.album, tags.album);
      text(AudioField.albumArtist, tags.bandOrOrchestra);
      number(AudioField.year, tags.year ?? tags.originalReleaseYear);
      if (hasText(tags.contentType) &&
          !RegExp(r'^\(?\d+\)?$').hasMatch(tags.contentType!.trim())) {
        text(AudioField.genre, tags.contentType);
      } else {
        many(AudioField.genre, tags.genres);
      }
      number(
        AudioField.trackNumber,
        tags.trackNumber ?? _legacyTrackNumber(file),
      );
      number(AudioField.trackTotal, tags.trackTotal);
      number(AudioField.discNumber, tags.discNumber);
      number(AudioField.discTotal, tags.totalDics);
      text(AudioField.composer, tags.composer);
      many(
        AudioField.comment,
        tags.comments
            .where((item) => !hasText(item.shortDescription))
            .map((item) => item.text),
      );
      text(AudioField.lyrics, tags.lyric);
      if (!hasText(values[AudioField.lyrics])) {
        final custom = {
          for (final entry in tags.customMetadata.entries)
            entry.key.replaceAll('\x00', '').trim().toUpperCase(): entry.value,
        };
        for (final key in const ['LYRICS', 'UNSYNCEDLYRICS', 'LRC', 'USLT']) {
          if (hasText(custom[key])) {
            text(AudioField.lyrics, custom[key]!.replaceAll('\x00', ''));
            break;
          }
        }
      }
      _readId3Comments(file, values, warnings);
      if (!hasText(values[AudioField.comment])) {
        for (final entry in tags.customMetadata.entries) {
          if (entry.key.replaceAll('\x00', '').trim().toUpperCase() ==
              'COMMENT') {
            text(AudioField.comment, entry.value.replaceAll('\x00', ''));
            break;
          }
        }
      }
    case VorbisMetadata():
      many(AudioField.title, tags.title);
      many(AudioField.artist, tags.artist);
      many(AudioField.album, tags.album);
      many(AudioField.albumArtist, tags.albumArtist);
      number(AudioField.year, tags.date.firstOrNull?.year);
      many(AudioField.genre, tags.genres);
      number(AudioField.trackNumber, tags.trackNumber.firstOrNull);
      number(AudioField.trackTotal, tags.trackTotal);
      number(AudioField.discNumber, tags.discNumber);
      number(AudioField.discTotal, tags.discTotal);
      many(AudioField.composer, tags.composer);
      many(
        AudioField.comment,
        tags.comment.any(hasText) ? tags.comment : tags.description,
      );
      text(AudioField.lyrics, tags.lyric);
      _readFlacAliases(file, values, warnings);
    case Mp4Metadata():
      text(AudioField.title, tags.title);
      text(AudioField.artist, tags.artist);
      text(AudioField.album, tags.album);
      number(AudioField.year, tags.year?.year);
      text(AudioField.genre, tags.genre);
      number(AudioField.trackNumber, tags.trackNumber);
      number(AudioField.trackTotal, tags.totalTracks);
      number(AudioField.discNumber, tags.discNumber);
      number(AudioField.discTotal, tags.totalDiscs);
      text(AudioField.lyrics, tags.lyrics);
      _readItunesExtras(file, values, warnings);
    case RiffMetadata():
      text(AudioField.title, tags.title);
      text(AudioField.artist, tags.artist);
      text(AudioField.album, tags.album);
      number(AudioField.year, tags.year?.year);
      text(AudioField.genre, tags.genre);
      number(AudioField.trackNumber, tags.trackNumber);
      text(AudioField.comment, tags.comment);
    case ApeMetadata():
      text(AudioField.title, tags.title);
      text(AudioField.artist, tags.artist);
      text(AudioField.album, tags.album);
      text(AudioField.albumArtist, tags.albumArtist);
      number(AudioField.year, tags.date?.year);
      many(AudioField.genre, tags.genres);
      number(AudioField.trackNumber, tags.trackNumber);
      number(AudioField.trackTotal, tags.trackTotal);
      number(AudioField.discNumber, tags.discNumber);
      number(AudioField.discTotal, tags.discTotal);
      text(AudioField.composer, tags.composer);
      text(AudioField.comment, tags.comment);
      text(AudioField.lyrics, tags.lyric);
    default:
      throw ArgumentError.value(metadata, 'metadata', 'Unknown metadata model');
  }
  return StandardAudioTags(values, warnings);
}

String? _clean(String? value) {
  if (value == null) return null;
  final cleaned = value.replaceAll(RegExp(r'^\x00+|\x00+$'), '').trim();
  return cleaned.isEmpty ? null : cleaned;
}

const _maxTagBytes = 32 * 1024 * 1024;

int? _legacyTrackNumber(File file) {
  final reader = file.openSync();
  try {
    final length = reader.lengthSync();
    if (length < 128 || latin1.decode(reader.readSync(3)) == 'ID3') return null;
    reader.setPositionSync(length - 128);
    final tag = reader.readSync(128);
    return latin1.decode(tag.sublist(0, 3)) == 'TAG' &&
            tag[125] == 0 &&
            tag[126] > 0
        ? tag[126]
        : null;
  } finally {
    reader.closeSync();
  }
}

int _syncSafe(Uint8List bytes, int offset) {
  if (bytes.sublist(offset, offset + 4).any((value) => value > 127)) {
    throw const FormatException('ID3 长度无效。');
  }
  return (bytes[offset] << 21) |
      (bytes[offset + 1] << 14) |
      (bytes[offset + 2] << 7) |
      bytes[offset + 3];
}

// The dependency retains COMM as opaque bytes and drops duplicate frames.
// Read only bounded COMM payloads; custom descriptions remain distinct tags.
void _readId3Comments(
  File file,
  Map<AudioField, String?> values,
  List<String> warnings,
) {
  final reader = file.openSync();
  try {
    final header = reader.readSync(10);
    if (header.length < 10 || latin1.decode(header.sublist(0, 3)) != 'ID3') {
      return;
    }
    if (!const {3, 4}.contains(header[3]) || header[5] & 0x80 != 0) {
      warnings.add('此 ID3 版本或去同步编码暂不支持完整备注读取。');
      return;
    }
    final size = _syncSafe(header, 6);
    if (size > _maxTagBytes || size + 10 > reader.lengthSync()) {
      throw const FormatException('ID3 标签区过大或不完整。');
    }
    final bytes = reader.readSync(size);
    final data = ByteData.sublistView(bytes);
    var cursor = 0;
    if (header[5] & 0x40 != 0) {
      if (bytes.length < 4) throw const FormatException('ID3 扩展标头不完整。');
      cursor = header[3] == 4 ? _syncSafe(bytes, 0) : data.getUint32(0) + 4;
      if (cursor < 4 || cursor > bytes.length) {
        throw const FormatException('ID3 扩展标头无效。');
      }
    }
    final comments = <String>[];
    var hasDescribedComments = false;
    while (cursor + 10 <= bytes.length) {
      if (bytes[cursor] == 0) break;
      final id = latin1.decode(bytes.sublist(cursor, cursor + 4));
      final count = header[3] == 4
          ? _syncSafe(bytes, cursor + 4)
          : data.getUint32(cursor + 4);
      final end = cursor + 10 + count;
      if (end > bytes.length) throw const FormatException('ID3 frame 不完整。');
      if (id == 'COMM') {
        if (bytes[cursor + 9] != 0) {
          warnings.add('备注使用暂不支持的 ID3 frame 编码，未作推测。');
        } else {
          final content = bytes.sublist(cursor + 10, end);
          if (content.length < 5) throw const FormatException('ID3 备注不完整。');
          final encoding = content[0];
          final step = encoding == 1 || encoding == 2 ? 2 : 1;
          var split = 4;
          while (split + step <= content.length) {
            if (content[split] == 0 && (step == 1 || content[split + 1] == 0)) {
              break;
            }
            split += step;
          }
          if (split + step > content.length) {
            throw const FormatException('ID3 备注描述不完整。');
          }
          final descriptionBytes = content.sublist(4, split);
          final little =
              descriptionBytes.length >= 2 &&
              descriptionBytes[0] == 0xff &&
              descriptionBytes[1] == 0xfe;
          final description = _decodeText(descriptionBytes, encoding);
          final text = _clean(
            _decodeText(
              content.sublist(split + step),
              encoding,
              littleEndian: little,
            ),
          );
          if (description.isEmpty) {
            if (text != null) comments.add(text);
          } else {
            hasDescribedComments = true;
          }
        }
      }
      cursor = end;
    }
    if (comments.isNotEmpty) values[AudioField.comment] = comments.first;
    if (comments.length > 1) {
      warnings.add('存在多条不同语言的备注；显示首条，未修改时保留全部。');
    }
    if (hasDescribedComments) {
      warnings.add('带自定义描述的 ID3 备注作为独立标签保留，不并入普通备注。');
    }
  } on FormatException {
    warnings.add('部分 ID3 备注结构或编码暂不支持，未作推测。');
  } finally {
    reader.closeSync();
  }
}

String _decodeText(Uint8List bytes, int encoding, {bool littleEndian = false}) {
  if (encoding == 0) return latin1.decode(bytes);
  if (encoding == 3) return utf8.decode(bytes);
  if (encoding != 1 && encoding != 2) {
    throw const FormatException('文本编码不支持。');
  }
  var start = 0;
  var endian = littleEndian && encoding == 1 ? Endian.little : Endian.big;
  if (bytes.length >= 2) {
    if (bytes[0] == 0xff && bytes[1] == 0xfe) {
      endian = Endian.little;
      start = 2;
    } else if (bytes[0] == 0xfe && bytes[1] == 0xff) {
      endian = Endian.big;
      start = 2;
    }
  }
  if ((bytes.length - start).isOdd) throw const FormatException('UTF-16 不完整。');
  final data = ByteData.sublistView(bytes);
  return String.fromCharCodes([
    for (var index = start; index < bytes.length; index += 2)
      data.getUint16(index, endian),
  ]);
}

// The dependency omits some common aliases and totals stored as n/m. Read the
// complete bounded comment list so repeated aliases remain visible as warnings.
void _readFlacAliases(
  File file,
  Map<AudioField, String?> values,
  List<String> warnings,
) {
  final reader = file.openSync();
  final entries = <String, List<String>>{};
  try {
    if (latin1.decode(reader.readSync(4)) != 'fLaC') return;
    var last = false;
    var consumed = 0;
    var blocks = 0;
    while (!last) {
      final header = reader.readSync(4);
      if (header.length != 4) throw const FormatException('FLAC 标头不完整。');
      last = header[0] & 0x80 != 0;
      final size = (header[1] << 16) | (header[2] << 8) | header[3];
      consumed += size + 4;
      if (consumed > _maxTagBytes ||
          reader.positionSync() + size > reader.lengthSync()) {
        throw const FormatException('FLAC 标签超出安全读取范围。');
      }
      if (header[0] & 0x7f != 4) {
        reader.setPositionSync(reader.positionSync() + size);
        continue;
      }
      blocks++;
      final bytes = reader.readSync(size);
      if (bytes.length != size || size < 8) {
        throw const FormatException('Vorbis 注释不完整。');
      }
      final data = ByteData.sublistView(bytes);
      var cursor = 4 + data.getUint32(0, Endian.little);
      if (cursor + 4 > size) throw const FormatException('Vorbis vendor 不完整。');
      final count = data.getUint32(cursor, Endian.little);
      cursor += 4;
      for (var index = 0; index < count; index++) {
        if (cursor + 4 > size) throw const FormatException('Vorbis 注释不完整。');
        final length = data.getUint32(cursor, Endian.little);
        cursor += 4;
        if (cursor + length > size) {
          throw const FormatException('Vorbis 注释不完整。');
        }
        final entry = utf8.decode(bytes.sublist(cursor, cursor + length));
        cursor += length;
        final equals = entry.indexOf('=');
        if (equals < 1) continue;
        final key = entry.substring(0, equals).toUpperCase();
        final value = _clean(entry.substring(equals + 1));
        if (value != null) entries.putIfAbsent(key, () => []).add(value);
      }
      if (cursor != size) throw const FormatException('Vorbis 注释包含未知尾部数据。');
    }
    if (blocks > 1) warnings.add('FLAC 含多个注释区；安全写入暂不支持此结构。');
    List<String> candidates(AudioField field) => [
      for (final key in standardVorbisFieldKeys[field]!) ...entries[key] ?? [],
    ];
    void numeric(AudioField field, Iterable<String> raw, {bool year = false}) {
      final usable = <int>[];
      var invalid = false;
      for (final text in raw) {
        final normalized = year
            ? RegExp(r'^(\d{1,4})(?:[-/].*)?$').firstMatch(text)?.group(1)
            : RegExp(r'^\d+$').hasMatch(text.trim())
            ? text.trim()
            : null;
        final value = int.tryParse(normalized ?? '');
        if (value == null || value < 1) {
          invalid = true;
        } else {
          usable.add(value);
        }
      }
      values[field] = usable.firstOrNull?.toString();
      if (invalid) warnings.add('${field.label}含暂不支持的数值格式，未作推测。');
      if (usable.toSet().length > 1) {
        warnings.add('${field.label}的多个标签或别名存在冲突；显示首个值，保存时需重新核对。');
      }
    }

    for (final field in standardVorbisFieldKeys.keys) {
      if (field.isNumeric) continue;
      final found = candidates(field);
      values[field] = found.isEmpty ? null : found.join('; ');
      if (found.length > 1 &&
          !warnings.any(
            (warning) => warning.startsWith('${field.label}含多个值'),
          )) {
        warnings.add('${field.label}含多个值或别名；此处合并显示，未修改时保留原始标签。');
      }
    }
    numeric(AudioField.year, candidates(AudioField.year), year: true);
    for (final (number, total) in const [
      (AudioField.trackNumber, AudioField.trackTotal),
      (AudioField.discNumber, AudioField.discTotal),
    ]) {
      final numbers = <String>[];
      final inferredTotals = <String>[];
      for (final text in candidates(number)) {
        final parts = text.split('/');
        numbers.add(parts.first.trim());
        if (parts.length == 2) {
          inferredTotals.add(parts.last.trim());
        } else if (parts.length > 2) {
          warnings.add('${number.label}含暂不支持的组合格式，未作推测。');
        }
      }
      numeric(number, numbers);
      numeric(total, [...candidates(total), ...inferredTotals]);
    }
  } on FormatException {
    warnings.add('部分 FLAC 标签结构或编码暂不支持，未作推测。');
  } finally {
    reader.closeSync();
  }
}

typedef _Atom = ({String type, int payload, int end});

// Read only the iTunes metadata tree, seeking past media bytes. The dependency
// has no album-artist/composer/comment fields, and its aART atom is ignored.
void _readItunesExtras(
  File file,
  Map<AudioField, String?> values,
  List<String> warnings,
) {
  final reader = file.openSync();
  var visited = 0;
  var readBytes = 0;
  final extras = <AudioField, List<String>>{};
  const fields = {
    'aART': AudioField.albumArtist,
    '©wrt': AudioField.composer,
    '©cmt': AudioField.comment,
  };
  List<_Atom> atoms(int start, int end) {
    final result = <_Atom>[];
    var cursor = start;
    while (cursor < end) {
      if (++visited > 100000 || cursor + 8 > end) {
        throw const FormatException('MP4 标签结构超出安全读取范围。');
      }
      reader.setPositionSync(cursor);
      final header = reader.readSync(8);
      if (header.length != 8) throw const FormatException('MP4 标头不完整。');
      var size = ByteData.sublistView(header).getUint32(0);
      var headerSize = 8;
      if (size == 1) {
        final extended = reader.readSync(8);
        if (extended.length != 8) throw const FormatException('MP4 标头不完整。');
        size = ByteData.sublistView(extended).getUint64(0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - cursor;
      }
      if (size < headerSize || cursor + size > end) {
        throw const FormatException('MP4 atom 长度无效。');
      }
      result.add((
        type: latin1.decode(header.sublist(4)),
        payload: cursor + headerSize,
        end: cursor + size,
      ));
      cursor += size;
    }
    return result;
  }

  void readList(_Atom list) {
    for (final atom in atoms(list.payload, list.end)) {
      final field = fields[atom.type];
      if (field == null) continue;
      for (final child in atoms(atom.payload, atom.end)) {
        if (child.type != 'data') continue;
        final size = child.end - child.payload;
        readBytes += size;
        if (size < 8 || readBytes > _maxTagBytes) {
          throw const FormatException('MP4 data 长度无效。');
        }
        reader.setPositionSync(child.payload);
        final bytes = reader.readSync(size);
        final format = ByteData.sublistView(bytes).getUint32(0);
        if (format != 1 && format != 2) {
          warnings.add('${field.label}使用暂不支持的 MP4 编码，未作推测。');
          continue;
        }
        final value = _clean(
          _decodeText(bytes.sublist(8), format == 1 ? 3 : 2),
        );
        if (value != null) extras.putIfAbsent(field, () => []).add(value);
      }
    }
  }

  void visit(int start, int end, int depth) {
    if (depth > 4) throw const FormatException('MP4 标签嵌套过深。');
    for (final atom in atoms(start, end)) {
      if (atom.type == 'moov' || atom.type == 'udta') {
        visit(atom.payload, atom.end, depth + 1);
      } else if (atom.type == 'meta') {
        if (atom.payload + 4 > atom.end) {
          throw const FormatException('MP4 meta 不完整。');
        }
        reader.setPositionSync(atom.payload);
        if (ByteData.sublistView(reader.readSync(4)).getUint32(0) != 0) {
          warnings.add('此 MP4 元数据版本暂不支持完整扩展标签读取。');
          continue;
        }
        final children = atoms(atom.payload + 4, atom.end);
        if (children.any((child) => child.type == 'keys')) {
          warnings.add('键控 MP4 元数据暂不支持完整扩展标签读取。');
          continue;
        }
        for (final child in children.where((child) => child.type == 'ilst')) {
          readList(child);
        }
      }
    }
  }

  try {
    visit(0, reader.lengthSync(), 0);
    for (final entry in extras.entries) {
      values[entry.key] = entry.value.join('; ');
      if (entry.value.length > 1) {
        warnings.add('${entry.key.label}含多个值；此处合并显示，未修改时保留原始标签。');
      }
    }
  } on FormatException {
    warnings.add('部分 MP4 扩展标签结构或编码暂不支持，未作推测。');
  } finally {
    reader.closeSync();
  }
}
