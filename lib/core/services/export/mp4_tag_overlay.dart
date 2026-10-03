import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/audio_track.dart';

/// Adds absent iTunes tags, or replaces explicitly selected supported tags.
/// Unselected tag atoms and untouched halves of number pairs are retained.
/// The rebuilt moov is appended at EOF; the old moov becomes same-sized free
/// padding. Existing media never moves, so stco/co64 offsets remain exact.
/// This trades a larger, potentially non-fast-start copy for safer preservation.
Future<void> addMissingMp4Tags(
  File copy,
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? artworkMime, {
  Set<AudioField> replaceFields = const {},
}) async {
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
      replaceFields,
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
    _atom('ilst', _additions(values, artwork, mime)),
  ]),
);

List<int> _editMetadata(
  Uint8List data,
  _Node meta,
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? mime,
  Set<AudioField> replaceFields,
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
        _atom('ilst', _additions(values, artwork, mime)),
      ]),
    );
  }
  final list = lists.single;
  final atoms = _nodes(data, list.payload, list.end);
  if (values.containsKey(AudioField.genre) &&
      atoms.any((atom) => atom.type == 'gnre')) {
    throw const FormatException('MP4 含数字类型流派标签，暂不支持安全替换。');
  }
  final targets = values.keys.map(_fieldType).toSet();
  final remaining = Map<AudioField, String>.of(values);
  final retained = BytesBuilder(copy: false);
  for (final atom in atoms) {
    if (targets.contains(atom.type)) {
      if (atoms.where((other) => other.type == atom.type).length != 1) {
        throw const FormatException('MP4 目标标签已存在或无法安全读取，未覆盖。');
      }
      final selected = <AudioField, String>{
        for (final entry in values.entries)
          if (_fieldType(entry.key) == atom.type) entry.key: entry.value,
      };
      retained.add(
        _editTag(data, atom, selected, artwork, mime, replaceFields),
      );
      remaining.removeWhere((field, _) => selected.containsKey(field));
      continue;
    }
    retained.add(Uint8List.sublistView(data, atom.start, atom.end));
  }
  retained.add(_additions(remaining, artwork, mime));
  final rewritten = _atom('ilst', retained.takeBytes());
  return _atom('meta', _replace(data, meta.payload, meta.end, list, rewritten));
}

String _fieldType(AudioField field) => switch (field) {
  AudioField.title => '©nam',
  AudioField.artist => '©ART',
  AudioField.album => '©alb',
  AudioField.albumArtist => 'aART',
  AudioField.year => '©day',
  AudioField.genre => '©gen',
  AudioField.trackNumber || AudioField.trackTotal => 'trkn',
  AudioField.discNumber || AudioField.discTotal => 'disk',
  AudioField.composer => '©wrt',
  AudioField.comment => '©cmt',
  AudioField.lyrics => '©lyr',
  AudioField.artwork => 'covr',
};

List<int> _editTag(
  Uint8List data,
  _Node atom,
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? mime,
  Set<AudioField> replaceFields,
) {
  for (final value in values.values) {
    if (!hasText(value)) throw const FormatException('候选内容不能为空。');
  }
  final children = _nodes(data, atom.payload, atom.end);
  if (atom.type == 'covr') {
    if (!replaceFields.contains(AudioField.artwork) || children.isEmpty) {
      throw const FormatException('MP4 封面已存在或无法安全读取，未覆盖。');
    }
    for (final child in children) {
      if (child.type != 'data' || child.end - child.payload < 9) {
        throw const FormatException('MP4 封面结构无法安全读取。');
      }
      final format = ByteData.sublistView(data).getUint32(child.payload);
      if (format != 13 && format != 14) {
        throw const FormatException('MP4 封面格式不受支持。');
      }
    }
    // iTunes covr has no picture-role flag. Its first image is the displayed
    // cover; all later images (including their data headers) stay unchanged.
    final first = children.first;
    return _atom(
      atom.type,
      _replace(
        data,
        atom.payload,
        atom.end,
        first,
        _artworkData(
          artwork,
          mime,
          data.sublist(first.payload + 4, first.payload + 8),
        ),
      ),
    );
  }
  if (children.length != 1 || children.single.type != 'data') {
    throw const FormatException('MP4 目标标签包含不支持的附加资料。');
  }
  final value = children.single;
  if (atom.type == 'trkn' || atom.type == 'disk') {
    final bytes = _numberPair(data, value);
    final pair = ByteData.sublistView(bytes);
    for (final entry in values.entries) {
      final offset = _isTotal(entry.key) ? 4 : 2;
      if (pair.getUint16(offset) != 0 && !replaceFields.contains(entry.key)) {
        throw const FormatException('MP4 目标序号已存在，未覆盖。');
      }
      pair.setUint16(offset, _number(entry.value));
    }
    return _atom(
      atom.type,
      _atom(
        'data',
        _join([data.sublist(value.payload, value.payload + 8), bytes]),
      ),
    );
  }
  if (value.end - value.payload < 8 ||
      ByteData.sublistView(data).getUint32(value.payload) != 1) {
    throw const FormatException('MP4 目标标签不是受支持的 UTF-8 文字。');
  }
  final previous = utf8.decode(
    Uint8List.sublistView(data, value.payload + 8, value.end),
  );
  final entry = values.entries.single;
  if (previous.trim().isNotEmpty && !replaceFields.contains(entry.key)) {
    throw const FormatException('MP4 目标标签已存在，未覆盖。');
  }
  return _atom(
    atom.type,
    _atom(
      'data',
      _join([
        data.sublist(value.payload, value.payload + 8),
        utf8.encode(entry.value),
      ]),
    ),
  );
}

List<int> _additions(
  Map<AudioField, String> values,
  Uint8List? artwork,
  String? mime,
) {
  final result = BytesBuilder(copy: false);
  final added = <String>{};
  for (final entry in values.entries) {
    final type = _fieldType(entry.key);
    if (!hasText(entry.value)) throw const FormatException('候选内容不能为空。');
    if (!added.add(type)) continue;
    if (entry.key == AudioField.artwork) {
      result.add(_atom(type, _artworkData(artwork, mime, _uint32(0))));
      continue;
    }
    if (type == 'trkn' || type == 'disk') {
      final pair = ByteData(type == 'trkn' ? 8 : 6);
      for (final field in values.entries) {
        if (_fieldType(field.key) == type) {
          pair.setUint16(_isTotal(field.key) ? 4 : 2, _number(field.value));
        }
      }
      result.add(
        _atom(
          type,
          _atom(
            'data',
            _join([_uint32(0), _uint32(0), pair.buffer.asUint8List()]),
          ),
        ),
      );
      continue;
    }
    result.add(
      _atom(
        type,
        _atom(
          'data',
          _join([_uint32(1), _uint32(0), utf8.encode(entry.value)]),
        ),
      ),
    );
  }
  return result.takeBytes();
}

bool _isTotal(AudioField field) =>
    field == AudioField.trackTotal || field == AudioField.discTotal;

int _number(String value) {
  final text = value.trim();
  final parsed = RegExp(r'^[0-9]+$').hasMatch(text) ? int.tryParse(text) : null;
  if (parsed == null || parsed < 1 || parsed > 0xffff) {
    throw const FormatException('MP4 曲目或碟片序号须介于 1 与 65535。');
  }
  return parsed;
}

Uint8List _numberPair(Uint8List data, _Node value) {
  final length = value.end - value.payload;
  if ((length != 14 && length != 16) ||
      ByteData.sublistView(data).getUint32(value.payload) != 0) {
    throw const FormatException('MP4 曲目或碟片序号结构不受支持。');
  }
  final bytes = Uint8List.fromList(data.sublist(value.payload + 8, value.end));
  final pair = ByteData.sublistView(bytes);
  if (pair.getUint16(0) != 0 || (bytes.length == 8 && pair.getUint16(6) != 0)) {
    throw const FormatException('MP4 曲目或碟片序号保留资料不受支持。');
  }
  return bytes;
}

List<int> _artworkData(Uint8List? artwork, String? mime, List<int> locale) {
  if (artwork == null ||
      artwork.isEmpty ||
      !const {'image/jpeg', 'image/png'}.contains(mime)) {
    throw const FormatException('封面未准备好。');
  }
  return _atom(
    'data',
    _join([_uint32(mime == 'image/png' ? 14 : 13), locale, artwork]),
  );
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
