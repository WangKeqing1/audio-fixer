import 'audio_track.dart';

enum AppTheme { system, light, dark }

class AppSettings {
  const AppSettings({
    this.theme = AppTheme.system,
    this.metadata = true,
    this.lyrics = true,
    this.artwork = true,
  });

  final AppTheme theme;
  final bool metadata;
  final bool lyrics;
  final bool artwork;

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
  }) => AppSettings(
    theme: theme ?? this.theme,
    metadata: metadata ?? this.metadata,
    lyrics: lyrics ?? this.lyrics,
    artwork: artwork ?? this.artwork,
  );

  Map<String, Object> toJson() => {
    'theme': theme.name,
    'metadata': metadata,
    'lyrics': lyrics,
    'artwork': artwork,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    theme: AppTheme.values.byName(json['theme'] as String),
    metadata: json['metadata'] as bool,
    lyrics: json['lyrics'] as bool,
    artwork: json['artwork'] as bool,
  );
}
