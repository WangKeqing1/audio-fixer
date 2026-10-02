import 'audio_folder.dart';

enum AudioField {
  title('歌名'),
  artist('歌手'),
  album('专辑'),
  lyrics('歌词'),
  artwork('封面');

  const AudioField(this.label);
  final String label;
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
    this.durationMs,
    this.indexedDurationMs,
    this.lyrics,
    this.artworkPath,
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
  final int? durationMs;
  // The native index and tag parser can differ slightly (e.g. MP3 padding).
  // Compare index to index on refresh, without discarding exact parsed duration.
  final int? indexedDurationMs;
  final String? lyrics;
  final String? artworkPath;
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
    AudioField.lyrics => lyrics,
    AudioField.artwork => artworkPath,
  };

  // A failed read is unknown, not evidence that every tag is absent.
  Set<AudioField> get missingFields => readError == null && detailsLoaded
      ? AudioField.values.where((field) => !hasText(valueOf(field))).toSet()
      : <AudioField>{};

  bool get needsCompletion =>
      readError == null && (!detailsLoaded || missingFields.isNotEmpty);

  AudioTrack withDetails({
    required String? title,
    required String? artist,
    required String? album,
    required int? year,
    required int? durationMs,
    required String? lyrics,
    required String? artworkPath,
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
    durationMs: durationMs,
    indexedDurationMs: indexedDurationMs,
    lyrics: lyrics,
    artworkPath: artworkPath,
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
    'durationMs': durationMs,
    'indexedDurationMs': indexedDurationMs,
    'lyrics': lyrics,
    'artworkPath': artworkPath,
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
    durationMs: json['durationMs'] as int?,
    indexedDurationMs: json.containsKey('indexedDurationMs')
        ? json['indexedDurationMs'] as int?
        : json['durationMs'] as int?,
    lyrics: json['lyrics'] as String?,
    artworkPath: json['artworkPath'] as String?,
    readError: json['readError'] as String?,
    contentUri: json['contentUri'] as String?,
    dateModifiedMs: json['dateModifiedMs'] as int?,
    detailsLoaded: json['detailsLoaded'] as bool? ?? true,
    volumeName: json['volumeName'] as String?,
    relativePath: json['relativePath'] as String?,
  );
}

bool hasText(String? value) => value != null && value.trim().isNotEmpty;
