import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/export/flac_tag_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Block = ({int type, Uint8List bytes});

Uint8List _u32(int value, [Endian endian = Endian.big]) =>
    (ByteData(4)..setUint32(0, value, endian)).buffer.asUint8List();

Uint8List _comments(List<List<int>> entries) => Uint8List.fromList([
  ..._u32(6, Endian.little),
  ...[0, 255, 97, 98, 99, 0], // Preserve the original, opaque vendor bytes.
  ..._u32(entries.length, Endian.little),
  for (final entry in entries) ...[
    ..._u32(entry.length, Endian.little),
    ...entry,
  ],
]);

Uint8List _picture(int type, List<int> image) => Uint8List.fromList([
  ..._u32(type),
  ..._u32(9),
  ...ascii.encode('image/png'),
  ..._u32(4),
  ...ascii.encode('test'),
  ..._u32(1),
  ..._u32(1),
  ..._u32(24),
  ..._u32(0),
  ..._u32(image.length),
  ...image,
]);

const _audio = [0xff, 0xf8, 1, 2, 3, 4, 5, 6];

Uint8List _flac(List<_Block> metadata) {
  final blocks = [
    (type: 0, bytes: Uint8List.fromList(List.generate(34, (i) => i))),
    ...metadata,
  ];
  return Uint8List.fromList([
    ...ascii.encode('fLaC'),
    for (var i = 0; i < blocks.length; i++) ...[
      blocks[i].type | (i == blocks.length - 1 ? 0x80 : 0),
      (blocks[i].bytes.length >> 16) & 255,
      (blocks[i].bytes.length >> 8) & 255,
      blocks[i].bytes.length & 255,
      ...blocks[i].bytes,
    ],
    ..._audio,
  ]);
}

({List<_Block> blocks, Uint8List audio}) _read(Uint8List bytes) {
  final blocks = <_Block>[];
  var cursor = 4;
  var last = false;
  while (!last) {
    last = bytes[cursor] & 0x80 != 0;
    final type = bytes[cursor] & 0x7f;
    final length =
        (bytes[cursor + 1] << 16) |
        (bytes[cursor + 2] << 8) |
        bytes[cursor + 3];
    cursor += 4;
    blocks.add((type: type, bytes: bytes.sublist(cursor, cursor + length)));
    cursor += length;
  }
  return (blocks: blocks, audio: bytes.sublist(cursor));
}

List<Uint8List> _rawComments(List<_Block> blocks) {
  final bytes = blocks.singleWhere((block) => block.type == 4).bytes;
  final data = ByteData.sublistView(bytes);
  var cursor = 4 + data.getUint32(0, Endian.little);
  final count = data.getUint32(cursor, Endian.little);
  cursor += 4;
  return List.generate(count, (_) {
    final length = data.getUint32(cursor, Endian.little);
    cursor += 4;
    final result = bytes.sublist(cursor, cursor + length);
    cursor += length;
    return result;
  });
}

List<String> _textComments(List<_Block> blocks) =>
    _rawComments(blocks)
        .map((raw) => utf8.decode(raw, allowMalformed: true))
        .toList();

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('flac-replacement-');
    file = File('${directory.path}/track.flac');
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> writeComments(List<String> entries) => file.writeAsBytes(
    _flac([(type: 4, bytes: _comments(entries.map(utf8.encode).toList()))]),
  );

  test(
    'replaces common aliases while preserving all unrelated raw data',
    () async {
      final unknown = [0xff, 0, 61, 0xf0, 0x80];
      final old = _comments([
        ...[
          'TITLE=Old title',
          'title=Second title',
          'ARTIST=Old artist',
          'ALBUM=Old album',
          'ALBUM_ARTIST=Old album artist',
          'ALBUM ARTIST=Another old album artist',
          'DATE=1999-10-09',
          'YEAR=1999',
          'GENRE=Old genre',
          'TRACKNUMBER=2',
          'TOTALTRACKS=12',
          'DISC=1',
          'TOTALDISCS=2',
          'COMPOSER=Old composer',
          'COMMENT=Old comment',
          'LYRICS=Old lyrics',
          'DESCRIPTION=Old comment alias',
          'DESCRIBED_CUSTOM=Keep this distinct description',
          'REPLAYGAIN_TRACK_GAIN=-4.2 dB',
          'CUSTOM=First',
          'CUSTOM=Second',
        ].map(utf8.encode),
        unknown,
      ]);
      final application = Uint8List.fromList([1, 2, 3, 4, 5]);
      final back = _picture(4, [88, 77]);
      await file.writeAsBytes(
        _flac([
          (type: 2, bytes: application),
          (type: 4, bytes: old),
          (type: 6, bytes: back),
        ]),
      );
      final before = _read(await file.readAsBytes());
      final values = <AudioField, String>{
        AudioField.title: 'New title',
        AudioField.artist: 'New artist',
        AudioField.album: 'New album',
        AudioField.albumArtist: 'New album artist',
        AudioField.year: '2026',
        AudioField.genre: 'New genre',
        AudioField.trackNumber: '3',
        AudioField.trackTotal: '15',
        AudioField.discNumber: '2',
        AudioField.discTotal: '3',
        AudioField.composer: 'New composer',
        AudioField.comment: 'New comment',
        AudioField.lyrics: 'New lyrics',
      };
      await addMissingFlacTags(
        file,
        values,
        null,
        null,
        replaceFields: values.keys.toSet(),
      );
      final after = _read(await file.readAsBytes());
      expect(after.audio, _audio);
      expect(after.blocks.first.bytes, before.blocks.first.bytes);
      expect(after.blocks.singleWhere((b) => b.type == 2).bytes, application);
      expect(after.blocks.singleWhere((b) => b.type == 6).bytes, back);
      expect(
        after.blocks.singleWhere((b) => b.type == 4).bytes.sublist(0, 10),
        old.sublist(0, 10),
      );
      expect(
        _textComments(after.blocks),
        containsAll([
          'TITLE=New title',
          'ARTIST=New artist',
          'ALBUM=New album',
          'ALBUMARTIST=New album artist',
          'DATE=2026',
          'GENRE=New genre',
          'TRACKNUMBER=3',
          'TRACKTOTAL=15',
          'DISCNUMBER=2',
          'DISCTOTAL=3',
          'COMPOSER=New composer',
          'COMMENT=New comment',
          'LYRICS=New lyrics',
          'DESCRIBED_CUSTOM=Keep this distinct description',
          'REPLAYGAIN_TRACK_GAIN=-4.2 dB',
          'CUSTOM=First',
          'CUSTOM=Second',
        ]),
      );
      expect(
        _textComments(after.blocks).where((v) => v.contains('Old')),
        isEmpty,
      );
      expect(
        _rawComments(after.blocks).lastWhere((raw) => raw[0] == 255),
        unknown,
      );
    },
  );

  test('DESCRIPTION-only comment obeys replacement permission', () async {
    await writeComments(['DESCRIPTION=Old note', 'CUSTOM=keep']);
    final before = await file.readAsBytes();
    await expectLater(
      addMissingFlacTags(file, {AudioField.comment: 'New note'}, null, null),
      throwsFormatException,
    );
    expect(await file.readAsBytes(), before);
    await addMissingFlacTags(
      file,
      {AudioField.comment: 'New note'},
      null,
      null,
      replaceFields: {AudioField.comment},
    );
    expect(_textComments(_read(await file.readAsBytes()).blocks), [
      'CUSTOM=keep',
      'COMMENT=New note',
    ]);
  });

  test('replacement permission applies only to the selected field', () async {
    await writeComments(['TITLE=Old', 'ALBUM_ARTIST=Existing']);
    final before = await file.readAsBytes();
    await expectLater(
      addMissingFlacTags(
        file,
        {AudioField.title: 'New', AudioField.albumArtist: 'New'},
        null,
        null,
        replaceFields: {AudioField.title},
      ),
      throwsFormatException,
    );
    expect(await file.readAsBytes(), before);
    expect(await File('${file.path}.tagging').exists(), isFalse);
  });

  test(
    'empty aliases remain replaceable without replacement permission',
    () async {
      await writeComments(['YEAR= ', 'ALBUM_ARTIST=', 'TITLE=Untouched']);
      await addMissingFlacTags(
        file,
        {AudioField.year: '2026', AudioField.albumArtist: 'Artist'},
        null,
        null,
      );
      expect(_textComments(_read(await file.readAsBytes()).blocks), [
        'TITLE=Untouched',
        'DATE=2026',
        'ALBUMARTIST=Artist',
      ]);
    },
  );

  test('number replacement extracts and preserves combined totals', () async {
    await writeComments([
      'TRACKNUMBER=02/012',
      'DISCNUMBER=1/2',
      'CUSTOM=keep',
    ]);
    await addMissingFlacTags(
      file,
      {AudioField.trackNumber: '4', AudioField.discNumber: '2'},
      null,
      null,
      replaceFields: {AudioField.trackNumber, AudioField.discNumber},
    );
    expect(
      _textComments(_read(await file.readAsBytes()).blocks),
      containsAll([
        'TRACKNUMBER=4',
        'TRACKTOTAL=012',
        'DISCNUMBER=2',
        'DISCTOTAL=2',
        'CUSTOM=keep',
      ]),
    );
  });

  test(
    'total replacement preserves combined numbers and removes aliases',
    () async {
      await writeComments([
        'tracknumber=02/12',
        'TOTALTRACKS=12',
        'TRACKTOTAL=12',
        'DISCNUMBER=1/2',
        'TOTALDISCS=2',
      ]);
      await addMissingFlacTags(
        file,
        {AudioField.trackTotal: '15', AudioField.discTotal: '3'},
        null,
        null,
        replaceFields: {AudioField.trackTotal, AudioField.discTotal},
      );
      expect(_textComments(_read(await file.readAsBytes()).blocks), [
        'tracknumber=02',
        'DISCNUMBER=1',
        'TRACKTOTAL=15',
        'DISCTOTAL=3',
      ]);
    },
  );

  test(
    'separate unselected counterpart comments keep their exact bytes',
    () async {
      await writeComments([
        'TRACKNUMBER=2/12',
        'totaltracks=0012',
        'DISCNUMBER=01',
      ]);
      await addMissingFlacTags(
        file,
        {AudioField.trackNumber: '3', AudioField.discTotal: '2'},
        null,
        null,
        replaceFields: {AudioField.trackNumber},
      );
      expect(_textComments(_read(await file.readAsBytes()).blocks), [
        'totaltracks=0012',
        'DISCNUMBER=01',
        'TRACKNUMBER=3',
        'DISCTOTAL=2',
      ]);
    },
  );

  test('combined total is existing data for the missing-only guard', () async {
    await writeComments(['TRACKNUMBER=2/12']);
    final before = await file.readAsBytes();
    await expectLater(
      addMissingFlacTags(file, {AudioField.trackTotal: '15'}, null, null),
      throwsFormatException,
    );
    expect(await file.readAsBytes(), before);
  });

  for (final entries in [
    ['TRACKNUMBER=2/12/15'],
    ['TRACKNUMBER=2/not-a-number'],
    ['TRACKNUMBER=2/12', 'TOTALTRACKS=13'],
  ]) {
    test('unsupported pair fails closed: $entries', () async {
      await writeComments(entries);
      final before = await file.readAsBytes();
      await expectLater(
        addMissingFlacTags(
          file,
          {AudioField.trackNumber: '3'},
          null,
          null,
          replaceFields: {AudioField.trackNumber},
        ),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), before);
    });
  }

  test(
    'front replacement preserves other pictures in both storage forms',
    () async {
      final back = _picture(4, [11, 12]);
      final artist = _picture(8, [21, 22]);
      final front = _picture(3, [31, 32]);
      final artistComment = 'METADATA_BLOCK_PICTURE=${base64.encode(artist)}';
      await file.writeAsBytes(
        _flac([
          (
            type: 4,
            bytes: _comments([
              utf8.encode('METADATA_BLOCK_PICTURE=${base64.encode(front)}'),
              utf8.encode(artistComment),
              utf8.encode('CUSTOM=keep'),
            ]),
          ),
          (type: 6, bytes: front),
          (type: 6, bytes: back),
        ]),
      );
      await addMissingFlacTags(
        file,
        {AudioField.artwork: 'new'},
        Uint8List.fromList([41, 42]),
        'image/png',
        replaceFields: {AudioField.artwork},
      );
      final result = _read(await file.readAsBytes());
      expect(_textComments(result.blocks), [artistComment, 'CUSTOM=keep']);
      final pictures = result.blocks.where((b) => b.type == 6).toList();
      expect(pictures, hasLength(2));
      expect(pictures.first.bytes, back);
      expect(ByteData.sublistView(pictures.last.bytes).getUint32(0), 3);
      expect(pictures.last.bytes.sublist(pictures.last.bytes.length - 2), [
        41,
        42,
      ]);
      expect(result.audio, _audio);
    },
  );

  test('adding a missing front preserves existing nonfront pictures', () async {
    final back = _picture(4, [11, 12]);
    await file.writeAsBytes(_flac([(type: 6, bytes: back)]));
    await addMissingFlacTags(
      file,
      {AudioField.artwork: 'new'},
      Uint8List.fromList([41, 42]),
      'image/png',
    );
    final result = _read(await file.readAsBytes());
    expect(result.blocks.where((b) => b.type == 6), hasLength(2));
    expect(result.blocks[1].bytes, back);
    expect(result.audio, _audio);
  });

  for (final asComment in [false, true]) {
    test('existing front requires permission (comment=$asComment)', () async {
      final picture = _picture(3, [31, 32]);
      await file.writeAsBytes(
        _flac([
          if (asComment)
            (
              type: 4,
              bytes: _comments([
                utf8.encode('METADATA_BLOCK_PICTURE=${base64.encode(picture)}'),
              ]),
            )
          else
            (type: 6, bytes: picture),
        ]),
      );
      final before = await file.readAsBytes();
      await expectLater(
        addMissingFlacTags(
          file,
          {AudioField.artwork: 'new'},
          Uint8List.fromList([41, 42]),
          'image/png',
        ),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), before);
    });

    test('malformed front fails closed (comment=$asComment)', () async {
      final picture = Uint8List.fromList([..._u32(3), ..._u32(0xffffffff)]);
      await file.writeAsBytes(
        _flac([
          if (asComment)
            (
              type: 4,
              bytes: _comments([
                utf8.encode('METADATA_BLOCK_PICTURE=${base64.encode(picture)}'),
              ]),
            )
          else
            (type: 6, bytes: picture),
        ]),
      );
      final before = await file.readAsBytes();
      await expectLater(
        addMissingFlacTags(
          file,
          {AudioField.artwork: 'new'},
          Uint8List.fromList([41, 42]),
          'image/png',
          replaceFields: {AudioField.artwork},
        ),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), before);
    });
  }

  test('legacy untyped cover fails closed when replacing artwork', () async {
    await writeComments(['COVERART=legacy-data']);
    final before = await file.readAsBytes();
    await expectLater(
      addMissingFlacTags(
        file,
        {AudioField.artwork: 'new'},
        Uint8List.fromList([41, 42]),
        'image/png',
        replaceFields: {AudioField.artwork},
      ),
      throwsFormatException,
    );
    expect(await file.readAsBytes(), before);
  });

  test('malformed comment tail fails closed before writing', () async {
    await file.writeAsBytes(
      _flac([
        (type: 4, bytes: Uint8List.fromList([..._comments([]), 1])),
      ]),
    );
    final before = await file.readAsBytes();
    await expectLater(
      addMissingFlacTags(file, {AudioField.title: 'New'}, null, null),
      throwsFormatException,
    );
    expect(await file.readAsBytes(), before);
  });
}
