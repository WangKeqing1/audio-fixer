import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/sources/track_search.dart';
import 'package:flutter_test/flutter_test.dart';

AudioTrack _file(
  String name, {
  String? title,
  String? artist,
  String? album,
  int? durationMs,
}) => AudioTrack(
  id: name,
  fileName: name,
  sizeBytes: 1,
  importedAt: DateTime(2026),
  title: title,
  artist: artist,
  album: album,
  durationMs: durationMs,
);

void main() {
  test(
    'Chinese filename separators recover artist without title-only matching',
    () {
      for (final name in [
        '周杰伦-晴天.mp3',
        '周杰伦_晴天.mp3',
        '周杰伦－晴天.mp3',
        '周杰伦 ｜ 晴天.mp3',
        '周杰伦 — 晴天.mp3',
      ]) {
        final search = TrackSearch.fromTrack(_file(name));
        expect(search.title, '晴天');
        expect(search.artist, '周杰伦');
      }
      expect(TrackSearch.fromTrack(_file('AC-DC.mp3')).artist, isNull);
      expect(
        TrackSearch.fromTrack(_file('周杰伦-晴天.mp3', artist: '其他歌手')).artist,
        '其他歌手',
      );
    },
  );

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

  test(
    'recognized technical and download suffixes are removed from both names',
    () {
      for (final polluted in [
        '晴天【无损音质】',
        '晴天 [FLAC] [320kbps]',
        '晴天 (24-bit 96kHz)',
        '晴天_320K',
        '晴天 - FLAC 24bit 96kHz',
        '晴天｜QQ音乐下载',
        '晴天 [下载来源：网易云音乐]',
        '晴天 [source: music.163.com]',
        '晴天 [codec: FLAC]',
        '晴天 [比特率：320 kbps]',
        '晴天 [www.kugou.com]',
      ]) {
        for (final embedded in [false, true]) {
          final query = TrackSearch.fromTrack(
            _file(
              embedded ? 'unrelated.mp3' : '$polluted.mp3',
              title: embedded ? polluted : null,
              artist: '周杰伦',
            ),
          );
          expect(query.title, '晴天', reason: '$polluted / $embedded');
          expect(query.artist, '周杰伦');
          expect(query.normalizationNotes, isNotEmpty);
        }
      }
    },
  );

  test('English and multi-artist query names keep the complete credit', () {
    for (final artist in ['A & B', 'A feat. B', 'A / B']) {
      for (final title in [
        '$artist - Song (Remix) [FLAC]',
        'Song (Remix) - $artist [320kbps]',
      ]) {
        final query = TrackSearch.fromTrack(
          _file('unrelated.mp3', title: title, artist: artist),
        );
        expect(query.title, 'Song (Remix)');
        expect(query.artist, artist);
        expect(query.matchesTitle('Song'), isFalse);
      }
    }
    final inferred = TrackSearch.fromTrack(
      _file('A feat. B - Song (Remix) [FLAC].mp3'),
    );
    expect(inferred.title, 'Song (Remix)');
    expect(inferred.artist, 'A feat. B');
    expect(
      inferred.normalizationNotes.any((note) => note.contains('推测')),
      isTrue,
    );
  });

  test(
    'known artist disambiguates either order without splitting song hyphens',
    () {
      for (final title in [
        '周杰伦 - 晴天 [FLAC]',
        '晴天 - 周杰伦 [320kbps]',
        '晴天_周杰伦【无损】',
      ]) {
        final query = TrackSearch.fromTrack(
          _file('unrelated.mp3', title: title, artist: '周杰伦'),
        );
        expect(query.title, '晴天');
        expect(query.artist, '周杰伦');
      }
      final hyphenated = TrackSearch.fromTrack(
        _file(
          'unrelated.mp3',
          title: 'Artist - Love - Hate [FLAC]',
          artist: 'Artist',
        ),
      );
      expect(hyphenated.title, 'Love - Hate');
    },
  );

  test(
    'clean embedded tags always take precedence over a better looking filename',
    () {
      for (final title in ['Live', 'FLAC', 'Love - Hate', '01. Forever']) {
        final query = TrackSearch.fromTrack(
          _file('Other Artist - Other Song [FLAC].mp3', title: title),
        );
        expect(query.title, title);
        expect(query.artist, isNull);
      }
      final query = TrackSearch.fromTrack(
        _file(
          'Other Artist - Other Song.mp3',
          title: 'Good Song',
          artist: 'Singer',
        ),
      );
      expect(query.title, 'Good Song');
      expect(query.artist, 'Singer');
      expect(query.normalizationNotes, isEmpty);
    },
  );

  test('versions and unknown bracket contents are never discarded', () {
    for (final title in [
      'Song (Live)',
      'Song（Remix）',
      'Song [Instrumental]',
      'Song【伴奏】',
      'Song (纯音乐)',
      'Song (2011 Remastered)',
      'Song [Deluxe Edition]',
      'Song [Live 320kbps]',
      'Song (Some Album)',
      'Song [FLAC Rain]',
      'Song (With a Little Help)',
      'Live',
    ]) {
      final query = TrackSearch.fromTrack(
        _file('unrelated.mp3', title: '$title [FLAC]', artist: 'Singer'),
      );
      expect(query.title, title, reason: title);
    }
    for (final title in ['Song - Live', 'Song - Deluxe Edition', 'Song - 伴奏']) {
      final query = TrackSearch.fromTrack(_file('$title.mp3'));
      expect(query.title, title);
      expect(query.artist, isNull);
    }
  });

  test('ambiguous names remain explicit manual corrections without invented metadata', () {
    final embedded = TrackSearch.fromTrack(
      _file('unrelated.mp3', title: 'Song - Singer [FLAC]'),
    );
    expect(embedded.title, 'Song - Singer');
    expect(embedded.artist, isNull);
    expect(embedded.album, isNull);
    final extra = TrackSearch.fromTrack(
      _file('Singer - Song - Album [FLAC].mp3'),
    );
    expect(extra.title, 'Singer - Song - Album');
    expect(extra.artist, isNull);
    expect(extra.album, isNull);
    expect(
      extra.normalizationNotes.any((note) => note.contains('无法确认')),
      isTrue,
    );
    final brackets = TrackSearch.fromTrack(_file('Song (Unknown Album).mp3'));
    expect(brackets.title, 'Song (Unknown Album)');
    expect(brackets.album, isNull);
  });

  test(
    'explicit labels are parsed only when consistent with known metadata',
    () {
      final query = TrackSearch.fromTrack(
        _file(
          'unrelated.mp3',
          title: '晴天 [歌手：周杰伦] [专辑: 叶惠美] [FLAC]',
          artist: '周杰伦',
          album: '叶惠美',
        ),
      );
      expect(query.title, '晴天');
      expect(query.artist, '周杰伦');
      expect(query.album, '叶惠美');
      final explicit = TrackSearch.fromTrack(
        _file('unrelated.mp3', title: 'Song [Artist: A feat. B] [FLAC]'),
      );
      expect(explicit.title, 'Song');
      expect(explicit.artist, 'A feat. B');
      final conflict = TrackSearch.fromTrack(
        _file('Song [歌手: A].mp3', artist: 'B'),
      );
      expect(conflict.title, 'Song [歌手: A]');
      expect(conflict.artist, 'B');
      final unknownAlbum = TrackSearch.fromTrack(
        _file('Song [专辑: New Album].mp3'),
      );
      expect(unknownAlbum.title, 'Song [专辑: New Album]');
      expect(unknownAlbum.album, isNull);
      final conflictAlbum = TrackSearch.fromTrack(
        _file('Song [专辑: New Album].mp3', album: 'Old Album'),
      );
      expect(conflictAlbum.title, 'Song [专辑: New Album]');
      expect(conflictAlbum.album, 'Old Album');
    },
  );

  test('filename-like or technical-only tags are handled without empty garbage queries', () {
    for (final title in [
      '01. Artist - Song [FLAC].mp3',
      '01. Artist - Song.mp3 [FLAC]',
      '01. Artist - Song [FLAC].mp3 [320kbps]',
    ]) {
      final copiedFilename = TrackSearch.fromTrack(
        _file('unrelated.mp3', title: title),
      );
      expect(copiedFilename.title, 'Song', reason: title);
      expect(copiedFilename.artist, 'Artist');
    }
    for (final title in ['[FLAC] [320kbps]', '【无损】', '320kbps', 'FLAC 24bit']) {
      final fallback = TrackSearch.fromTrack(
        _file('Artist - Song.mp3', title: title),
      );
      expect(fallback.title, 'Song', reason: title);
      expect(fallback.artist, 'Artist');
      expect(
        fallback.normalizationNotes.any((note) => note.contains('改用文件名')),
        isTrue,
      );
    }
    final empty = TrackSearch.fromTrack(_file('[FLAC] [320kbps].mp3'));
    expect(empty.title, isEmpty);
    expect(empty.artist, isNull);
    expect(empty.matchesTitle(''), isFalse);
    expect(
      empty.normalizationNotes.any((note) => note.contains('手动填写')),
      isTrue,
    );
    for (final title in [
      'Song [320kbps',
      'Song [FLAC 320kbps',
      'Song (Live [FLAC]',
    ]) {
      final malformed = TrackSearch.fromTrack(_file('$title.mp3'));
      expect(malformed.title, title);
    }
    final labeled = TrackSearch.fromTrack(
      _file('Song.mp3', title: '[Artist: Singer] [FLAC]'),
    );
    expect(labeled.title, 'Song');
    expect(labeled.artist, 'Singer');
    expect(
      labeled.normalizationNotes.any((note) => note.contains('明确标注')),
      isTrue,
    );
  });

  test(
    'normalization changes neither raw metadata nor query cache identity rules',
    () {
      final track = _file(
        'Other.mp3',
        title: 'Artist - A/B [FLAC]',
        artist: 'Artist',
        album: 'Album',
        durationMs: 180001,
      );
      final original = track.toJson();
      final query = TrackSearch.fromTrack(track);
      expect(track.toJson(), original);
      expect(query.title, 'A/B');
      expect(
        query.key,
        const TrackSearch(
          title: 'A/B',
          artist: 'Artist',
          album: 'Album',
          durationSeconds: 180.001,
        ).key,
      );
      expect(
        query.key,
        isNot(
          const TrackSearch(
            title: 'AB',
            artist: 'Artist',
            album: 'Album',
            durationSeconds: 180.001,
          ).key,
        ),
      );
    },
  );
}
