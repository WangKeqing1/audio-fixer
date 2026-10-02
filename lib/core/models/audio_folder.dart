import 'dart:convert';

/// A folder identity is scoped to an exact storage volume, never a content URI.
/// Android 29+ paths are relative to that volume. Older devices expose an
/// absolute DATA parent path under the distinct `legacy-filesystem` namespace.
class AudioFolder {
  const AudioFolder({required this.volumeName, required this.relativePath});

  final String volumeName;
  final String relativePath;

  String get normalizedPath =>
      relativePath.split('/').where((part) => part.isNotEmpty).join('/');
  bool get isValid =>
      volumeName.isNotEmpty &&
      relativePath.split('/').every((part) => part != '.' && part != '..');
  String get id => jsonEncode([volumeName, normalizedPath]);
  String get volumeLabel => switch (volumeName) {
    'external_primary' => '内部存储',
    'legacy-filesystem' => '本地存储（旧版路径）',
    _ => '存储卷 $volumeName',
  };
  String get label =>
      '$volumeLabel · /${normalizedPath.isEmpty ? '' : '$normalizedPath/'}';

  bool contains(AudioFolder other) =>
      isValid &&
      other.isValid &&
      volumeName == other.volumeName &&
      (normalizedPath.isEmpty ||
          other.normalizedPath == normalizedPath ||
          other.normalizedPath.startsWith('$normalizedPath/'));

  /// Includes the volume root and this folder, in root-to-leaf order.
  Iterable<AudioFolder> get ancestors sync* {
    if (!isValid) return;
    yield AudioFolder(volumeName: volumeName, relativePath: '');
    if (normalizedPath.isEmpty) return;
    final parts = normalizedPath.split('/');
    for (var length = 1; length <= parts.length; length++) {
      yield AudioFolder(
        volumeName: volumeName,
        relativePath: parts.take(length).join('/'),
      );
    }
  }

  Map<String, Object> toJson() => {
    'volumeName': volumeName,
    'relativePath': normalizedPath,
  };

  factory AudioFolder.fromJson(Map<String, dynamic> json) {
    final folder = AudioFolder(
      volumeName: json['volumeName'] as String,
      relativePath: json['relativePath'] as String,
    );
    if (!folder.isValid) throw const FormatException('文件夹标识无效');
    return folder;
  }

  @override
  bool operator ==(Object other) =>
      other is AudioFolder &&
      volumeName == other.volumeName &&
      normalizedPath == other.normalizedPath;

  @override
  int get hashCode => Object.hash(volumeName, normalizedPath);
}
