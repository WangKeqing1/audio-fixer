import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/sources/track_search.dart';
import 'package:flutter_test/flutter_test.dart';

AudioTrack _file(String name, {String? title, String? artist}) => AudioTrack(
  id: name,
  fileName: name,
  sizeBytes: 1,
  importedAt: DateTime(2026),
  title: title,
  artist: artist,
);

void main() {
  test('punctuation-only artist credits do not count as matching evidence', () {
    const query = TrackSearch(title: 'Song', artist: '---');
    expect(query.matchesArtist(['...']), isFalse);
  });

  test('cache keys retain punctuation and exact duration', () {
    const first = TrackSearch(title: 'A/B', durationSeconds: 180.001);
    const punctuation = TrackSearch(title: 'AB', durationSeconds: 180.001);
    const duration = TrackSearch(title: 'A/B', durationSeconds: 180.002);
    expect(first.key, isNot(punctuation.key));
    expect(first.key, isNot(duration.key));
  });

  test('numeric song names remain intact while explicit track prefixes can be removed', () {
    expect(TrackSearch.fromTrack(_file('21 Guns.mp3')).title, '21 Guns');
    expect(
      TrackSearch.fromTrack(_file('01. Artist - Song.flac')).title,
      'Song',
    );
    expect(
      TrackSearch.fromTrack(_file('Artist - Song.mp3', artist: 'Artist')).title,
      'Song',
    );
  });

  test('tags take priority and version names retain identity', () {
    final query = TrackSearch.fromTrack(
      _file('unrelated.mp3', title: '中文歌曲 (Live)', artist: '歌手'),
    );
    expect(query.matchesTitle('中文歌曲（Live）'), isTrue);
    expect(query.matchesTitle('中文歌曲'), isFalse);
    expect(query.matchesArtist(['其他歌手']), isFalse);
  });
}
