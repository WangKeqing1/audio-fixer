import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/export/audio_payload.dart';
import 'package:audio_fixer/core/services/export/mp4_tag_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
List<int> _u64(int value) =>
    (ByteData(8)..setUint64(0, value)).buffer.asUint8List();
List<int> _box(String type, List<int> payload) => [
  _u32(payload.length + 8),
  type.codeUnits,
  payload,
].expand((bytes) => bytes).toList();
List<int> _full(String type, List<int> payload) =>
    _box(type, [0, 0, 0, 0, ...payload]);

List<int> _flac({
  int rateByte = 0x0a,
  List<int> comments = const [],
  bool duplicateStreamInfo = false,
}) {
  final streamInfo = List<int>.filled(34, 0)..[10] = rateByte;
  final extra = duplicateStreamInfo
      ? [0x80, 0, 0, 34, ...streamInfo]
      : [0x84, 0, 0, comments.length, ...comments];
  return [
    'fLaC'.codeUnits,
    [0, 0, 0, 34],
    streamInfo,
    extra,
    [0xff, 0xf8, 1, 2, 3, 4],
  ].expand((bytes) => bytes).toList();
}

List<int> _mp4({
  bool frontMovie = false,
  int padding = 0,
  bool wideOffsets = false,
  int chunkShift = 0,
  int codecValue = 44100,
  int timingValue = 1024,
  int sampleSize = 4,
  bool externalReference = false,
  bool fragmented = false,
  int metadataValue = 1,
  int audioValue = 42,
  String? existingLyrics,
  bool duplicateLyrics = false,
  int lyricEncoding = 1,
}) {
  final ftyp = _box('ftyp', [
    ...'M4A '.codeUnits,
    0,
    0,
    0,
    0,
    ...'isom'.codeUnits,
  ]);
  final free = padding == 0 ? <int>[] : _box('free', List.filled(padding, 0));
  final media = _box('mdat', [audioValue, 2, 3, 4]);
  List<int> movie(int chunkOffset) {
    final reference = _box('url ', [0, 0, 0, externalReference ? 0 : 1]);
    final dinf = _box('dinf', _full('dref', [..._u32(1), ...reference]));
    final entry = _box('mp4a', [0, 0, 0, 0, 0, 0, 0, 1, ..._u32(codecValue)]);
    final stbl = _box('stbl', [
      ..._full('stsd', [..._u32(1), ...entry]),
      ..._full('stts', [..._u32(1), ..._u32(1), ..._u32(timingValue)]),
      ..._full('stsc', [..._u32(1), ..._u32(1), ..._u32(1), ..._u32(1)]),
      ..._full('stsz', [..._u32(sampleSize), ..._u32(1)]),
      ..._full(wideOffsets ? 'co64' : 'stco', [
        ..._u32(1),
        ...(wideOffsets ? _u64(chunkOffset) : _u32(chunkOffset)),
      ]),
    ]);
    final minf = _box('minf', [
      ..._full('smhd', [0, 0, 0, 0]),
      ...dinf,
      ...stbl,
    ]);
    final mdia = _box('mdia', [
      ..._full('mdhd', List.filled(20, 0)),
      ..._full('hdlr', [
        0,
        0,
        0,
        0,
        ...'soun'.codeUnits,
        ...List.filled(12, 0),
      ]),
      ...minf,
    ]);
    final track = _box('trak', [..._full('tkhd', List.filled(80, 0)), ...mdia]);
    return _box('moov', [
      ..._full('mvhd', List.filled(96, 0)),
      ...track,
      ..._box(
        'udta',
        _full('meta', [
          ..._full('hdlr', [
            0,
            0,
            0,
            0,
            ...'mdir'.codeUnits,
            ...List.filled(12, 0),
          ]),
          ..._box('ilst', [
            ..._box(
              '©too',
              _box('data', [
                ..._u32(1),
                ..._u32(0),
                ...'existing encoder $metadataValue'.codeUnits,
              ]),
            ),
            if (existingLyrics != null)
              ..._box(
                '©lyr',
                _box('data', [
                  ..._u32(lyricEncoding),
                  ..._u32(0),
                  ...utf8.encode(existingLyrics),
                ]),
              ),
            if (duplicateLyrics)
              ..._box(
                '©lyr',
                _box('data', [
                  ..._u32(1),
                  ..._u32(0),
                  ...utf8.encode(existingLyrics ?? ''),
                ]),
              ),
          ]),
        ]),
      ),
      if (fragmented) ..._box('mvex', []),
    ]);
  }

  final provisional = movie(0);
  final chunk =
      ftyp.length +
      free.length +
      (frontMovie ? provisional.length : 0) +
      8 +
      chunkShift;
  final moov = movie(chunk);
  return [
    ...ftyp,
    ...free,
    if (frontMovie) ...moov,
    ...media,
    if (!frontMovie) ...moov,
  ];
}

void main() {
  late Directory temporary;
  var counter = 0;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('audio_payload_test_');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  Future<String> fingerprint(List<int> bytes, String extension) async {
    final file = File('${temporary.path}/${counter++}.$extension');
    await file.writeAsBytes(bytes);
    return audioPayloadDigest(file, extension);
  }

  test('MP4 overlay preserves raw existing tags and media offsets', () async {
    for (final frontMovie in [false, true]) {
      final file = File('${temporary.path}/overlay-$frontMovie.m4a');
      await file.writeAsBytes(_mp4(frontMovie: frontMovie));
      final before = await audioPayloadDigest(file, 'm4a');
      await addMissingMp4Tags(file, {AudioField.lyrics: '新的歌词'}, null, null);
      expect(await audioPayloadDigest(file, 'm4a'), before);
      expect(
        String.fromCharCodes(await file.readAsBytes()),
        contains('existing encoder 1'),
      );
      final saved = await file.readAsBytes();
      await expectLater(
        addMissingMp4Tags(
          file,
          {AudioField.lyrics: 'Do not overwrite'},
          null,
          null,
        ),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), saved);
    }
  });

  test('MP4 overlay replaces only one verified blank UTF-8 text atom', () async {
    final file = File('${temporary.path}/blank.m4a');
    await file.writeAsBytes(_mp4(existingLyrics: '  \n '));
    final before = await audioPayloadDigest(file, 'm4a');
    await addMissingMp4Tags(file, {AudioField.lyrics: '新的歌词'}, null, null);
    expect(await audioPayloadDigest(file, 'm4a'), before);
    final bytes = await file.readAsBytes();
    // Old moov is padding; the active appended moov contains exactly one value.
    expect(utf8.decode(bytes, allowMalformed: true), contains('新的歌词'));
  });

  test(
    'MP4 blank duplicates and unsupported text encodings remain protected',
    () async {
      for (final bytes in [
        _mp4(existingLyrics: ' ', duplicateLyrics: true),
        _mp4(existingLyrics: ' ', lyricEncoding: 2),
      ]) {
        final file = File('${temporary.path}/protected-${counter++}.m4a');
        await file.writeAsBytes(bytes);
        await expectLater(
          addMissingMp4Tags(
            file,
            {AudioField.lyrics: 'New lyrics'},
            null,
            null,
          ),
          throwsFormatException,
        );
        expect(await file.readAsBytes(), bytes);
      }
    },
  );

  test(
    'MP4 overlay closes a to-EOF mdat before appending its new moov',
    () async {
      final file = File('${temporary.path}/to-eof.m4a');
      final bytes = _mp4(frontMovie: true);
      bytes.setRange(bytes.length - 12, bytes.length - 8, [0, 0, 0, 0]);
      await file.writeAsBytes(bytes);
      final before = await audioPayloadDigest(file, 'm4a');
      await addMissingMp4Tags(
        file,
        {AudioField.title: 'New title'},
        null,
        null,
      );
      expect(await audioPayloadDigest(file, 'm4a'), before);
    },
  );

  test(
    'FLAC tag growth is allowed but STREAMINFO decoding changes are detected',
    () async {
      final baseline = await fingerprint(_flac(comments: [1]), 'flac');
      expect(
        await fingerprint(_flac(comments: [2, 3, 4, 5]), 'flac'),
        baseline,
      );
      expect(await fingerprint(_flac(rateByte: 0x0b), 'flac'), isNot(baseline));
    },
  );

  test('FLAC duplicated or missing STREAMINFO fails closed', () async {
    await expectLater(
      fingerprint(_flac(duplicateStreamInfo: true), 'flac'),
      throwsFormatException,
    );
    final missing = _flac()..[4] = 1;
    await expectLater(fingerprint(missing, 'flac'), throwsFormatException);
  });

  test('MP4 preserves audio identity across moov relocation, padding and tag changes', () async {
    final baseline = await fingerprint(_mp4(), 'm4a');
    expect(
      await fingerprint(
        _mp4(frontMovie: true, padding: 64, metadataValue: 2),
        'm4a',
      ),
      baseline,
    );
  });

  test(
    'MP4 stco to co64 conversion retains normalized chunk identity',
    () async {
      final baseline = await fingerprint(_mp4(frontMovie: true), 'm4a');
      expect(
        await fingerprint(_mp4(frontMovie: true, wideOffsets: true), 'm4a'),
        baseline,
      );
    },
  );

  test(
    'MP4 codec, timing, sample sizes and chunk pointers affect the digest',
    () async {
      final baseline = await fingerprint(_mp4(), 'm4a');
      for (final changed in [
        _mp4(codecValue: 48000),
        _mp4(timingValue: 2048),
        _mp4(sampleSize: 3),
        _mp4(chunkShift: 1),
        _mp4(audioValue: 43),
      ]) {
        expect(await fingerprint(changed, 'm4a'), isNot(baseline));
      }
    },
  );

  test(
    'MP4 external references, fragments and out-of-range pointers fail closed',
    () async {
      for (final unsupported in [
        _mp4(externalReference: true),
        _mp4(fragmented: true),
        _mp4(chunkShift: -1),
        _mp4(chunkShift: 4),
        _box('mdat', [1, 2, 3]),
      ]) {
        await expectLater(
          fingerprint(unsupported, 'm4a'),
          throwsFormatException,
        );
      }
    },
  );

  test('malformed MP4 box sizes cannot escape container bounds', () async {
    final malformed = _mp4();
    malformed.setRange(0, 4, _u32(malformed.length + 1));
    await expectLater(fingerprint(malformed, 'mp4'), throwsFormatException);
  });

  test(
    'MP3 ID3v2.4 footer must match its header before being excluded',
    () async {
      final audio = [0xff, 0xfb, 1, 2, 3, 4];
      final header = [...'ID3'.codeUnits, 4, 0, 0x10, 0, 0, 0, 0];
      final footer = [...'3DI'.codeUnits, ...header.sublist(3)];
      final baseline = await fingerprint(audio, 'mp3');
      expect(
        await fingerprint([...header, ...footer, ...audio], 'mp3'),
        baseline,
      );
      footer[5] = 0;
      await expectLater(
        fingerprint([...header, ...footer, ...audio], 'mp3'),
        throwsFormatException,
      );
    },
  );
}
