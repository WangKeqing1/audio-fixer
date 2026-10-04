import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../models/audio_track.dart';

class TrackSearch {
  const TrackSearch({
    required this.title,
    this.artist,
    this.album,
    this.durationSeconds,
    this.normalizationNotes = const [],
    this.artistIsInferred = false,
  });
  final String title;
  final String? artist;
  final String? album;
  final double? durationSeconds;
  final List<String> normalizationNotes;
  final bool artistIsInferred;

  factory TrackSearch.fromTrack(AudioTrack track) {
    final embeddedTitle = track.title?.trim() ?? '';
    final fileTitle = p.basenameWithoutExtension(track.fileName).trim();
    final notes = <String>[];
    final artist = _cleanQueryTag(track.artist, '歌手', notes);
    final album = _cleanQueryTag(track.album, '专辑', notes);
    var name = _SearchName(
      embeddedTitle.isEmpty ? fileTitle : embeddedTitle,
      artist: artist,
      album: album,
      fromFileName: embeddedTitle.isEmpty,
    );
    if (name.title.isEmpty && embeddedTitle.isNotEmpty) {
      // A title consisting entirely of explicit metadata has no useful query.
      // Never replace an ordinary, nonempty embedded title with a filename.
      final fallback = _SearchName(
        fileTitle,
        artist: name.artist,
        album: album,
        fromFileName: true,
      );
      if (fallback.title.isNotEmpty) {
        notes.addAll(name.notes.where((note) => note != _missingTitleNote));
        notes.add('内嵌名称仅含附加信息，检索改用文件名');
        name = fallback;
      }
    }
    notes.addAll(name.notes);
    return TrackSearch(
      title: name.title,
      artist: name.artist,
      album: album,
      durationSeconds: (track.durationMs ?? 0) > 0
          ? track.durationMs! / 1000
          : null,
      normalizationNotes: List.unmodifiable(notes.toSet()),
      artistIsInferred: name.artistIsInferred,
    );
  }

  /// A bounded alternative for discovery after a clean no-match. It never
  /// replaces a clean embedded identity or authorizes a tag change.
  static TrackSearch? filenameFallback(AudioTrack track) {
    final name = _SearchName(
      p.basenameWithoutExtension(track.fileName).trim(),
      artist: null,
      album: null,
      fromFileName: true,
    );
    if (!name.artistIsInferred || !hasText(name.artist) || name.title.isEmpty) {
      return null;
    }
    final primary = TrackSearch.fromTrack(track);
    if (_sameIdentity(primary.title, name.title) &&
        primary.artist != null &&
        _sameIdentity(primary.artist!, name.artist!)) {
      return null;
    }
    return TrackSearch(
      title: name.title,
      artist: name.artist,
      durationSeconds: primary.durationSeconds,
      artistIsInferred: true,
      normalizationNotes: [
        '原标签未匹配，按文件名推测另一组检索词；与原标签的差异尚未确认，原资料保持不变',
        ...name.notes,
      ],
    );
  }

  // The actual query includes punctuation and sub-second duration. Do not
  // share a cached answer across distinct signatures that normalize alike.
  String get key => jsonEncode([
    title.trim().toLowerCase(),
    artist?.trim().toLowerCase(),
    album?.trim().toLowerCase(),
    durationSeconds,
  ]);

  bool matchesTitle(String candidate) =>
      normalizedIdentity(title).isNotEmpty &&
      normalizedIdentity(title) == normalizedIdentity(candidate);

  bool matchesArtist(Iterable<String> candidates) =>
      artist == null ||
      (normalizedIdentity(artist!).isNotEmpty &&
          candidates.any(
            (candidate) =>
                normalizedIdentity(artist!) == normalizedIdentity(candidate),
          ));

  bool matchesDuration(double? candidate, {double tolerance = 3}) =>
      durationSeconds == null ||
      (candidate != null &&
          candidate.isFinite &&
          candidate > 0 &&
          (durationSeconds! - candidate).abs() <= tolerance);
}

// This is a query hint, not a tag repair. Only known technical suffixes and
// explicitly identified metadata are removed; unknown text stays searchable.
class _SearchName {
  _SearchName(
    String raw, {
    required String? artist,
    required String? album,
    required bool fromFileName,
  }) : title = raw.trim(),
       artist = hasText(artist) ? artist!.trim() : null {
    var fileLike = _removeAudioExtension() || fromFileName;
    _removeSuffixes(album);
    // Tags copied from download names may put quality text after the extension.
    if (_removeAudioExtension()) {
      fileLike = true;
      _removeSuffixes(album);
    }
    final recordingLike = fileLike && _looksLikeRecordingName(title);
    var numberedFileName = false;
    if (fileLike && !recordingLike) {
      final withoutNumber = title.replaceFirst(_trackPrefix, '').trim();
      if (withoutNumber != title) {
        numberedFileName = true;
        title = withoutNumber;
        notes.add('检索时已忽略文件名开头的音轨序号');
      }
    }
    if (fileLike && !recordingLike && numberedFileName) {
      _separateBracketArtist();
    }
    _separateArtist(
      allowInference: fileLike && !recordingLike,
      allowCollectionPrefix: numberedFileName,
    );
    if (recordingLike && this.artist == null) {
      _note('名称可能来自录音或带有时间戳，未推测歌手，请手动填写检索词');
    }
    if (title.isEmpty || normalizedIdentity(title).isEmpty) {
      // An empty query is deliberately left empty: every source can decline it
      // instead of searching only for an artist or for arbitrary quality text.
      title = '';
      notes.add(_missingTitleNote);
    }
  }

  String title;
  String? artist;
  bool artistIsInferred = false;
  final notes = <String>[];

  bool _removeAudioExtension() {
    final extension = _audioExtension.firstMatch(title);
    if (extension == null) return false;
    title = title.substring(0, extension.start).trim();
    _note('检索时已忽略名称末尾的音频扩展名');
    return true;
  }

  void _removeSuffixes(String? album) {
    if (_isTechnicalMetadata(title) &&
        (_technicalLabel.hasMatch(title) ||
            _sourceLabel.hasMatch(title) ||
            _technicalNumber.hasMatch(title))) {
      title = '';
      _note('检索时已忽略音质、格式或下载来源后缀');
      return;
    }
    while (title.isNotEmpty) {
      final bracket = _trailingBracket.firstMatch(title);
      if (bracket != null) {
        if (_insideBrackets(title, bracket.start)) break;
        final content = [
          for (var group = 1; group <= bracket.groupCount; group++)
            if (bracket.group(group) != null) bracket.group(group)!,
        ].single.trim();
        if (_isTechnicalMetadata(content)) {
          title = _beforeSuffix(title, bracket.start);
          _note('检索时已忽略音质、格式或下载来源后缀');
          continue;
        }
        final label = _metadataLabel.firstMatch(content);
        if (label != null) {
          final kind = label.group(1)!.toLowerCase();
          final value = label.group(2)!.trim();
          if (_artistLabels.contains(kind) &&
              normalizedIdentity(value).isNotEmpty &&
              (artist == null || _sameIdentity(artist!, value))) {
            artist ??= value;
            title = _beforeSuffix(title, bracket.start);
            _note('检索歌手来自名称中明确标注的歌手信息');
            continue;
          }
          if (_albumLabels.contains(kind) &&
              album != null &&
              _sameIdentity(album, value)) {
            title = _beforeSuffix(title, bracket.start);
            _note('检索时已忽略与现有专辑一致的名称后缀');
            continue;
          }
          _note('名称中的附加信息无法确认或与现有标签冲突，已保留，请手动核对');
        } else if (!_versionWords.hasMatch(content)) {
          _note('名称中的括号内容可能属于歌名或专辑，已保留，请按需调整检索词');
        }
        break;
      }
      var removed = false;
      for (final boundary in _suffixBoundary.allMatches(title)) {
        if (_insideBrackets(title, boundary.start)) continue;
        final suffix = title.substring(boundary.end).trim();
        if (suffix.isNotEmpty && _isTechnicalMetadata(suffix)) {
          title = _beforeSuffix(title, boundary.start);
          _note('检索时已忽略音质、格式或下载来源后缀');
          removed = true;
          break;
        }
      }
      if (!removed) break;
    }
  }

  void _separateBracketArtist() {
    final bracket = _numberedBracketArtist.firstMatch(title);
    if (bracket == null) return;
    final credit = bracket.group(1)!.trim();
    final song = bracket.group(2)!.trim();
    // A bracketed version/source is not an artist. Do not absorb ambiguous
    // "[Group] Guest - Song" compilation credits into this narrow pattern.
    if (_isTechnicalMetadata(credit) ||
        _metadataLabel.hasMatch(credit) ||
        _versionWords.hasMatch(credit) ||
        normalizedIdentity(credit).isEmpty ||
        normalizedIdentity(song).isEmpty ||
        _nameSeparator.hasMatch(song)) {
      return;
    }
    if (artist != null && !_sameIdentity(artist!, credit)) {
      _note('文件名中的括号歌手与现有标签不同，已保留原检索条件，可尝试文件名候选');
      return;
    }
    artistIsInferred = artist == null;
    artist ??= credit;
    title = song;
    _note(
      artistIsInferred
          ? '按“(序号) [歌手] 歌名”的文件名格式推测检索词，请核对歌手与歌名'
          : '检索时已分离文件名中与现有歌手一致的括号内容',
    );
  }

  void _separateArtist({
    required bool allowInference,
    required bool allowCollectionPrefix,
  }) {
    final separators = _nameSeparator
        .allMatches(title)
        .where((match) => !_insideBrackets(title, match.start))
        .toList();
    if (artist != null) {
      for (final separator in separators) {
        final before = title.substring(0, separator.start).trim();
        final after = title.substring(separator.end).trim();
        if (after.isNotEmpty && _sameIdentity(before, artist!)) {
          title = after;
          _note('检索时已分离名称中与现有歌手一致的部分');
          return;
        }
        if (before.isNotEmpty && _sameIdentity(after, artist!)) {
          title = before;
          _note('检索时已分离名称中与现有歌手一致的部分');
          return;
        }
      }
      // Some tags copied from filenames append the complete artist credit
      // using spaces only. Require the existing credit, including its word
      // boundaries and punctuation; never guess the last words as an artist.
      // Bracketed credits and version annotations remain part of the title.
      // Credits such as "Live" are ambiguous with recording-version text.
      final artistText = _normalizedSpacing(artist!);
      if (normalizedIdentity(artistText).isNotEmpty &&
          !_versionWords.hasMatch(artistText)) {
        for (final boundary in _whitespace.allMatches(title)) {
          if (_insideBrackets(title, boundary.start)) continue;
          final before = title.substring(0, boundary.start).trim();
          final after = title.substring(boundary.end).trim();
          if (normalizedIdentity(before).isNotEmpty &&
              _normalizedSpacing(after) == artistText) {
            title = before;
            _note('检索时已分离名称末尾与现有歌手一致的完整歌手名');
            return;
          }
        }
      }
    } else if (allowInference && separators.length == 1) {
      final separator = separators.single;
      var before = title.substring(0, separator.start).trim();
      final after = title.substring(separator.end).trim();
      var inferredCollection = false;
      // Numbered compilation names sometimes use 【source】Artist - Title.
      // Only this narrow, spaced shape permits a source-prefix guess. An
      // unnumbered bracketed artist or a title/version bracket stays intact.
      if (allowCollectionPrefix &&
          RegExp(r'^\s+[-–—]\s+$').hasMatch(separator.group(0)!)) {
        final collection = _leadingCollectionArtist.firstMatch(before);
        if (collection != null &&
            !_versionWords.hasMatch(collection.group(1)!) &&
            !_isTechnicalMetadata(collection.group(1)!) &&
            !_metadataLabel.hasMatch(collection.group(1)!)) {
          before = collection.group(2)!.trim();
          inferredCollection = true;
        }
      }
      if (normalizedIdentity(before).isNotEmpty &&
          normalizedIdentity(after).isNotEmpty &&
          !_ambiguousVersionPart(before) &&
          !_ambiguousVersionPart(after) &&
          !_isTechnicalMetadata(before)) {
        artist = before;
        artistIsInferred = true;
        title = after;
        if (inferredCollection) {
          _note('按编号文件名推测开头的【括号内容】是来源，未作专辑使用，请核对歌手');
        }
        _note('按“歌手 - 歌名”的文件名格式推测检索词，请核对歌手与歌名');
        return;
      }
    }
    if (separators.isNotEmpty) {
      _note('名称分隔符的含义无法确认，已保留，请按需调整检索词');
    }
  }

  void _note(String note) {
    if (!notes.contains(note)) notes.add(note);
  }
}

const _missingTitleNote = '名称中没有可确认的歌名，请手动填写检索词';
final _audioExtension = RegExp(
  r'\.(?:mp3|flac|m4a|aac|wav|ape|alac|ogg|opus|wma|aiff?)$',
  caseSensitive: false,
);
final _trackPrefix = RegExp(r'^(?:\d{1,3}\s*[._-]\s*|[（(]\d{1,3}[）)]\s+)');
final _numberedBracketArtist = RegExp(r'^\[([^\[\]]+)\]\s+([^\[【(（].*)$');
final _trailingBracket = RegExp(
  r'\[([^\[\]]*)\]$|\(([^()]*)\)$|【([^【】]*)】$|（([^（）]*)）$',
);
final _metadataLabel = RegExp(
  r'^(歌手|演唱|artist|专辑|album)\s*[:：]\s*(.+)$',
  caseSensitive: false,
);
const _artistLabels = {'歌手', '演唱', 'artist'};
const _albumLabels = {'专辑', 'album'};
final _versionWords = RegExp(
  r'\b(?:live|remix|instrumental|acoustic|remaster(?:ed)?|edition|version|mix|edit)\b|伴奏|纯音乐|现场|重制|重混|版本',
  caseSensitive: false,
);
final _suffixBoundary = RegExp(r'\s*[-_｜|－–—]\s*|\s+');
final _whitespace = RegExp(r'\s+');
final _nameSeparator = RegExp(
  r'\s+[-–—]\s+|[－｜]|(?<=[\u3040-\u30ff\u3400-\u9fff])[-_](?=[\u3040-\u30ff\u3400-\u9fff])',
);
final _leadingCollectionArtist = RegExp(r'^【([^【】]+)】\s*([^\s\[【(（].*)$');
final _recordingPrefix = RegExp(
  r'^(?:微信|wechat|qq|record(?:ing)?|call[ _-]?record(?:ing)?|电话录音|通话录音|标准录音|录音)(?:[\s_-]|$)',
  caseSensitive: false,
);
final _recordingTimestamp = RegExp(
  r'(?:^|[ _-])(?:\d{10,14}(?:[-_]\d{1,3})?|\d{2,4}[-_]\d{2}[-_]\d{2}[ _-]\d{2}[-_]\d{2}[-_]\d{2}(?:[-_]\d{1,3})?)$',
);

bool _looksLikeRecordingName(String text) =>
    _recordingPrefix.hasMatch(text) || _recordingTimestamp.hasMatch(text);

final _technicalMetadata = RegExp(
  r'^(?:(?:flac|mp3|m4a|aac|wav|ape|alac|ogg|opus|wma|aiff?|lossless|hi[ -]?res|hq|sq|'
  r'(?:64|96|128|160|192|224|256|320)\s*k|\d{2,4}\s*(?:kbps|kbit/s|kb/s)|'
  r'(?:16|24|32)\s*[- ]?bit|\d{2,3}(?:\.\d+)?\s*khz|'
  r'无损(?:音质)?|超高音质|高音质|标准音质|高品质|'
  r'(?:网易云音乐|QQ音乐|酷狗音乐|酷我音乐|咪咕音乐)(?:下载)?|'
  r'(?:www\.)?(?:music\.163\.com|kugou\.com|kuwo\.cn|y\.qq\.com|wusunk\.com))'
  r'[\s,，/|·+_-]*)+$',
  caseSensitive: false,
);
final _technicalLabel = RegExp(
  r'^(?:音质|格式|码率|比特率|采样率|quality|format|codec|bitrate)\s*[:：]\s*',
  caseSensitive: false,
);
final _sourceLabel = RegExp(
  r'^(?:下载来源|来源|下载自|source|downloaded from)\s*[:：]?\s*(.+)$',
  caseSensitive: false,
);
final _technicalNumber = RegExp(
  r'\d\s*(?:k|kbps|kbit/s|kb/s|bit|khz)\b',
  caseSensitive: false,
);

bool _ambiguousVersionPart(String text) {
  // "Artist - Song (Live)" still has a title; "Song - Live" may be a
  // title plus a version suffix, not an artist plus a title.
  final bracket = _trailingBracket.firstMatch(text);
  final base = bracket == null ? text : text.substring(0, bracket.start).trim();
  return base.isEmpty || _versionWords.hasMatch(base);
}

bool _isTechnicalMetadata(String text) {
  final value = text.trim();
  if (_technicalMetadata.hasMatch(value)) return true;
  final withoutLabel = value.replaceFirst(_technicalLabel, '');
  if (withoutLabel != value && _technicalMetadata.hasMatch(withoutLabel)) {
    return true;
  }
  final source = _sourceLabel.firstMatch(value);
  return source != null && _technicalMetadata.hasMatch(source.group(1)!.trim());
}

String? _cleanQueryTag(String? raw, String label, List<String> notes) {
  if (!hasText(raw)) return null;
  var value = raw!.trim();
  // Only recognized technical/download markers are removed. Names of unknown
  // websites and ordinary bracketed artist credits are not guessed away.
  if (_isTechnicalMetadata(value) &&
      (_sourceLabel.hasMatch(value) ||
          _technicalLabel.hasMatch(value) ||
          _technicalNumber.hasMatch(value) ||
          value.contains('.'))) {
    notes.add('检索时已忽略$label标签中的格式或下载来源信息，原标签保留');
    return null;
  }
  while (value.isNotEmpty) {
    final match = _trailingBracket.firstMatch(value);
    if (match == null || _insideBrackets(value, match.start)) break;
    final content = [
      for (var i = 1; i <= match.groupCount; i++)
        if (match.group(i) != null) match.group(i)!,
    ].single;
    if (!_isTechnicalMetadata(content)) break;
    value = _beforeSuffix(value, match.start);
    notes.add('检索时已忽略$label标签中的格式或下载来源后缀，原标签保留');
  }
  return hasText(value) ? value : null;
}

String _beforeSuffix(String text, int start) => text
    .substring(0, start)
    .replaceFirst(RegExp(r'\s+[-–—]\s*$|[_｜|－]\s*$'), '')
    .trim();

bool _sameIdentity(String first, String second) =>
    normalizedIdentity(first).isNotEmpty &&
    normalizedIdentity(first) == normalizedIdentity(second);

String _normalizedSpacing(String text) =>
    text.trim().toLowerCase().replaceAll(_whitespace, ' ');

bool _insideBrackets(String text, int position) {
  var depth = 0;
  for (var index = 0; index < position; index++) {
    if ('[（(【'.contains(text[index])) depth++;
    if (']）)】'.contains(text[index]) && depth > 0) depth--;
  }
  return depth > 0;
}

// Keep words such as live/remix/instrumental: they identify different versions.
String normalizedIdentity(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
