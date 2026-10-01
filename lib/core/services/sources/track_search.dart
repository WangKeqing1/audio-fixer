import 'package:path/path.dart' as p;

import '../../models/audio_track.dart';

class TrackSearch {
  const TrackSearch({
    required this.title,
    this.artist,
    this.album,
    this.durationSeconds,
  });
  final String title;
  final String? artist;
  final String? album;
  final double? durationSeconds;

  factory TrackSearch.fromTrack(AudioTrack track) {
    var title = track.title?.trim() ?? '';
    var artist = track.artist?.trim();
    if (title.isEmpty) {
      title = p
          .basenameWithoutExtension(track.fileName)
          .replaceFirst(RegExp(r'^\d{1,3}\s*[._-]\s*'), '')
          .trim();
      final separator = title.indexOf(' - ');
      if (separator > 0) {
        final prefix = title.substring(0, separator).trim();
        if (!hasText(artist) ||
            normalizedIdentity(prefix) == normalizedIdentity(artist!)) {
          if (!hasText(artist)) artist = prefix;
          title = title.substring(separator + 3).trim();
        }
      }
    }
    return TrackSearch(
      title: title,
      artist: hasText(artist) ? artist : null,
      album: hasText(track.album) ? track.album!.trim() : null,
      durationSeconds: (track.durationMs ?? 0) > 0
          ? track.durationMs! / 1000
          : null,
    );
  }

  String get key => [
    normalizedIdentity(title),
    normalizedIdentity(artist ?? ''),
    normalizedIdentity(album ?? ''),
    durationSeconds?.toStringAsFixed(2) ?? '',
  ].join('|');

  bool matchesTitle(String candidate) =>
      normalizedIdentity(title).isNotEmpty &&
      normalizedIdentity(title) == normalizedIdentity(candidate);

  bool matchesArtist(Iterable<String> candidates) =>
      artist == null ||
      candidates.any(
        (candidate) =>
            normalizedIdentity(artist!) == normalizedIdentity(candidate),
      );

  bool matchesDuration(double? candidate, {double tolerance = 3}) =>
      durationSeconds == null ||
      (candidate != null && (durationSeconds! - candidate).abs() <= tolerance);
}

// Keep words such as live/remix/instrumental: they identify different versions.
String normalizedIdentity(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
