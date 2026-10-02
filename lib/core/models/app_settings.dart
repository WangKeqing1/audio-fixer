import 'audio_track.dart';
import 'audio_folder.dart';

enum AppTheme { system, light, dark }

class AppSettings {
  const AppSettings({
    this.theme = AppTheme.system,
    this.metadata = true,
    this.lyrics = true,
    this.artwork = true,
    this.excludeShortAudio = false,
    this.includeChineseTranslation = true,
    this.excludedFolders = const [],
  });

  final AppTheme theme;
  final bool metadata;
  final bool lyrics;
  final bool artwork;
  final bool excludeShortAudio;
  final bool includeChineseTranslation;
  final List<AudioFolder> excludedFolders;

  bool excludes(AudioTrack track) =>
      (excludeShortAudio &&
          track.durationMs != null &&
          track.durationMs! > 0 &&
          track.durationMs! < 60000) ||
      (track.folder != null &&
          excludedFolders.any((folder) => folder.contains(track.folder!)));

  Set<AudioField> get enabledFields => {
    if (metadata) ...[AudioField.title, AudioField.artist, AudioField.album],
    if (lyrics) AudioField.lyrics,
    if (artwork) AudioField.artwork,
  };

  AppSettings copyWith({
    AppTheme? theme,
    bool? metadata,
    bool? lyrics,
    bool? artwork,
    bool? excludeShortAudio,
    bool? includeChineseTranslation,
    List<AudioFolder>? excludedFolders,
  }) => AppSettings(
    theme: theme ?? this.theme,
    metadata: metadata ?? this.metadata,
    lyrics: lyrics ?? this.lyrics,
    artwork: artwork ?? this.artwork,
    excludeShortAudio: excludeShortAudio ?? this.excludeShortAudio,
    includeChineseTranslation:
        includeChineseTranslation ?? this.includeChineseTranslation,
    excludedFolders: excludedFolders == null
        ? this.excludedFolders
        : List.unmodifiable(excludedFolders),
  );

  Map<String, Object> toJson() => {
    'theme': theme.name,
    'metadata': metadata,
    'lyrics': lyrics,
    'artwork': artwork,
    'excludeShortAudio': excludeShortAudio,
    'includeChineseTranslation': includeChineseTranslation,
    'excludedFolders': excludedFolders
        .map((folder) => folder.toJson())
        .toList(),
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    theme: AppTheme.values.byName(json['theme'] as String),
    metadata: json['metadata'] as bool,
    lyrics: json['lyrics'] as bool,
    artwork: json['artwork'] as bool,
    excludeShortAudio: json['excludeShortAudio'] as bool? ?? false,
    includeChineseTranslation:
        json['includeChineseTranslation'] as bool? ?? true,
    excludedFolders: List.unmodifiable(
      (json['excludedFolders'] as List? ?? const []).map(
        (folder) =>
            AudioFolder.fromJson(Map<String, dynamic>.from(folder as Map)),
      ),
    ),
  );
}
