import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../storage/library_store.dart';

typedef WindowsFolderPicker = Future<String?> Function(String title);

/// The only filesystem authority used by the Windows library and writer.
/// Default Music is readable; original writes require an explicitly picked root.
/// Neither library enumeration nor a supplied file URI expands this allowlist.
class WindowsFileAccess {
  WindowsFileAccess(
    this.directoryProvider, {
    WindowsFolderPicker? pickDirectory,
    Map<String, String>? environment,
  }) : pickDirectory = pickDirectory ?? _pickDirectory,
       environment = environment ?? Platform.environment;

  final DirectoryProvider directoryProvider;
  final WindowsFolderPicker pickDirectory;
  final Map<String, String> environment;
  final _roots = <String, bool>{};
  final _exportRoots = <String>{};
  Future<void>? _initializing;

  List<String> get roots => List.unmodifiable(_roots.keys);
  List<String> get writableRoots => List.unmodifiable(
    _roots.entries.where((entry) => entry.value).map((entry) => entry.key),
  );

  static Future<String?> _pickDirectory(String title) =>
      FilePicker.getDirectoryPath(dialogTitle: title);

  Future<Directory> privateDirectory(String name) async {
    final root = await directoryProvider();
    await root.create(recursive: true);
    final canonicalRoot = await root.resolveSymbolicLinks();
    final directory = Directory(p.join(canonicalRoot, name));
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('应用存储目录不能是链接');
    }
    await directory.create(recursive: true);
    if (!p.equals(await directory.resolveSymbolicLinks(), directory.path)) {
      throw const FileSystemException('应用存储目录已重定向');
    }
    return directory;
  }

  Future<void> initialize() => _initializing ??= _load();

  Future<void> _load() async {
    final directory = await privateDirectory('windows_library');
    final file = File(p.join(directory.path, 'folders.json'));
    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['version'] != 1 || data['roots'] is! List) {
        throw const FormatException('Windows 音乐文件夹设置无效，请保留应用数据后重试');
      }
      for (final row in data['roots'] as List) {
        if (row is! Map || row['path'] is! String || row['write'] is! bool) {
          throw const FormatException('Windows 音乐文件夹记录无效');
        }
        final path = row['path'] as String;
        if (!p.isAbsolute(path) || p.normalize(path) != path) {
          throw const FormatException('Windows 音乐文件夹路径无效');
        }
        _roots[path] = row['write'] as bool;
      }
      return;
    }
    final profile = environment['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) {
      final music = Directory(p.join(profile, 'Music'));
      if (await music.exists()) {
        _roots[await music.resolveSymbolicLinks()] = false;
      }
    }
  }

  Future<bool> chooseLibraryFolder() async {
    await initialize();
    final selection = await pickDirectory('选择音乐文件夹（允许读取及保存已审核的标签）');
    if (selection == null) return false;
    final directory = Directory(selection);
    final canonical = await directory.resolveSymbolicLinks();
    filePath(Directory(canonical).uri.toString());
    if (!await directory.exists()) return false;
    final previous = Map<String, bool>.from(_roots);
    _roots[canonical] = true;
    try {
      final root = await privateDirectory('windows_library');
      await writeWindowsJson(File(p.join(root.path, 'folders.json')), {
        'version': 1,
        'roots': _roots.entries
            .map((entry) => {'path': entry.key, 'write': entry.value})
            .toList(),
      });
    } catch (_) {
      _roots
        ..clear()
        ..addAll(previous);
      rethrow;
    }
    return true;
  }

  Future<String?> chooseExportDirectory({String? title}) async {
    final selection = await pickDirectory(
      title ?? '选择副本保存文件夹（自动生成新文件，不覆盖已有文件）',
    );
    if (selection == null) return null;
    final canonical = await Directory(selection).resolveSymbolicLinks();
    filePath(Directory(canonical).uri.toString());
    _exportRoots.add(canonical);
    return Directory(canonical).uri.toString();
  }

  Future<Directory> exportDirectory(String uri) async {
    final path = filePath(uri);
    final resolved = await Directory(path).resolveSymbolicLinks();
    if (!_exportRoots.contains(path) || !p.equals(path, resolved)) {
      throw PlatformException(
        code: 'permission_denied',
        message: '请先选择副本保存文件夹',
      );
    }
    return Directory(resolved);
  }

  String filePath(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'file' ||
        uri.host.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw PlatformException(code: 'invalid_uri', message: '本地音频地址无效');
    }
    final path = p.normalize(File.fromUri(uri).absolute.path);
    if (!p.isAbsolute(path)) {
      throw PlatformException(code: 'invalid_uri', message: '本地音频地址无效');
    }
    return path;
  }

  Future<File> sourceFile(String uri, {bool forWrite = false}) async {
    await initialize();
    final path = filePath(uri);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw PlatformException(
        code: 'permission_denied',
        message: '音频已移动、不可用或是链接，请重新选择音乐文件夹',
      );
    }
    final canonical = await File(path).resolveSymbolicLinks();
    if (!p.equals(canonical, path)) {
      throw PlatformException(
        code: 'permission_denied',
        message: '不读取或写入重定向的音乐路径',
      );
    }
    var permitted = false;
    for (final entry in _roots.entries) {
      if (forWrite && !entry.value) continue;
      if (!p.isWithin(entry.key, canonical)) continue;
      try {
        if (p.equals(
          await Directory(entry.key).resolveSymbolicLinks(),
          entry.key,
        )) {
          permitted = true;
          break;
        }
      } on FileSystemException {
        // A selected root which was moved or disconnected grants no access.
      }
    }
    if (!permitted) {
      throw PlatformException(
        code: 'permission_denied',
        message: forWrite
            ? '请先选择此音乐文件所在文件夹，再保存已审核的标签'
            : '音频不在已选音乐文件夹内，请重新选择文件夹',
      );
    }
    return File(canonical);
  }

  Future<File> preparedFile(String path) async {
    final root = await privateDirectory('tagged_exports');
    final file = File(p.normalize(p.absolute(path)));
    if (!p.isWithin(root.path, file.path) ||
        !p.basename(p.dirname(file.path)).startsWith('export_') ||
        !RegExp(r'^tagged\.(mp3|flac|m4a|mp4)$')
            .hasMatch(p.basename(file.path)) ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.equals(await file.resolveSymbolicLinks(), file.path)) {
      throw PlatformException(
        code: 'invalid_path',
        message: '待保存文件不属于本次校验的临时副本',
      );
    }
    return file;
  }
}

Future<String> windowsFileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> writeWindowsJson(File file, Map<String, Object?> data) async {
  final temporary = File('${file.path}.next');
  // The parent directory is app-owned and canonical before calling this helper.
  if (await FileSystemEntity.type(temporary.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FileSystemException('恢复记录临时路径不能是链接');
  }
  await temporary.writeAsString(jsonEncode(data), flush: true);
  await temporary.rename(file.path);
}

String windowsSafeFileName(String name) {
  var result = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  result = result.replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty) result = 'audio-fixed';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(result)) {
    result = '_$result';
  }
  if (result.length > 160) {
    final extension = p.extension(result);
    result = '${result.substring(0, 140)}$extension';
  }
  return result;
}

/// Reserves a unique regular file with CREATE_NEW semantics; never overwrites.
Future<File> createWindowsOutput(Directory directory, String name) async {
  final safe = windowsSafeFileName(name);
  for (var attempt = 0; attempt < 10000; attempt++) {
    final file = File(
      p.join(
        directory.path,
        attempt == 0
            ? safe
            : '${p.basenameWithoutExtension(safe)} ($attempt)${p.extension(safe)}',
      ),
    );
    try {
      await file.create(exclusive: true);
      return file;
    } on FileSystemException {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        rethrow;
      }
    }
  }
  throw const FileSystemException('目标文件名过多，请选择其他保存位置');
}

Future<void> copyWindowsFile(File source, File destination) async {
  final input = await source.open();
  RandomAccessFile? output;
  try {
    output = await destination.open(mode: FileMode.write);
    while (true) {
      final bytes = await input.read(1024 * 1024);
      if (bytes.isEmpty) break;
      await output.writeFrom(bytes);
    }
    await output.flush();
  } finally {
    try {
      await input.close();
    } finally {
      await output?.close();
    }
  }
}

/// Writes only a just-reserved empty output. Opening in append mode avoids
/// truncation before validation; the same locked handle is used throughout.
/// If another program replaced/populated the name, keep its bytes untouched.
Future<void> copyWindowsReservedOutput(File source, File destination) async {
  if (await FileSystemEntity.type(destination.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FileSystemException('新建的保存路径已变化');
  }
  final input = await source.open();
  RandomAccessFile? output;
  var locked = false;
  try {
    output = await destination.open(mode: FileMode.append);
    await output.lock(FileLock.exclusive);
    locked = true;
    if (await output.length() != 0 ||
        await FileSystemEntity.type(destination.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.equals(await destination.resolveSymbolicLinks(), destination.path)) {
      throw const FileSystemException('保存位置已被其他程序更改，未覆盖已有文件');
    }
    await output.setPosition(0);
    while (true) {
      final bytes = await input.read(1024 * 1024);
      if (bytes.isEmpty) break;
      await output.writeFrom(bytes);
    }
    await output.flush();
  } finally {
    try {
      await input.close();
    } finally {
      try {
        if (locked) await output!.unlock();
      } finally {
        await output?.close();
      }
    }
  }
}
