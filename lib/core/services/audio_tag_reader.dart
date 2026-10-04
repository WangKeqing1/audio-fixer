import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import 'standard_audio_tags.dart';
import 'artwork_validation.dart';

// Only plain Dart values enter the isolate; native streams/handles stay outside.
Future<AudioTrack> readTrackTags(
  AudioTrack track,
  String path,
  String root,
) async {
  final read = await Isolate.run(() => _read(track, path, root));
  if (read.readError != null) return read;
  // Flutter's image codec belongs to the root isolate. Tag parsing and cache
  // extraction remain off the UI isolate, and a cover error is not a tag error.
  return validateTrackArtwork(read);
}

AudioTrack _read(AudioTrack track, String path, String root) {
  try {
    final file = File(path);
    final metadata = readMetadata(file, getImage: true);
    final standard = readStandardAudioTags(file);
    final riffTags = _readRiffUtf8Tags(file);
    String? riffText(String key, String? current) {
      final value = riffTags[key];
      return value != null && value.$1 == current ? value.$2 : current;
    }

    String? artworkPath;
    String? artworkSha256;
    String? artworkError;
    if (metadata.pictures.isNotEmpty) {
      final picture = metadata.pictures.firstWhere(
        (picture) => picture.pictureType == PictureType.coverFront,
        orElse: () => metadata.pictures.first,
      );
      artworkSha256 = sha256.convert(picture.bytes).toString();
      if (picture.bytes.isEmpty) {
        artworkError = '已读到封面标签，但图片数据为空；请手动更换封面。';
      } else {
        final directory = Directory(
          p.join(root, track.isDeviceTrack ? 'device_artwork' : 'artwork'),
        );
        directory.createSync(recursive: true);
        final key = track.isDeviceTrack
            ? sha256.convert(utf8.encode(track.id)).toString()
            : track.id;
        // FileImage keys include the path. A content-addressed filename makes
        // a repaired cover visible immediately and retains review snapshots.
        final file = File(p.join(directory.path, '$key.$artworkSha256.cover'));
        file.writeAsBytesSync(picture.bytes, flush: true);
        artworkPath = file.path;
      }
    }
    return track.withDetails(
      title: riffText('INAM', standard.title),
      artist: riffText('IART', standard.artist),
      album: riffText('IPRD', standard.album),
      albumArtist: standard.albumArtist,
      year: standard.year,
      genre: riffText('IGNR', standard.genre),
      trackNumber: standard.trackNumber,
      trackTotal: standard.trackTotal,
      discNumber: standard.discNumber,
      discTotal: standard.discTotal,
      composer: standard.composer,
      comment: riffText('ICMT', standard.comment),
      tagReadWarnings: standard.warnings,
      tagReadVersion: AudioTrack.currentTagReadVersion,
      durationMs:
          _readOpusDurationMs(file) ??
          metadata.duration?.inMilliseconds ??
          track.durationMs,
      lyrics: standard.lyrics,
      artworkPath: artworkPath,
      artworkSha256: artworkSha256,
      artworkValidated: false,
      artworkError: artworkError,
    );
  } catch (_) {
    return track.withReadError('标签读取失败，文件可能损坏或包含暂不支持的标签。');
  }
}

// RIFF INFO text has no universal encoding marker. Modern encoders commonly
// store UTF-8; the dependency currently interprets every byte as Latin-1.
// Decode only valid UTF-8 INFO values, retaining legacy bytes on invalid input
// and leaving separately parsed ID3 text alone.
Map<String, (String, String)> _readRiffUtf8Tags(File file) {
  final values = <String, (String, String)>{};
  final reader = file.openSync();
  try {
    final length = reader.lengthSync();
    if (length < 12) return values;
    final header = reader.readSync(12);
    if (String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(header.sublist(8, 12)) != 'WAVE') {
      return values;
    }
    var offset = 12;
    while (offset + 8 <= length) {
      reader.setPositionSync(offset);
      final chunk = reader.readSync(8);
      final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
      final end = offset + 8 + size;
      if (end > length) return values;
      if (String.fromCharCodes(chunk.sublist(0, 4)) == 'LIST' &&
          size >= 4 &&
          String.fromCharCodes(reader.readSync(4)) == 'INFO') {
        var textOffset = offset + 12;
        while (textOffset + 8 <= end) {
          reader.setPositionSync(textOffset);
          final textHeader = reader.readSync(8);
          final tag = String.fromCharCodes(textHeader.sublist(0, 4));
          final count = ByteData.sublistView(textHeader)
              .getUint32(4, Endian.little);
          if (textOffset + 8 + count > end) break;
          if (const {'INAM', 'IART', 'IPRD', 'IGNR', 'ICMT'}.contains(tag) &&
              count <= 1024 * 1024) {
            final bytes = reader.readSync(count);
            try {
              final decoded = utf8.decode(bytes).replaceAll('\x00', '').trim();
              final legacy = String.fromCharCodes(bytes)
                  .replaceAll('\x00', '')
                  .trim();
              values[tag] = (legacy, decoded);
            } on FormatException {
              // Unmarked older INFO tags may legitimately use Latin-1.
            }
          }
          textOffset += 8 + count + (count.isOdd ? 1 : 0);
        }
      }
      offset = end + (size.isOdd ? 1 : 0);
    }
  } on FileSystemException {
    return values;
  } finally {
    reader.closeSync();
  }
  return values;
}

// Opus granule positions always use a 48 kHz clock; OpusHead's input sample
// rate is only a hint. Subtract encoder pre-skip and retain millisecond precision.
// RFC 7845 sections 4 and 5.1: https://www.rfc-editor.org/rfc/rfc7845
// Read small page headers/lacing tables rather than loading the whole audio.
int? _readOpusDurationMs(File file) {
  final reader = file.openSync();
  try {
    final length = reader.lengthSync();
    var offset = 0;
    int? activeSerial;
    var expectedSequence = 0;
    var preSkip = 0;
    var samples = 0;
    var foundOpus = false;
    while (offset + 27 <= length) {
      reader.setPositionSync(offset);
      final header = reader.readSync(27);
      if (String.fromCharCodes(header.sublist(0, 4)) != 'OggS' ||
          header[4] != 0) {
        return null;
      }
      final page = ByteData.sublistView(header);
      final serial = page.getUint32(14, Endian.little);
      final sequence = page.getUint32(18, Endian.little);
      final segments = reader.readSync(header[26]);
      if (segments.length != header[26]) return null;
      final bodySize = segments.fold<int>(0, (sum, size) => sum + size);
      final bodyOffset = offset + 27 + segments.length;
      final next = bodyOffset + bodySize;
      if (next > length) return null;
      if (activeSerial == null) {
        if (header[5] & 0x02 == 0 || sequence != 0 || bodySize < 19) {
          return null;
        }
        final identification = reader.readSync(19);
        if (String.fromCharCodes(identification.sublist(0, 8)) != 'OpusHead') {
          return null;
        }
        preSkip = ByteData.sublistView(identification)
            .getUint16(10, Endian.little);
        activeSerial = serial;
        expectedSequence = 0;
        foundOpus = true;
      }
      // Do not guess the duration of multiplexed or discontinuous streams.
      if (serial != activeSerial || sequence != expectedSequence) return null;
      expectedSequence = (expectedSequence + 1) & 0xffffffff;
      if (header[5] & 0x04 != 0) {
        final granule = page.getInt64(6, Endian.little);
        if (granule < preSkip) return null;
        samples += granule - preSkip;
        activeSerial = null;
      }
      offset = next;
    }
    return foundOpus && activeSerial == null && offset == length
        ? samples ~/ 48
        : null;
  } on FileSystemException {
    return null;
  } finally {
    reader.closeSync();
  }
}
