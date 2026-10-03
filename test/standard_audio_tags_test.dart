import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_fixer/core/models/audio_field_validation.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/audio_tag_reader.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/services/standard_audio_tags.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _DraftExporter implements AudioCopyExporter {
  @override
  bool supports(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async => null;
}

AudioTrack _track() => AudioTrack(
  id: 'standard-tags',
  fileName: 'fixture.mp3',
  sizeBytes: 2000,
  importedAt: DateTime(2026),
  title: 'Title',
  artist: 'Artist',
  album: 'Album',
  albumArtist: 'Album artist',
  year: 2024,
  genre: 'Rock / Pop',
  trackNumber: 3,
  trackTotal: 12,
  discNumber: 1,
  discTotal: 2,
  composer: 'Composer',
  comment: 'Comment',
  lyrics: 'Lyrics',
  artworkPath: '/fixture/cover',
  artworkSha256: 'old-digest',
  tagReadWarnings: const ['Preserved warning'],
);

List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
List<int> _sync(int value) => [
  (value >> 21) & 127,
  (value >> 14) & 127,
  (value >> 7) & 127,
  value & 127,
];
List<int> _frame(String id, List<int> data, {int version = 3, int flags = 0}) =>
    [
      ...ascii.encode(id),
      ...(version == 4 ? _sync(data.length) : _u32(data.length)),
      0,
      flags,
      ...data,
    ];
List<int> _id3(List<int> frames, {int version = 3}) => [
  ...ascii.encode('ID3'),
  version,
  0,
  0,
  ..._sync(frames.length),
  ...frames,
];
List<int> _utf16(String value, {bool little = false, bool bom = true}) => [
  if (bom) ...(little ? [0xff, 0xfe] : [0xfe, 0xff]),
  for (final unit in value.codeUnits)
    ...(little ? [unit & 255, unit >> 8] : [unit >> 8, unit & 255]),
];
List<int> _atom(String type, List<int> data) => [
  ..._u32(data.length + 8),
  ...latin1.encode(type),
  ...data,
];
List<int> _mp4Tag(String type, List<int> value, {int format = 1}) =>
    _atom(type, _atom('data', [..._u32(format), ..._u32(0), ...value]));
List<int> _mp4(List<int> tags) => _atom(
  'moov',
  _atom('udta', _atom('meta', [0, 0, 0, 0, ..._atom('ilst', tags)])),
);

List<int> _vorbisComments(List<String> entries) {
  List<int> size(int value) =>
      (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
  return [
    ...size(4),
    ...ascii.encode('test'),
    ...size(entries.length),
    for (final entry in entries) ...[
      ...size(utf8.encode(entry).length),
      ...utf8.encode(entry),
    ],
  ];
}

void _replaceFlacComments(File file, List<String> entries) {
  final bytes = file.readAsBytesSync();
  final out = BytesBuilder()..add(bytes.sublist(0, 4));
  var cursor = 4;
  var last = false;
  while (!last) {
    final type = bytes[cursor];
    last = type & 0x80 != 0;
    final size =
        (bytes[cursor + 1] << 16) |
        (bytes[cursor + 2] << 8) |
        bytes[cursor + 3];
    if (type & 0x7f == 4) {
      final data = _vorbisComments(entries);
      out.add([
        type,
        data.length >> 16,
        (data.length >> 8) & 255,
        data.length & 255,
      ]);
      out.add(data);
    } else {
      out.add(bytes.sublist(cursor, cursor + 4 + size));
    }
    cursor += 4 + size;
  }
  out.add(bytes.sublist(cursor));
  file.writeAsBytesSync(out.takeBytes());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy parsed caches require refresh while new constructed tracks remain current', () {
    final current = _track();
    expect(current.tagReadVersion, AudioTrack.currentTagReadVersion);
    expect(current.requiresTagRefresh, isFalse);
    final legacyJson = current.withInstrumental(true).toJson()
      ..remove('tagReadVersion');
    final legacy = AudioTrack.fromJson(legacyJson);
    expect(legacy.detailsLoaded, isTrue);
    expect(legacy.tagReadVersion, 0);
    expect(legacy.requiresTagRefresh, isTrue);
    for (final copy in [
      legacy.withInstrumental(false),
      legacy.withReadError('Cannot read yet'),
      legacy.withDetails(
        title: legacy.title,
        artist: legacy.artist,
        album: legacy.album,
        year: legacy.year,
        durationMs: legacy.durationMs,
        lyrics: legacy.lyrics,
        artworkPath: legacy.artworkPath,
      ),
      AudioTrack.fromJson(legacy.toJson()),
    ]) {
      expect(copy.tagReadVersion, 0);
      expect(copy.requiresTagRefresh, isTrue);
    }
    expect(legacy.withReadError('Cannot read yet').isInstrumental, isTrue);
    expect(
      AudioTrack.fromJson({...legacyJson, 'detailsLoaded': false})
          .requiresTagRefresh,
      isFalse,
    );
    expect(AudioTrack.fromJson(current.toJson()).requiresTagRefresh, isFalse);
  });
  test(
    'optional fields round-trip and remain optional completion criteria',
    () {
      final track = _track();
      final restored = AudioTrack.fromJson(track.toJson());
      for (final field in AudioField.values) {
        expect(restored.valueOf(field), track.valueOf(field));
      }
      expect(restored.artworkSha256, 'old-digest');
      expect(restored.tagReadWarnings, ['Preserved warning']);
      expect(track.missingFields, isEmpty);
      final oldCatalog = track.toJson();
      for (final field in AudioField.metadataFields.difference(
        AudioField.coreFields,
      )) {
        oldCatalog.remove(field.name);
      }
      oldCatalog.remove('artworkSha256');
      oldCatalog.remove('tagReadWarnings');
      final old = AudioTrack.fromJson(oldCatalog);
      expect(old.needsCompletion, isFalse);
      expect(old.albumArtist, isNull);
      expect(old.year, isNull);
      expect(old.tagReadWarnings, isEmpty);
    },
  );

  test(
    'copy helpers preserve extras, explicit null rereads clear vanished tags',
    () {
      final track = _track();
      for (final copy in [
        track.withReadError('Unreadable'),
        track.withInstrumental(true),
        track.withDetails(
          title: track.title,
          artist: track.artist,
          album: track.album,
          year: track.year,
          durationMs: null,
          lyrics: track.lyrics,
          artworkPath: track.artworkPath,
        ),
      ]) {
        for (final field in AudioField.metadataFields) {
          expect(copy.valueOf(field), track.valueOf(field));
        }
        expect(copy.artworkSha256, track.artworkSha256);
        expect(copy.tagReadWarnings, track.tagReadWarnings);
      }
      final reread = track.withDetails(
        title: track.title,
        artist: track.artist,
        album: track.album,
        year: null,
        durationMs: null,
        lyrics: track.lyrics,
        artworkPath: null,
        artworkSha256: null,
        albumArtist: null,
        genre: null,
        trackNumber: null,
        trackTotal: null,
        discNumber: null,
        discTotal: null,
        composer: null,
        comment: null,
        tagReadWarnings: [],
      );
      expect(reread.albumArtist, isNull);
      expect(reread.trackTotal, isNull);
      expect(reread.comment, isNull);
      expect(reread.artworkSha256, isNull);
      expect(reread.tagReadWarnings, isEmpty);
    },
  );

  test('field validation rejects deletion, hidden NUL, oversized values and invalid counters', () {
    expect(validateAudioFieldValue(AudioField.title, ' \n'), isNotNull);
    expect(validateAudioFieldValue(AudioField.comment, 'a\x00b'), isNotNull);
    expect(validateAudioFieldValue(AudioField.artist, 'a' * 4097), isNotNull);
    for (final field in AudioField.numericFields) {
      for (final value in ['0', '-1', '1/2', '1.5', '65536', '1e2']) {
        expect(validateAudioFieldValue(field, value), isNotNull);
      }
    }
    expect(validateAudioFieldValue(AudioField.year, '10000'), isNotNull);
    expect(validateAudioFieldValue(AudioField.trackNumber, '65535'), isNull);
    expect(
      validateAudioFieldChanges(_track(), {AudioField.trackNumber: '13'}),
      isNotNull,
    );
    expect(
      validateAudioFieldChanges(_track(), {AudioField.discTotal: '1'}),
      isNull,
    );
    expect(
      validateAudioFieldChanges(_track(), {
        AudioField.trackNumber: '13',
        AudioField.trackTotal: '20',
      }),
      isNull,
    );
  });

  group('bounded standard-tag readers', () {
    late Directory directory;
    setUp(
      () async =>
          directory = await Directory.systemTemp.createTemp('standard_tags_'),
    );
    tearDown(() async => directory.delete(recursive: true));
    File write(String name, List<int> bytes) =>
        File('${directory.path}/$name')..writeAsBytesSync(bytes);

    for (final version in [3, 4]) {
      for (final encoding in [0, 1, 2, 3]) {
        test(
          'ID3v2.$version COMM encoding $encoding reads only the standard comment',
          () {
            final expected = encoding == 0 ? 'Café note' : '备注 Café';
            List<int> encode(String value) => switch (encoding) {
              0 => latin1.encode(value),
              1 => _utf16(value, little: true),
              2 => _utf16(value, bom: false),
              _ => utf8.encode(value),
            };
            List<int> comment(String description, String value) => [
              encoding,
              ...ascii.encode('eng'),
              ...encode(description),
              ...((encoding == 1 || encoding == 2) ? [0, 0] : [0]),
              ...encode(value),
            ];
            final file = write(
              'comm.mp3',
              _id3([
                ..._frame(
                  'COMM',
                  comment('Vendor private', 'Retained custom note'),
                  version: version,
                ),
                ..._frame('COMM', comment('', expected), version: version),
              ], version: version),
            );
            final tags = readStandardAudioTags(file, metadata: Mp3Metadata());
            expect(tags.comment, expected);
            expect(tags.warnings.single, contains('自定义描述'));
          },
        );
      }
    }

    test('unsupported COMM flags and truncation report a warning without inventing text', () {
      final file = write(
        'compressed.mp3',
        _id3([
          ..._frame('COMM', [
            3,
            ...ascii.encode('eng'),
            0,
            ...utf8.encode('Opaque'),
          ], flags: 8),
        ]),
      );
      final tags = readStandardAudioTags(file, metadata: Mp3Metadata());
      expect(tags.comment, isNull);
      expect(tags.warnings, isNotEmpty);
      file.writeAsBytesSync(_id3(_frame('COMM', [3, 101])));
      expect(
        readStandardAudioTags(file, metadata: Mp3Metadata()).warnings,
        isNotEmpty,
      );
    });

    test('MP4 extended tags support UTF8, UTF16 and repeated values with a warning', () {
      final file = write(
        'tags.m4a',
        _mp4([
          ..._mp4Tag('aART', utf8.encode('专辑歌手')),
          ..._mp4Tag('©wrt', _utf16('作曲者', bom: false), format: 2),
          ..._mp4Tag('©cmt', utf8.encode('First comment')),
          ..._mp4Tag('©cmt', utf8.encode('Second comment')),
        ]),
      );
      final tags = readStandardAudioTags(file, metadata: Mp4Metadata());
      expect(tags.albumArtist, '专辑歌手');
      expect(tags.composer, '作曲者');
      expect(tags.comment, 'First comment; Second comment');
      expect(tags.warnings.single, contains('多个值'));
    });

    test('unknown MP4 text encoding produces an explicit read warning', () {
      final file = write(
        'unknown.m4a',
        _mp4(_mp4Tag('aART', [1, 2, 3], format: 99)),
      );
      final tags = readStandardAudioTags(file, metadata: Mp4Metadata());
      expect(tags.albumArtist, isNull);
      expect(tags.warnings.single, contains('暂不支持'));
    });

    test('Vorbis repeated values are shown without losing the distinction silently', () {
      final file = write('nonflac.ogg', [0, 1, 2, 3]);
      final metadata = VorbisMetadata()
        ..albumArtist = ['First artist', 'Second artist']
        ..composer = ['Composer A', 'Composer B']
        ..comment = ['A', 'B'];
      final tags = readStandardAudioTags(file, metadata: metadata);
      expect(tags.albumArtist, 'First artist; Second artist');
      expect(tags.composer, 'Composer A; Composer B');
      expect(tags.warnings, hasLength(3));
    });
  });

  group('actual encoded metadata', () {
    late Directory directory;
    var ffmpegReady = false;
    try {
      ffmpegReady = Process.runSync('ffmpeg', ['-version']).exitCode == 0;
    } on ProcessException {
      // Keep non-media model/encoding coverage runnable on minimal hosts.
    }
    setUp(
      () async => directory = await Directory.systemTemp.createTemp(
        'encoded_standard_tags_',
      ),
    );
    tearDown(() async => directory.delete(recursive: true));

    Future<File> flacWithAliases(List<String> entries) async {
      final file = File('${directory.path}/aliases.flac');
      final result = await Process.run('ffmpeg', [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=0.1',
        file.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      _replaceFlacComments(file, [
        'TITLE=Alias fixture',
        'ARTIST=Artist',
        'ALBUM=Album',
        ...entries,
      ]);
      return file;
    }

    for (final trackKey in ['TRACK', 'ITUNES_CDDB_TRACKNUMBER']) {
      test(
        'FLAC $trackKey and noncanonical aliases can be read, reviewed and repaired',
        () async {
          final source = await flacWithAliases([
            'YEAR=1999',
            'ALBUM ARTIST=Old album artist',
            '$trackKey=3/12',
            'DISC=1/2',
            'UNSYNCEDLYRICS=Old lyrics',
          ]);
          final before = sha256.convert(source.readAsBytesSync());
          final original = await readTrackTags(
            AudioTrack(
              id: 'alias-file',
              fileName: 'aliases.flac',
              localPath: source.path,
              sizeBytes: source.lengthSync(),
              importedAt: DateTime(2026),
            ),
            source.path,
            directory.path,
          );
          expect(original.readError, isNull);
          expect(original.year, 1999);
          expect(original.albumArtist, 'Old album artist');
          expect(original.trackNumber, 3);
          expect(original.trackTotal, 12);
          expect(original.discNumber, 1);
          expect(original.discTotal, 2);
          expect(original.lyrics, 'Old lyrics');
          final controller = LibraryController(
            store: MemoryStore(LibrarySnapshot(tracks: [original])),
            picker: FakePicker(),
            importer: FakeImporter(),
            completion: CompletionService(),
            exporter: _DraftExporter(),
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          final values = {
            AudioField.year: '2000',
            AudioField.albumArtist: 'New album artist',
            AudioField.trackNumber: '4',
            AudioField.discNumber: '2',
            AudioField.lyrics: 'New lyrics',
          };
          final draft = await controller.createManualRepair(
            original.id,
            values,
          );
          expect(draft, isNotNull);
          expect(
            draft!.suggestions.every((candidate) => candidate.replaceExisting),
            isTrue,
          );
          final output = File('${directory.path}/repaired.flac');
          await prepareTaggedCopy(
            sourcePath: source.path,
            outputPath: output.path,
            extension: 'flac',
            values: values,
            artwork: null,
            expectedTrack: original,
            replaceFields: draft.suggestions
                .where((candidate) => candidate.replaceExisting)
                .map((candidate) => candidate.field)
                .toSet(),
          );
          final actual = readStandardAudioTags(output);
          for (final entry in values.entries) {
            expect(actual.valueOf(entry.key), entry.value);
          }
          expect(actual.trackTotal, 12);
          expect(actual.discTotal, 2);
          expect(sha256.convert(source.readAsBytesSync()), before);
        },
        skip: ffmpegReady ? false : 'Requires optional offline FFmpeg encoder',
      );
    }

    test('conflicting FLAC aliases warn and an ambiguous paired repair fails closed', () async {
      final source = await flacWithAliases([
        'DATE=1999',
        'YEAR=2000',
        'TRACK=3/12',
        'ITUNES_CDDB_TRACKNUMBER=3/13',
      ]);
      final before = sha256.convert(source.readAsBytesSync());
      final original = await readTrackTags(
        AudioTrack(
          id: 'alias-conflict',
          fileName: 'aliases.flac',
          localPath: source.path,
          sizeBytes: source.lengthSync(),
          importedAt: DateTime(2026),
        ),
        source.path,
        directory.path,
      );
      expect(original.readError, isNull);
      expect(original.year, 1999);
      expect(original.trackTotal, 12);
      expect(
        original.tagReadWarnings.where((warning) => warning.contains('冲突')),
        hasLength(2),
      );
      final output = File('${directory.path}/refused.flac');
      await expectLater(
        prepareTaggedCopy(
          sourcePath: source.path,
          outputPath: output.path,
          extension: 'flac',
          values: {AudioField.trackNumber: '4'},
          artwork: null,
          expectedTrack: original,
          replaceFields: {AudioField.trackNumber},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(output.existsSync(), isFalse);
      expect(sha256.convert(source.readAsBytesSync()), before);
    }, skip: ffmpegReady ? false : 'Requires optional offline FFmpeg encoder');

    for (final extension in ['mp3', 'flac', 'm4a']) {
      test(
        '$extension reads the full standard tag set and clears stale lyrics',
        () async {
          final file = File('${directory.path}/fixture.$extension');
          final metadata = {
            'title': '标题 Café',
            'artist': 'Track artist',
            'album': 'Album',
            'album_artist': 'Album artist',
            'date': '2024',
            'genre': 'Rock / Pop',
            'track': '3/12',
            'disc': '1/2',
            'composer': 'Composer',
            'comment': 'Comment',
          };
          final result = await Process.run('ffmpeg', [
            '-nostdin',
            '-hide_banner',
            '-loglevel',
            'error',
            '-y',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:duration=0.1',
            '-map_metadata',
            '-1',
            for (final entry in metadata.entries) ...[
              '-metadata',
              '${entry.key}=${entry.value}',
            ],
            file.path,
          ]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          final before = sha256.convert(file.readAsBytesSync()).toString();
          final seed = AudioTrack(
            id: 'encoded',
            fileName: 'fixture.$extension',
            sizeBytes: file.lengthSync(),
            importedAt: DateTime(2026),
            lyrics: 'Stale lyrics',
            tagReadVersion: 0,
          );
          final read = await readTrackTags(seed, file.path, directory.path);
          expect(read.readError, isNull);
          expect(read.tagReadVersion, AudioTrack.currentTagReadVersion);
          expect(read.requiresTagRefresh, isFalse);
          expect(read.title, metadata['title']);
          expect(read.artist, 'Track artist');
          expect(read.albumArtist, 'Album artist');
          expect(read.year, 2024);
          expect(read.genre, 'Rock / Pop');
          expect(read.trackNumber, 3);
          expect(read.trackTotal, 12);
          expect(read.discNumber, 1);
          expect(read.discTotal, 2);
          expect(read.composer, 'Composer');
          expect(read.comment, 'Comment');
          expect(read.lyrics, isNull);
          expect(sha256.convert(file.readAsBytesSync()).toString(), before);
        },
        skip: ffmpegReady ? false : 'Requires optional offline FFmpeg encoder',
      );
    }
  });
}
