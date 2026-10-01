import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/audio_track.dart';

/// Appends only absent iTunes tag atoms, retaining every existing ilst child.
/// The rebuilt moov is appended at EOF; the old moov becomes same-sized free
/// padding. Existing media never moves, so stco/co64 offsets remain exact.
/// This trades a larger, potentially non-fast-start copy for safer preservation.
Future<void> addMissingMp4Tags(
  File copy,
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? artworkMime,
) async {
  if (values.isEmpty) throw const FormatException('请至少选择一项资料。');
  final reader = await copy.open();
  late Uint8List movie;
  late int movieStart;
  final patches = <(int, List<int>)>[];
  try {
    final length = await reader.length();
    var offset = 0;
    var movieCount = 0;
    var mediaCount = 0;
    while (offset < length) {
      if (offset + 8 > length) throw const FormatException('MP4 box 标头不完整。');
      await reader.setPosition(offset);
      final header = await reader.read(8);
      var size = ByteData.sublistView(header).getUint32(0);
      final type = String.fromCharCodes(header.sublist(4));
      var headerSize = 8;
      if (size == 1) {
        if (offset + 16 > length) {
          throw const FormatException('MP4 大型 box 标头不完整。');
        }
        size = ByteData.sublistView(await reader.read(8)).getUint64(0);
        headerSize = 16;
      } else if (size == 0) {
        size = length - offset;
        if (size > 0xffffffff) throw const FormatException('MP4 box 过大。');
        patches.add((offset, _uint32(size)));
      }
      if (size < headerSize || offset + size > length) {
        throw const FormatException('MP4 box 长度无效。');
      }
      if (!const {
        'ftyp',
        'moov',
        'mdat',
        'free',
        'skip',
        'wide',
        'meta',
      }.contains(type)) {
        throw const FormatException('暂不支持此 MP4 分片或附加结构。');
      }
      if (type == 'mdat') mediaCount++;
      if (type == 'moov') {
        movieCount++;
        if (size > 32 * 1024 * 1024) {
          throw const FormatException('MP4 资料区超过安全处理上限。');
        }
        movieStart = offset;
        await reader.setPosition(offset + headerSize);
        movie = await reader.read(size - headerSize);
        if (movie.length != size - headerSize) {
          throw const FormatException('MP4 资料读取不完整。');
        }
      }
      offset += size;
    }
    if (movieCount != 1 || mediaCount == 0) {
      throw const FormatException('MP4 音频或资料区缺失、重复。');
    }
  } finally {
    await reader.close();
  }

  final children = _nodes(movie, 0, movie.length);
  if (children.any((item) => item.type == 'mvex')) {
    throw const FormatException('暂不支持分片 MP4。');
  }
  final paths = <(_Node?, _Node)>[];
  for (final child in children) {
    if (child.type == 'meta') paths.add((null, child));
    if (child.type == 'udta') {
      for (final nested in _nodes(movie, child.payload, child.end)) {
        if (nested.type == 'meta') paths.add((child, nested));
      }
    }
  }
  if (paths.length > 1) throw const FormatException('MP4 含多个资料区，无法安全追加。');
  late List<int> updatedMovie;
  if (paths.isEmpty) {
    final udta = children.where((item) => item.type == 'udta').toList();
    if (udta.length > 1) throw const FormatException('MP4 用户资料区重复。');
    final meta = _newMetadata(values, artwork, artworkMime);
    if (udta.isEmpty) {
      updatedMovie = _join([movie, _atom('udta', meta)]);
    } else {
      final existing = udta.single;
      updatedMovie = _replace(
        movie,
        0,
        movie.length,
        existing,
        _atom(
          'udta',
          _join([movie.sublist(existing.payload, existing.end), meta]),
        ),
      );
    }
  } else {
    final (udta, meta) = paths.single;
    final rewrittenMeta = _editMetadata(
      movie,
      meta,
      values,
      artwork,
      artworkMime,
    );
    if (udta == null) {
      updatedMovie = _replace(movie, 0, movie.length, meta, rewrittenMeta);
    } else {
      final rewrittenUser = _atom(
        'udta',
        _replace(movie, udta.payload, udta.end, meta, rewrittenMeta),
      );
      updatedMovie = _replace(movie, 0, movie.length, udta, rewrittenUser);
    }
  }
  final rebuilt = _atom('moov', updatedMovie);
  if (rebuilt.length > 32 * 1024 * 1024) {
    throw const FormatException('MP4 资料区超过安全处理上限。');
  }
  patches.add((movieStart + 4, 'free'.codeUnits));
  patches.sort((left, right) => left.$1.compareTo(right.$1));
  final staging = File('${copy.path}.tagging');
  try {
    final output = staging.openWrite();
    try {
      var position = 0;
      for (final (offset, replacement) in patches) {
        await output.addStream(copy.openRead(position, offset));
        output.add(replacement);
        position = offset + replacement.length;
      }
      await output.addStream(copy.openRead(position));
      output.add(rebuilt);
      await output.flush();
    } finally {
      await output.close();
    }
    await staging.rename(copy.path);
  } finally {
    if (await staging.exists()) await staging.delete();
  }
}

List<int> _newMetadata(
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? mime,
) => _atom(
  'meta',
  _join([
    [0, 0, 0, 0],
    _atom('hdlr', [
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      ...'mdir'.codeUnits,
      ...'appl'.codeUnits,
      ...List<int>.filled(9, 0),
    ]),
    _atom('ilst', _additions(values, artwork, mime, {})),
  ]),
);

List<int> _editMetadata(
  Uint8List data,
  _Node meta,
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? mime,
) {
  if (meta.end - meta.payload < 4 ||
      ByteData.sublistView(data).getUint32(meta.payload) != 0) {
    throw const FormatException('暂不支持此 MP4 资料版本。');
  }
  final children = _nodes(data, meta.payload + 4, meta.end);
  if (children.any((item) => item.type == 'keys')) {
    throw const FormatException('暂不支持键控 MP4 资料。');
  }
  final handlers = children.where((item) => item.type == 'hdlr').toList();
  if (handlers.length != 1 ||
      handlers.single.end - handlers.single.payload < 12 ||
      String.fromCharCodes(
            data.sublist(
              handlers.single.payload + 8,
              handlers.single.payload + 12,
            ),
          ) !=
          'mdir') {
    throw const FormatException('暂不支持此 MP4 资料处理器。');
  }
  final lists = children.where((item) => item.type == 'ilst').toList();
  if (lists.length > 1) throw const FormatException('MP4 标签列表重复。');
  if (lists.isEmpty) {
    return _atom(
      'meta',
      _join([
        data.sublist(meta.payload, meta.end),
        _atom('ilst', _additions(values, artwork, mime, {})),
      ]),
    );
  }
  final list = lists.single;
  final atoms = _nodes(data, list.payload, list.end);
  final targets = values.keys.map(_fieldType).toSet();
  final retained = BytesBuilder(copy: false);
  for (final atom in atoms) {
    if (targets.contains(atom.type)) {
      if (atoms.where((other) => other.type == atom.type).length != 1 ||
          !_emptyTextTag(data, atom)) {
        throw const FormatException('MP4 目标标签已存在或无法安全读取，未覆盖。');
      }
      // Only one validated, whitespace-only UTF-8 data atom can be replaced.
      // Unknown encodings, multiple values, artwork and private children stay
      // protected; every unrelated atom is copied byte-for-byte.
      continue;
    }
    retained.add(Uint8List.sublistView(data, atom.start, atom.end));
  }
  retained.add(_additions(values, artwork, mime, {}));
  final rewritten = _atom('ilst', retained.takeBytes());
  return _atom('meta', _replace(data, meta.payload, meta.end, list, rewritten));
}

String _fieldType(AudioField field) => switch (field) {
  AudioField.title => '©nam',
  AudioField.artist => '©ART',
  AudioField.album => '©alb',
  AudioField.lyrics => '©lyr',
  AudioField.artwork => 'covr',
};

bool _emptyTextTag(Uint8List data, _Node atom) {
  if (atom.type == 'covr') return false;
  final children = _nodes(data, atom.payload, atom.end);
  if (children.length != 1 || children.single.type != 'data') return false;
  final value = children.single;
  if (value.end - value.payload < 8 ||
      ByteData.sublistView(data).getUint32(value.payload) != 1) {
    return false;
  }
  try {
    return utf8
        .decode(Uint8List.sublistView(data, value.payload + 8, value.end))
        .trim()
        .isEmpty;
  } on FormatException {
    return false;
  }
}

List<int> _additions(
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? mime,
  Set<String> existing,
) {
  final result = BytesBuilder(copy: false);
  for (final entry in values.entries) {
    final type = _fieldType(entry.key);
    if (existing.contains(type)) {
      throw const FormatException('MP4 目标标签已存在，未覆盖。');
    }
    if (!hasText(entry.value)) throw const FormatException('候选内容不能为空。');
    var format = 1;
    List<int> bytes;
    if (entry.key == AudioField.artwork) {
      if (artwork == null ||
          artwork.isEmpty ||
          !const {'image/jpeg', 'image/png'}.contains(mime)) {
        throw const FormatException('封面未准备好。');
      }
      format = mime == 'image/png' ? 14 : 13;
      bytes = artwork;
    } else {
      bytes = utf8.encode(entry.value);
    }
    result.add(
      _atom(type, _atom('data', _join([_uint32(format), _uint32(0), bytes]))),
    );
  }
  return result.takeBytes();
}

List<int> _replace(
  Uint8List data,
  int start,
  int end,
  _Node old,
  List<int> replacement,
) => _join([
  Uint8List.sublistView(data, start, old.start),
  replacement,
  Uint8List.sublistView(data, old.end, end),
]);
List<int> _uint32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
List<int> _atom(String type, List<int> payload) =>
    _join([_uint32(payload.length + 8), latin1.encode(type), payload]);
Uint8List _join(List<List<int>> parts) {
  final bytes = BytesBuilder(copy: false);
  for (final part in parts) {
    bytes.add(part);
  }
  return bytes.takeBytes();
}

List<_Node> _nodes(Uint8List data, int start, int end) {
  final result = <_Node>[];
  var offset = start;
  while (offset < end) {
    if (offset + 8 > end) throw const FormatException('MP4 资料 box 标头不完整。');
    var size = ByteData.sublistView(data).getUint32(offset);
    var header = 8;
    if (size == 1) {
      if (offset + 16 > end) throw const FormatException('MP4 资料大型 box 不完整。');
      size = ByteData.sublistView(data).getUint64(offset + 8);
      header = 16;
    }
    if (size < header || offset + size > end) {
      throw const FormatException('MP4 资料 box 长度无效。');
    }
    result.add(
      _Node(
        String.fromCharCodes(data.sublist(offset + 4, offset + 8)),
        offset,
        offset + header,
        offset + size,
      ),
    );
    offset += size;
  }
  return result;
}

class _Node {
  const _Node(this.type, this.start, this.payload, this.end);
  final String type;
  final int start;
  final int payload;
  final int end;
}
