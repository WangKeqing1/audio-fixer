import 'audio_folder.dart';

const _unchangedTag = Object();

enum AudioField {
  title('歌名'),
  artist('歌手'),
  album('专辑'),
  albumArtist('专辑歌手'),
  year('年份'),
  genre('流派'),
  trackNumber('音轨序号'),
  trackTotal('音轨总数'),
  discNumber('碟片序号'),
  discTotal('碟片总数'),
  composer('作曲'),
  comment('备注'),
  lyrics('歌词'),
  artwork('封面');

  const AudioField(this.label);
  final String label;

  // Optional tags can be repaired without making them mandatory for every song.
  static const coreFields = {title, artist, album, lyrics, artwork};
  static const metadataFields = {
    title,
    artist,
    album,
    albumArtist,
    year,
    genre,
    trackNumber,
    trackTotal,
    discNumber,
    discTotal,
    composer,
    comment,
  };
  static const numericFields = {
    year,
    trackNumber,
    trackTotal,
    discNumber,
    discTotal,
  };
  bool get isNumeric => numericFields.contains(this);
}

class AudioTrack {
  const AudioTrack({
    required this.id,
    required this.fileName,
    this.localPath = '',
    required this.sizeBytes,
    required this.importedAt,
    this.title,
    this.artist,
    this.album,
    this.year,
    this.albumArtist,
    this.genre,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.discTotal,
    this.composer,
    this.comment,
    this.tagReadWarnings = const [],
    this.durationMs,
    this.indexedDurationMs,
    this.lyrics,
    this.isInstrumental = false,
    this.artworkPath,
    this.artworkSha256,
    this.readError,
    this.contentUri,
    this.dateModifiedMs,
    this.detailsLoaded = true,
    this.volumeName,
    this.relativePath,
  });

  final String id;
  final String fileName;
  final String localPath;
  final int sizeBytes;
  final DateTime importedAt;
  final String? title;
  final String? artist;
  final String? album;
  final int? year;
  final String? albumArtist;
  final String? genre;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final int? discTotal;
  final String? composer;
  final String? comment;
  final List<String> tagReadWarnings;
  final int? durationMs;
  // The native index and tag parser can differ slightly (e.g. MP3 padding).
  // Compare index to index on refresh, without discarding exact parsed duration.
  final int? indexedDurationMs;
  final String? lyrics;
  // Explicit user choice stored in the app catalog, never inferred from a
  // missing lyric or written as placeholder lyrics into an audio file.
  final bool isInstrumental;
  final String? artworkPath;
  // Snapshot of extracted bytes, independent of a subsequently refreshed cache.
  final String? artworkSha256;
  final String? readError;
  final String? contentUri;
  final int? dateModifiedMs;
  final bool detailsLoaded;
  final String? volumeName;
  final String? relativePath;

  AudioFolder? get folder {
    if (volumeName == null || relativePath == null) return null;
    final result = AudioFolder(
      volumeName: volumeName!,
      relativePath: relativePath!,
    );
    return result.isValid ? result : null;
  }

  bool get hasKnownDuration => durationMs != null && durationMs! > 0;

  bool get isDeviceTrack => contentUri != null;

  String get displayTitle => hasText(title) ? title! : fileName;
  String get extension => fileName.split('.').last.toUpperCase();

  String? valueOf(AudioField field) => switch (field) {
    AudioField.title => title,
    AudioField.artist => artist,
    AudioField.album => album,
    AudioField.albumArtist => albumArtist,
    AudioField.year => year?.toString(),
    AudioField.genre => genre,
    AudioField.trackNumber => trackNumber?.toString(),
    AudioField.trackTotal => trackTotal?.toString(),
    AudioField.discNumber => discNumber?.toString(),
    AudioField.discTotal => discTotal?.toString(),
    AudioField.composer => composer,
    AudioField.comment => comment,
    AudioField.lyrics => lyrics,
    AudioField.artwork => artworkPath,
  };

  // A failed read is unknown, not evidence that every tag is absent.
  Set<AudioField> get missingFields => readError == null && detailsLoaded
      ? AudioField.coreFields
            .where(
              (field) =>
                  !(field == AudioField.lyrics && isInstrumental) &&
                  !hasText(valueOf(field)),
            )
            .toSet()
      : <AudioField>{};

  bool get needsCompletion =>
      readError == null && (!detailsLoaded || missingFields.isNotEmpty);

  AudioTrack withDetails({
    required String? title,
    required String? artist,
    required String? album,
    required int? year,
    Object? albumArtist = _unchangedTag,
    Object? genre = _unchangedTag,
    Object? trackNumber = _unchangedTag,
    Object? trackTotal = _unchangedTag,
    Object? discNumber = _unchangedTag,
    Object? discTotal = _unchangedTag,
    Object? composer = _unchangedTag,
    Object? comment = _unchangedTag,
    List<String>? tagReadWarnings,
    required int? durationMs,
    required String? lyrics,
    required String? artworkPath,
    Object? artworkSha256 = _unchangedTag,
    String? readError,
  }) => AudioTrack(
    id: id,
    fileName: fileName,
    localPath: localPath,
    sizeBytes: sizeBytes,
    importedAt: importedAt,
    contentUri: contentUri,
    dateModifiedMs: dateModifiedMs,
    volumeName: volumeName,
    relativePath: relativePath,
    title: title,
    artist: artist,
    album: album,
    year: year,
    albumArtist: identical(albumArtist, _unchangedTag)
        ? this.albumArtist
        : albumArtist as String?,
    genre: identical(genre, _unchangedTag) ? this.genre : genre as String?,
    trackNumber: identical(trackNumber, _unchangedTag)
        ? this.trackNumber
        : trackNumber as int?,
    trackTotal: identical(trackTotal, _unchangedTag)
        ? this.trackTotal
        : trackTotal as int?,
    discNumber: identical(discNumber, _unchangedTag)
        ? this.discNumber
        : discNumber as int?,
    discTotal: identical(discTotal, _unchangedTag)
        ? this.discTotal
        : discTotal as int?,
    composer: identical(composer, _unchangedTag)
        ? this.composer
        : composer as String?,
    comment: identical(comment, _unchangedTag)
        ? this.comment
        : comment as String?,
    tagReadWarnings: tagReadWarnings ?? this.tagReadWarnings,
    durationMs: durationMs,
    indexedDurationMs: indexedDurationMs,
    lyrics: lyrics,
    isInstrumental: isInstrumental,
    artworkPath: artworkPath,
    artworkSha256: identical(artworkSha256, _unchangedTag)
        ? this.artworkSha256
        : artworkSha256 as String?,
    readError: readError,
    detailsLoaded: true,
  );

  AudioTrack withReadError(String error) => withDetails(
    title: title,
    artist: artist,
    album: album,
    year: year,
    durationMs: durationMs,
    lyrics: lyrics,
    artworkPath: artworkPath,
    readError: error,
  );

  AudioTrack withInstrumental(bool value) => AudioTrack(
    id: id,
    fileName: fileName,
    localPath: localPath,
    sizeBytes: sizeBytes,
    importedAt: importedAt,
    title: title,
    artist: artist,
    album: album,
    year: year,
    albumArtist: albumArtist,
    genre: genre,
    trackNumber: trackNumber,
    trackTotal: trackTotal,
    discNumber: discNumber,
    discTotal: discTotal,
    composer: composer,
    comment: comment,
    tagReadWarnings: tagReadWarnings,
    durationMs: durationMs,
    indexedDurationMs: indexedDurationMs,
    lyrics: lyrics,
    isInstrumental: value,
    artworkPath: artworkPath,
    artworkSha256: artworkSha256,
    readError: readError,
    contentUri: contentUri,
    dateModifiedMs: dateModifiedMs,
    detailsLoaded: detailsLoaded,
    volumeName: volumeName,
    relativePath: relativePath,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'fileName': fileName,
    'localPath': localPath,
    'sizeBytes': sizeBytes,
    'importedAt': importedAt.toIso8601String(),
    'title': title,
    'artist': artist,
    'album': album,
    'year': year,
    'albumArtist': albumArtist,
    'genre': genre,
    'trackNumber': trackNumber,
    'trackTotal': trackTotal,
    'discNumber': discNumber,
    'discTotal': discTotal,
    'composer': composer,
    'comment': comment,
    'tagReadWarnings': tagReadWarnings,
    'durationMs': durationMs,
    'indexedDurationMs': indexedDurationMs,
    'lyrics': lyrics,
    'isInstrumental': isInstrumental,
    'artworkPath': artworkPath,
    'artworkSha256': artworkSha256,
    'readError': readError,
    'contentUri': contentUri,
    'dateModifiedMs': dateModifiedMs,
    'detailsLoaded': detailsLoaded,
    'volumeName': volumeName,
    'relativePath': relativePath,
  };

  factory AudioTrack.fromJson(Map<String, dynamic> json) => AudioTrack(
    id: json['id'] as String,
    fileName: json['fileName'] as String,
    localPath: json['localPath'] as String? ?? '',
    sizeBytes: json['sizeBytes'] as int,
    importedAt: DateTime.parse(json['importedAt'] as String),
    title: json['title'] as String?,
    artist: json['artist'] as String?,
    album: json['album'] as String?,
    year: json['year'] as int?,
    albumArtist: json['albumArtist'] as String?,
    genre: json['genre'] as String?,
    trackNumber: json['trackNumber'] as int?,
    trackTotal: json['trackTotal'] as int?,
    discNumber: json['discNumber'] as int?,
    discTotal: json['discTotal'] as int?,
    composer: json['composer'] as String?,
    comment: json['comment'] as String?,
    tagReadWarnings:
        (json['tagReadWarnings'] as List?)?.whereType<String>().toList() ??
        const [],
    durationMs: json['durationMs'] as int?,
    indexedDurationMs: json.containsKey('indexedDurationMs')
        ? json['indexedDurationMs'] as int?
        : json['durationMs'] as int?,
    lyrics: json['lyrics'] as String?,
    isInstrumental: json['isInstrumental'] as bool? ?? false,
    artworkPath: json['artworkPath'] as String?,
    artworkSha256: json['artworkSha256'] as String?,
    readError: json['readError'] as String?,
    contentUri: json['contentUri'] as String?,
    dateModifiedMs: json['dateModifiedMs'] as int?,
    detailsLoaded: json['detailsLoaded'] as bool? ?? true,
    volumeName: json['volumeName'] as String?,
    relativePath: json['relativePath'] as String?,
  );
}

bool hasText(String? value) => value != null && value.trim().isNotEmpty;
