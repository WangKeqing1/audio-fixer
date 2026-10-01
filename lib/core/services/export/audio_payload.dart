import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Fingerprints encoded audio and the container information needed to decode it.
/// Tags/padding may change. FLAC STREAMINFO and MP4 codec, timing and sample
/// tables must remain intact; MP4 chunk pointers may relocate with their mdat.
/// This is a preservation check, not a full decoder/validator for source audio.
/// Unsupported or ambiguous layouts fail closed instead of certifying a copy.
Future<String> audioPayloadDigest(File file, String extension) async {
  final handle = await file.open();
  try {
    final reader = _AudioReader(file, handle, await handle.length());
    return switch (extension.toLowerCase()) {
      'mp3' => await reader.mp3(),
      'flac' => await reader.flac(),
      'm4a' || 'mp4' => await reader.mp4(),
      _ => throw const FormatException('此格式暂不支持安全导出。'),
    };
  } finally {
    await handle.close();
  }
}

class _AudioReader {
  _AudioReader(this.file, this.handle, this.length);
  final File file;
  final RandomAccessFile handle;
  final int length;

  Future<Uint8List> read(int offset, int count) async {
    if (offset < 0 || count < 0 || offset + count > length) {
      throw const FormatException('音频结构不完整。');
    }
    await handle.setPosition(offset);
    final bytes = await handle.read(count);
    if (bytes.length != count) throw const FormatException('音频读取中断。');
    return bytes;
  }

  Future<String> hashRange(int start, int end) async =>
      (await sha256.bind(file.openRead(start, end)).first).toString();

  String digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  String text(List<int> bytes) => String.fromCharCodes(bytes);
  int uint32(Uint8List bytes, [int offset = 0]) =>
      ByteData.sublistView(bytes).getUint32(offset);

  Future<String> mp3() async {
    var start = 0;
    var end = length;
    if (length < 4) throw const FormatException('音频文件过短。');
    if (length >= 10) {
      final header = await read(0, 10);
      if (text(header.sublist(0, 3)) == 'ID3') {
        if (header[3] < 2 ||
            header[3] > 4 ||
            header[4] == 255 ||
            header.sublist(6, 10).any((v) => v > 127)) {
          throw const FormatException('暂不支持此 ID3 标签结构。');
        }
        final allowedFlags = switch (header[3]) {
          2 => 0xc0,
          3 => 0xe0,
          _ => 0xf0,
        };
        if (header[5] & ~allowedFlags != 0) {
          throw const FormatException('ID3 标签标志无效。');
        }
        final size =
            (header[6] << 21) |
            (header[7] << 14) |
            (header[8] << 7) |
            header[9];
        start = 10 + size;
        if (header[3] == 4 && header[5] & 0x10 != 0) {
          final footer = await read(start, 10);
          if (text(footer.sublist(0, 3)) != '3DI' ||
              !List.generate(
                7,
                (i) => footer[i + 3] == header[i + 3],
              ).every((v) => v)) {
            throw const FormatException('ID3 页脚不完整。');
          }
          start += 10;
        }
      }
    }
    if (end >= 128 && text(await read(end - 128, 3)) == 'TAG') end -= 128;
    if (end >= 32) {
      final footer = await read(end - 32, 32);
      if (text(footer.sublist(0, 8)) == 'APETAGEX') {
        final size = ByteData.sublistView(footer).getUint32(12, Endian.little);
        if (size < 32 || size > end - start) {
          throw const FormatException('APE 标签异常。');
        }
        end -= size;
        if (end - start >= 32 && text(await read(end - 32, 8)) == 'APETAGEX') {
          end -= 32;
        }
      }
    }
    if (end <= start) throw const FormatException('未发现音频数据。');
    final sync = await read(start, 2);
    if (sync[0] != 0xff || sync[1] & 0xe0 != 0xe0) {
      throw const FormatException('无法验证 MP3 音频数据。');
    }
    return hashRange(start, end);
  }

  Future<String> flac() async {
    if (text(await read(0, 4)) != 'fLaC') {
      throw const FormatException('FLAC 文件标识无效。');
    }
    var offset = 4;
    String? streamInfo;
    var last = false;
    while (!last) {
      final header = await read(offset, 4);
      final type = header[0] & 0x7f;
      final size = (header[1] << 16) | (header[2] << 8) | header[3];
      last = header[0] & 0x80 != 0;
      final start = offset + 4;
      offset = start + size;
      if (offset > length || type == 127) {
        throw const FormatException('FLAC 标签不完整。');
      }
      if (streamInfo == null && type != 0) {
        throw const FormatException('FLAC 缺少首个 STREAMINFO。');
      }
      if (type == 0) {
        if (streamInfo != null || size != 34) {
          throw const FormatException('FLAC STREAMINFO 无效。');
        }
        streamInfo = await hashRange(start, offset);
      }
    }
    if (streamInfo == null || offset == length) {
      throw const FormatException('未发现音频数据。');
    }
    return digest([
      'flac',
      streamInfo,
      length - offset,
      await hashRange(offset, length),
    ]);
  }

  Future<_Box> box(int start, int limit) async {
    if (start + 8 > limit) throw const FormatException('MP4 box 标头不完整。');
    final header = await read(start, 8);
    var size = uint32(header);
    var headerSize = 8;
    if (size == 1) {
      if (start + 16 > limit) throw const FormatException('MP4 大型 box 标头不完整。');
      size = ByteData.sublistView(await read(start + 8, 8)).getUint64(0);
      headerSize = 16;
    } else if (size == 0) {
      size = limit - start;
    }
    if (size < headerSize || start + size > limit) {
      throw const FormatException('MP4 音频结构不完整。');
    }
    return _Box(text(header.sublist(4)), start + headerSize, start + size);
  }

  Future<List<_Box>> boxes(int start, int end) async {
    final result = <_Box>[];
    var offset = start;
    while (offset < end) {
      final item = await box(offset, end);
      result.add(item);
      offset = item.end;
      if (result.length > 100000) throw const FormatException('MP4 box 数量过多。');
    }
    return result;
  }

  _Box one(List<_Box> children, Set<String> types) {
    final matches = children
        .where((item) => types.contains(item.type))
        .toList();
    if (matches.length != 1) throw const FormatException('MP4 必需结构缺失或重复。');
    return matches.single;
  }

  Future<String> mp4() async {
    final roots = await boxes(0, length);
    if (roots.any(
      (item) => !const {
        'ftyp',
        'moov',
        'mdat',
        'free',
        'skip',
        'wide',
        'meta',
      }.contains(item.type),
    )) {
      throw const FormatException('暂不支持此 MP4 分片或附加结构。');
    }
    final ftyp = one(roots, {'ftyp'});
    final moov = one(roots, {'moov'});
    final media = roots.where((item) => item.type == 'mdat').toList();
    if (media.isEmpty || media.any((item) => item.payload == item.end)) {
      throw const FormatException('未发现音频数据。');
    }
    final movie = await normalize(moov, media);
    final payloads = <Object>[];
    for (final item in media) {
      payloads.add([
        item.end - item.payload,
        await hashRange(item.payload, item.end),
      ]);
    }
    return digest([
      'mp4',
      await hashRange(ftyp.payload, ftyp.end),
      movie,
      payloads,
    ]);
  }

  static const _containers = {
    'moov',
    'trak',
    'mdia',
    'minf',
    'stbl',
    'edts',
    'dinf',
  };
  static const _children = <String, Set<String>>{
    'moov': {'mvhd', 'trak', 'iods', 'udta', 'meta', 'free', 'skip'},
    'trak': {'tkhd', 'mdia', 'edts', 'tref', 'udta', 'meta', 'free', 'skip'},
    'mdia': {'mdhd', 'hdlr', 'minf', 'udta', 'meta', 'free', 'skip'},
    'minf': {'smhd', 'dinf', 'stbl', 'free', 'skip'},
    'dinf': {'dref'},
    'edts': {'elst'},
    'stbl': {
      'stsd',
      'stts',
      'ctts',
      'stsc',
      'stsz',
      'stz2',
      'stco',
      'co64',
      'stss',
      'sdtp',
      'sgpd',
      'sbgp',
      'padb',
      'subs',
      'free',
      'skip',
    },
  };

  Future<String> normalize(
    _Box item,
    List<_Box> media, {
    int dataReferences = 0,
  }) async {
    if (_containers.contains(item.type)) {
      final children = await boxes(item.payload, item.end);
      if (children.any(
        (child) => !_children[item.type]!.contains(child.type),
      )) {
        throw const FormatException('暂不支持此 MP4 解码结构。');
      }
      switch (item.type) {
        case 'moov':
          one(children, {'mvhd'});
          if (!children.any((child) => child.type == 'trak')) {
            throw const FormatException('MP4 没有音轨。');
          }
        case 'trak':
          one(children, {'tkhd'});
          one(children, {'mdia'});
        case 'mdia':
          one(children, {'mdhd'});
          final handler = one(children, {'hdlr'});
          if (handler.end - handler.payload < 12 ||
              text(await read(handler.payload + 8, 4)) != 'soun') {
            throw const FormatException('暂不支持非纯音频 MP4。');
          }
          one(children, {'minf'});
        case 'minf':
          one(children, {'smhd'});
          final dinf = one(children, {'dinf'});
          final references = one(await boxes(dinf.payload, dinf.end), {'dref'});
          dataReferences = await validateReferences(references);
          one(children, {'stbl'});
        case 'dinf':
          one(children, {'dref'});
        case 'stbl':
          one(children, {'stsd'});
          one(children, {'stts'});
          one(children, {'stsc'});
          one(children, {'stsz', 'stz2'});
          one(children, {'stco', 'co64'});
        case 'edts':
          one(children, {'elst'});
      }
      final parts = <String>[];
      for (final child in children) {
        if (const {'udta', 'meta', 'free', 'skip'}.contains(child.type)) {
          continue;
        }
        parts.add(
          await normalize(child, media, dataReferences: dataReferences),
        );
      }
      return digest([item.type, parts]);
    }
    if (item.type == 'stco' || item.type == 'co64') {
      if (item.end - item.payload < 8) {
        throw const FormatException('MP4 块索引不完整。');
      }
      final header = await read(item.payload, 8);
      final count = uint32(header, 4);
      final width = item.type == 'stco' ? 4 : 8;
      if (uint32(header) != 0 ||
          count == 0 ||
          item.end - item.payload != 8 + count * width) {
        throw const FormatException('MP4 块索引无效。');
      }
      // Stream normalized pointers to avoid allocating one object per chunk.
      Stream<List<int>> pointers() async* {
        yield utf8.encode('chunk-offsets:$count;');
        for (var index = 0; index < count; index += 1024) {
          final batch = count - index < 1024 ? count - index : 1024;
          final bytes = await read(
            item.payload + 8 + index * width,
            batch * width,
          );
          final data = ByteData.sublistView(bytes);
          final normalized = StringBuffer();
          for (var pointer = 0; pointer < batch; pointer++) {
            final offset = width == 4
                ? data.getUint32(pointer * width)
                : data.getUint64(pointer * width);
            final mediaIndex = media.indexWhere(
              (data) => offset >= data.payload && offset < data.end,
            );
            if (mediaIndex < 0) {
              throw const FormatException('MP4 块索引指向音频数据之外。');
            }
            normalized.write(
              '$mediaIndex:${offset - media[mediaIndex].payload};',
            );
          }
          yield utf8.encode(normalized.toString());
        }
      }

      return (await sha256.bind(pointers()).first).toString();
    }
    if (item.type == 'dref') await validateReferences(item);
    if (item.type == 'stsd') await validateDescriptions(item, dataReferences);
    return digest([
      item.type,
      item.end - item.payload,
      await hashRange(item.payload, item.end),
    ]);
  }

  Future<int> validateReferences(_Box item) async {
    if (item.end - item.payload < 8) {
      throw const FormatException('MP4 数据引用不完整。');
    }
    final header = await read(item.payload, 8);
    final entries = await boxes(item.payload + 8, item.end);
    if (uint32(header) != 0 ||
        entries.isEmpty ||
        uint32(header, 4) != entries.length) {
      throw const FormatException('MP4 数据引用无效。');
    }
    for (final entry in entries) {
      if (entry.type != 'url ' ||
          entry.end - entry.payload != 4 ||
          uint32(await read(entry.payload, 4)) != 1) {
        throw const FormatException('暂不支持引用外部数据的 MP4。');
      }
    }
    return entries.length;
  }

  Future<void> validateDescriptions(_Box item, int dataReferences) async {
    if (item.end - item.payload < 8) {
      throw const FormatException('MP4 编码信息不完整。');
    }
    final header = await read(item.payload, 8);
    final entries = await boxes(item.payload + 8, item.end);
    if (uint32(header) != 0 ||
        entries.isEmpty ||
        uint32(header, 4) != entries.length) {
      throw const FormatException('MP4 编码信息无效。');
    }
    for (final entry in entries) {
      if (!const {
            'mp4a',
            'alac',
            'fLaC',
            'Opus',
            'ac-3',
            'ec-3',
            'lpcm',
            'sowt',
            'twos',
            'in24',
            'in32',
            'fl32',
            'fl64',
            'ulaw',
            'alaw',
          }.contains(entry.type) ||
          entry.end - entry.payload < 8) {
        throw const FormatException('暂不支持此 MP4 音频编码结构。');
      }
      final reference = ByteData.sublistView(await read(entry.payload + 6, 2))
          .getUint16(0);
      if (reference < 1 || reference > dataReferences) {
        throw const FormatException('MP4 编码引用无效。');
      }
    }
  }
}

class _Box {
  const _Box(this.type, this.payload, this.end);
  final String type;
  final int payload;
  final int end;
}
