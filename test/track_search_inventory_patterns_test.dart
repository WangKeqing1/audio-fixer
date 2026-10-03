import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/sources/track_search.dart';
import 'package:flutter_test/flutter_test.dart';

AudioTrack _track(String fileName, {String? title, String? artist}) =>
    AudioTrack(
      id: 'synthetic',
      fileName: fileName,
      sizeBytes: 1,
      importedAt: DateTime(2026),
      title: title,
      artist: artist,
    );

void main() {
  test('recording and timestamp names do not fabricate artist credits', () {
    for (final name in [
      '微信-测试联系人-20250102030405',
      '微信-测试联系人',
      'WeChat - Example - 20250102030405',
      '标准录音 1',
      'Record_2025-01-02-03-04-05_example',
      '测试名称-20250102030405',
      '测试名称-另一片段-2501020304',
      '1-2501020304',
      '03. 示例歌手 - 示例片段_25-01-02_03-04-05-123',
    ]) {
      final query = TrackSearch.fromTrack(_track('$name.mp3'));
      expect(query.artist, isNull, reason: name);
      expect(query.title, name, reason: name);
      expect(
        query.normalizationNotes.any((note) => note.contains('未推测歌手')),
        isTrue,
        reason: name,
      );
    }
  });

  test('filename-like embedded recording names receive the same guard', () {
    final query = TrackSearch.fromTrack(
      _track('unrelated.mp3', title: '微信-测试联系人-20250102030405.aac'),
    );
    expect(query.title, '微信-测试联系人-20250102030405');
    expect(query.artist, isNull);
  });

  test(
    'clean embedded tags take precedence over recording-shaped filenames',
    () {
      final query = TrackSearch.fromTrack(
        _track(
          '微信-测试联系人-20250102030405.mp3',
          title: 'Song 20250102030405',
          artist: 'Singer',
        ),
      );
      expect(query.title, 'Song 20250102030405');
      expect(query.artist, 'Singer');
      expect(query.normalizationNotes, isEmpty);
    },
  );

  test('Japanese tight filenames can provide artist and title query hints', () {
    for (final name in ['架空みどり-ひかりの歌', 'カナタ_夜のうた', '星野あおい-星の歌']) {
      final expected = name.split(RegExp('[-_]'));
      final query = TrackSearch.fromTrack(_track('$name.wav'));
      expect(query.artist, expected[0]);
      expect(query.title, expected[1]);
      expect(
        query.normalizationNotes.any((note) => note.contains('推测')),
        isTrue,
      );
    }
    expect(TrackSearch.fromTrack(_track('AC-DC.mp3')).artist, isNull);
    expect(TrackSearch.fromTrack(_track('Love-Hate.mp3')).title, 'Love-Hate');
  });

  test('Japanese separators respect embedded title and existing artist', () {
    final embedded = TrackSearch.fromTrack(
      _track('unrelated.mp3', title: 'ひかり-かげ'),
    );
    expect(embedded.title, 'ひかり-かげ');
    expect(embedded.artist, isNull);
    final known = TrackSearch.fromTrack(
      _track('架空みどり-ひかりの歌.wav', artist: '架空みどり'),
    );
    expect(known.title, 'ひかりの歌');
    expect(known.artist, '架空みどり');
    final conflict = TrackSearch.fromTrack(
      _track('架空みどり-ひかりの歌.wav', artist: '別の歌手'),
    );
    expect(conflict.title, '架空みどり-ひかりの歌');
    expect(conflict.artist, '別の歌手');
  });

  test('numbered series prefixes become visible filename guesses only', () {
    final track = _track('047.【架空の物語】架空歌手 - 星の歌 (Live).flac');
    final original = track.toJson();
    final query = TrackSearch.fromTrack(track);
    expect(query.artist, '架空歌手');
    expect(query.title, '星の歌 (Live)');
    expect(query.album, isNull);
    expect(query.matchesTitle('星の歌'), isFalse);
    expect(
      query.normalizationNotes.any((note) => note.contains('未作专辑')),
      isTrue,
    );
    expect(track.toJson(), original);
  });

  test('unknown brackets outside the narrow numbered series shape survive', () {
    for (final entry in <String, String?>{
      '【架空企划】歌手 - 歌曲.mp3': '【架空企划】歌手',
      '01. [Artist Group] Guest - Song.mp3': '[Artist Group] Guest',
      '01. 【Live】Singer - Song.mp3': null,
      '01. 【FLAC】Singer - Song.mp3': '【FLAC】Singer',
      '01. 【歌手：Singer】Guest - Song.mp3': '【歌手：Singer】Guest',
      '01. 【First】【Second】Singer - Song.mp3': '【First】【Second】Singer',
      '01. 【First】 【Second】Singer - Song.mp3': '【First】 【Second】Singer',
    }.entries) {
      final query = TrackSearch.fromTrack(_track(entry.key));
      expect(query.artist, entry.value, reason: entry.key);
      if (entry.value == null) {
        expect(query.title, '【Live】Singer - Song');
      }
      expect(query.album, isNull);
      expect(
        query.normalizationNotes.any((note) => note.contains('未作专辑')),
        isFalse,
      );
    }
    final song = TrackSearch.fromTrack(_track('047.【架空物語】歌だけ.mp3'));
    expect(song.title, '【架空物語】歌だけ');
    expect(song.artist, isNull);
    final ambiguous = TrackSearch.fromTrack(
      _track('047.【架空物語】Singer - Song - Album.mp3'),
    );
    expect(ambiguous.title, '【架空物語】Singer - Song - Album');
    expect(ambiguous.artist, isNull);
  });

  test('existing embedded artist is not replaced by a source-prefix guess', () {
    final query = TrackSearch.fromTrack(
      _track('047.【架空物語】Other - Song.mp3', artist: 'Known Singer'),
    );
    expect(query.artist, 'Known Singer');
    expect(query.title, '【架空物語】Other - Song');
  });
}
