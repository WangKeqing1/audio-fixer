import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/export/mp4_tag_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _u16(int value) =>
    (ByteData(2)..setUint16(0, value)).buffer.asUint8List();
List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
List<int> _box(String type, List<int> bytes) => [
  ..._u32(bytes.length + 8),
  ...latin1.encode(type),
  ...bytes,
];
List<int> _value(List<int> bytes, {int format = 1, int locale = 0}) =>
    _box('data', [..._u32(format), ..._u32(locale), ...bytes]);
List<int> _text(String type, String value, {int locale = 0}) =>
    _box(type, _value(utf8.encode(value), locale: locale));
List<int> _pair(String type, int number, int total, {int? length}) => _box(
  type,
  _value(
    [
      0,
      0,
      ..._u16(number),
      ..._u16(total),
      if ((length ?? (type == 'trkn' ? 8 : 6)) == 8) ...[0, 0],
    ],
    format: 0,
    locale: 17,
  ),
);
List<int> _file(List<List<int>> tags) => [
  ..._box('ftyp', [...'M4A '.codeUnits, ..._u32(0), ...'isom'.codeUnits]),
  ..._box('mdat', [11, 22, 33, 44, 55]),
  ..._box('moov', [
    ..._box(
      'udta',
      _box('meta', [
        0,
        0,
        0,
        0,
        ..._box('hdlr', [
          ...List<int>.filled(8, 0),
          ...'mdir'.codeUnits,
          ...List<int>.filled(12, 0),
        ]),
        ..._box('ilst', tags.expand((tag) => tag).toList()),
      ]),
    ),
    ..._box('free', [6, 5, 4, 3, 2, 1]),
  ]),
];

List<Uint8List> _children(List<int> bytes, {int offset = 0}) {
  final data = Uint8List.fromList(bytes);
  final result = <Uint8List>[];
  while (offset < data.length) {
    final length = ByteData.sublistView(data).getUint32(offset);
    result.add(Uint8List.sublistView(data, offset, offset + length));
    offset += length;
  }
  return result;
}

String _type(List<int> atom) => latin1.decode(atom.sublist(4, 8));
Uint8List _child(List<int> bytes, String type, {int offset = 8}) =>
    _children(bytes, offset: offset).singleWhere((atom) => _type(atom) == type);
List<Uint8List> _tags(List<int> bytes) {
  final movie = _child(bytes, 'moov', offset: 0);
  final user = _child(movie, 'udta');
  final meta = _child(user, 'meta');
  return _children(_child(meta, 'ilst', offset: 12), offset: 8);
}

Uint8List _tag(List<int> bytes, String type) =>
    _tags(bytes).singleWhere((tag) => _type(tag) == type);
String _readText(List<int> bytes, String type) =>
    utf8.decode(_child(_tag(bytes, type), 'data').sublist(16));
(int, int) _readPair(List<int> bytes, String type) {
  final value = ByteData.sublistView(_child(_tag(bytes, type), 'data'));
  return (value.getUint16(18), value.getUint16(20));
}

void main() {
  late Directory temporary;
  var index = 0;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('mp4_replacement_');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  Future<File> write(List<List<int>> tags) async {
    final file = File('${temporary.path}/${index++}.m4a');
    await file.writeAsBytes(_file(tags));
    return file;
  }

  test(
    'selected common text tags replace while private tags and media stay raw',
    () async {
      const fields = {
        AudioField.title: '©nam',
        AudioField.artist: '©ART',
        AudioField.album: '©alb',
        AudioField.albumArtist: 'aART',
        AudioField.year: '©day',
        AudioField.genre: '©gen',
        AudioField.composer: '©wrt',
        AudioField.comment: '©cmt',
        AudioField.lyrics: '©lyr',
      };
      final private = _box('----', [9, 8, 7, 6, 5]);
      final encoder = _text('©too', 'Existing encoder');
      final file = await write([
        for (final type in fields.values) _text(type, 'Old value', locale: 23),
        private,
        encoder,
      ]);
      final before = await file.readAsBytes();
      final values = {
        for (final field in fields.keys)
          field: field == AudioField.year ? '2026' : '新的 ${field.name}',
      };
      await addMissingMp4Tags(
        file,
        values,
        null,
        null,
        replaceFields: fields.keys.toSet(),
      );
      final after = await file.readAsBytes();
      for (final entry in fields.entries) {
        expect(_readText(after, entry.value), values[entry.key]);
        expect(
          ByteData.sublistView(_child(_tag(after, entry.value), 'data'))
              .getUint32(12),
          23,
        );
      }
      expect(_tag(after, '----'), private);
      expect(_tag(after, '©too'), encoder);
      expect(
        _child(after, 'mdat', offset: 0),
        _child(before, 'mdat', offset: 0),
      );
      final originalMovie = _child(before, 'moov', offset: 0);
      final movieStart = before.length - originalMovie.length;
      final expectedOriginal = before.toList()
        ..setRange(movieStart + 4, movieStart + 8, 'free'.codeUnits);
      expect(after.sublist(0, before.length), expectedOriginal);
    },
  );

  test(
    'replacement permission remains specific to each selected field',
    () async {
      final file = await write([
        _text('©nam', 'Old title'),
        _text('©alb', 'Old album'),
      ]);
      final before = await file.readAsBytes();
      await expectLater(
        addMissingMp4Tags(
          file,
          {AudioField.title: 'New title', AudioField.album: 'New album'},
          null,
          null,
          replaceFields: {AudioField.title},
        ),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), before);
      await expectLater(
        addMissingMp4Tags(file, {AudioField.title: 'New title'}, null, null),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), before);
    },
  );

  test(
    'number pair edits preserve the unselected half and data locale',
    () async {
      for (final field in [
        AudioField.trackNumber,
        AudioField.trackTotal,
        AudioField.discNumber,
        AudioField.discTotal,
      ]) {
        final type =
            field == AudioField.trackNumber || field == AudioField.trackTotal
            ? 'trkn'
            : 'disk';
        final total =
            field == AudioField.trackTotal || field == AudioField.discTotal;
        final file = await write([_pair(type, 2, 9)]);
        await addMissingMp4Tags(
          file,
          {field: '7'},
          null,
          null,
          replaceFields: {field},
        );
        final after = await file.readAsBytes();
        expect(_readPair(after, type), total ? (2, 7) : (7, 9));
        expect(
          ByteData.sublistView(_child(_tag(after, type), 'data')).getUint32(12),
          17,
        );
      }
    },
  );

  test(
    'missing pair halves can be filled without replacing their counterpart',
    () async {
      final file = await write([_pair('trkn', 0, 12), _pair('disk', 2, 0)]);
      await addMissingMp4Tags(
        file,
        {AudioField.trackNumber: '3', AudioField.discTotal: '4'},
        null,
        null,
      );
      final after = await file.readAsBytes();
      expect(_readPair(after, 'trkn'), (3, 12));
      expect(_readPair(after, 'disk'), (2, 4));
      final beforeRejected = after;
      await expectLater(
        addMissingMp4Tags(
          file,
          {AudioField.trackNumber: '4', AudioField.trackTotal: '15'},
          null,
          null,
          replaceFields: {AudioField.trackNumber},
        ),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), beforeRejected);
    },
  );

  test(
    'new number and total values share one standard atom per pair',
    () async {
      final file = await write([]);
      await addMissingMp4Tags(
        file,
        {
          AudioField.trackTotal: '12',
          AudioField.trackNumber: '3',
          AudioField.discNumber: '2',
          AudioField.discTotal: '4',
        },
        null,
        null,
      );
      final after = await file.readAsBytes();
      expect(_tags(after).map(_type), ['trkn', 'disk']);
      expect(_readPair(after, 'trkn'), (3, 12));
      expect(_readPair(after, 'disk'), (2, 4));
    },
  );

  test(
    'cover replacement preserves every extra artwork entry byte for byte',
    () async {
      final originalFront = _value(
        [0xff, 0xd8, 0xff, 1],
        format: 13,
        locale: 12,
      );
      final extra = _value(
        [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10, 2],
        format: 14,
        locale: 99,
      );
      final file = await write([
        _box('covr', [...originalFront, ...extra]),
      ]);
      final before = await file.readAsBytes();
      final newFront = Uint8List.fromList([
        0x89,
        0x50,
        0x4e,
        0x47,
        13,
        10,
        26,
        10,
        3,
      ]);
      await expectLater(
        addMissingMp4Tags(
          file,
          {AudioField.artwork: 'cover.png'},
          newFront,
          'image/png',
        ),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), before);
      await addMissingMp4Tags(
        file,
        {AudioField.artwork: 'cover.png'},
        newFront,
        'image/png',
        replaceFields: {AudioField.artwork},
      );
      final entries = _children(
        _tag(await file.readAsBytes(), 'covr'),
        offset: 8,
      );
      expect(entries, [_value(newFront, format: 14, locale: 12), extra]);
    },
  );

  test('unsupported selected text, number and artwork structures fail without mutation', () async {
    final cases = <(List<List<int>>, AudioField)>[
      ([_text('©nam', 'one'), _text('©nam', 'two')], AudioField.title),
      (
        [
          _box('©nam', [
            ..._value(utf8.encode('one')),
            ..._value(utf8.encode('two')),
          ]),
        ],
        AudioField.title,
      ),
      (
        [
          _box('©nam', _value([0xff])),
        ],
        AudioField.title,
      ),
      (
        [
          _box('©nam', _value([0, 65], format: 2)),
        ],
        AudioField.title,
      ),
      (
        [
          _box('©nam', [..._value(utf8.encode('old')), ..._box('free', [])]),
        ],
        AudioField.title,
      ),
      (
        [
          _box('trkn', _value([0, 0, 0, 1], format: 0)),
        ],
        AudioField.trackNumber,
      ),
      (
        [
          _box('disk', _value([0, 0, 0, 1, 0, 2], format: 1)),
        ],
        AudioField.discNumber,
      ),
      (
        [
          _box('trkn', _value([0, 0, 0, 1, 0, 2, 0, 1], format: 0)),
        ],
        AudioField.trackTotal,
      ),
      (
        [
          _box('covr', _value([1, 2, 3], format: 1)),
        ],
        AudioField.artwork,
      ),
      ([_box('covr', _value([], format: 13))], AudioField.artwork),
      (
        [
          _box('covr', [
            ..._value([1], format: 13),
            ..._box('name', [2]),
          ]),
        ],
        AudioField.artwork,
      ),
      (
        [
          _box('gnre', _value([0, 14], format: 0)),
        ],
        AudioField.genre,
      ),
    ];
    for (final (tags, field) in cases) {
      final file = await write(tags);
      final before = await file.readAsBytes();
      await expectLater(
        addMissingMp4Tags(
          file,
          {field: '7'},
          Uint8List.fromList([0xff, 0xd8, 0xff]),
          'image/jpeg',
          replaceFields: {field},
        ),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), before);
    }
  });

  test(
    'out of range or noninteger numbers are rejected before mutation',
    () async {
      for (final value in ['0', '-1', '65536', '1.5', '1/12', '']) {
        for (final tags in <List<List<int>>>[
          [],
          [_pair('trkn', 1, 12)],
        ]) {
          final file = await write(tags);
          final before = await file.readAsBytes();
          await expectLater(
            addMissingMp4Tags(
              file,
              {AudioField.trackNumber: value},
              null,
              null,
              replaceFields: {AudioField.trackNumber},
            ),
            throwsFormatException,
          );
          expect(await file.readAsBytes(), before);
        }
      }
    },
  );
}
