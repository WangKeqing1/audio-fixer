import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'windows_file_access.dart';

/// Dart filesystem adapter for the existing verified SafeAudioCopyExporter.
/// Preparation/tag/payload verification stays in the shared exporter; this class
/// supplies scoped snapshots, durable backup journals and final byte checks.
class WindowsFileMethodChannel extends MethodChannel {
  WindowsFileMethodChannel(this.access) : super('audio_fixer/windows_files');
  final WindowsFileAccess access;
  final _readCopies = <String>{};
  bool _busy = false;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async =>
      await _invoke(
        method,
        arguments is Map ? Map<String, dynamic>.from(arguments) : const {},
      ) as T?;

  @override
  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    dynamic arguments,
  ]) async {
    final result = await invokeMethod<Map<dynamic, dynamic>>(method, arguments);
    return result?.cast<K, V>();
  }

  @override
  Future<List<T>?> invokeListMethod<T>(
    String method, [
    dynamic arguments,
  ]) async {
    final result = await invokeMethod<List<dynamic>>(method, arguments);
    return result?.cast<T>();
  }

  Future<Object?> _invoke(String method, Map<String, dynamic> arguments) async {
    switch (method) {
      case 'copyForRead':
        return _copyForRead(arguments['uri'] as String);
      case 'releaseReadCopy':
        final path = arguments['path'] as String;
        if (_readCopies.remove(path)) {
          final file = File(path);
          if (await file.exists()) await file.delete();
          final parent = file.parent;
          if (await parent.exists() && await parent.list().isEmpty) {
            await parent.delete();
          }
        }
        return null;
      case 'chooseExportDirectory':
        return access.chooseExportDirectory();
      case 'authorizeOriginalWrites':
        for (final uri in arguments['uris'] as List) {
          await access.sourceFile(uri as String, forWrite: true);
        }
        return true;
      case 'saveAudioOriginal':
        return _serial(() => _saveOriginal(arguments));
      case 'exportAudioCopy':
      case 'exportAudioToDirectory':
        return _serial(() async {
          await _requireNoJournal();
          final source = await access.preparedFile(arguments['path'] as String);
          final directoryUri =
              arguments['directoryUri'] as String? ??
              await access.chooseExportDirectory();
          if (directoryUri == null) return null;
          return _export(source, arguments['fileName'] as String, directoryUri);
        });
      case 'recoverExport':
      case 'retryOriginalRecovery':
        return _serial(_recoveryNotice);
      case 'getOriginalRecoveryState':
        return _serial(_recoveryState);
      case 'restoreOriginalBackup':
        return _serial(_restoreOriginal);
      case 'exportOriginalRecoveryVersion':
        return _serial(
          () => _exportRecoveryVersion(arguments['versionId'] as String),
        );
      case 'finishOriginalRecovery':
        return _serial(() async {
          final journal = await _readJournal();
          if (journal == null) return null;
          final state = await _recoveryState();
          if (state?['canFinish'] != true) {
            throw PlatformException(
              code: 'recovery_pending',
              message: '请先安全导出所有不同版本，再结束恢复',
            );
          }
          await _clearJournal(journal);
          return null;
        });
      case 'confirmExportRecorded':
        return _serial(() async {
          final journal = await _readJournal();
          if (journal == null) return null;
          if (journal['targetUri'] != arguments['uri'] ||
              journal['status'] != 'saved' ||
              await _targetHash(journal) != journal['outputSha256']) {
            throw PlatformException(
              code: 'recovery_pending',
              message: '保存后的文件已变化，保留恢复记录',
            );
          }
          await _clearJournal(journal);
          return null;
        });
      case 'acknowledgeExportRecovery':
        return _serial(() async {
          final journal = await _readJournal();
          if (journal == null) return null;
          if (journal['kind'] == 'original') {
            throw PlatformException(
              code: 'recovery_pending',
              message: '请在原文件恢复面板中处理保留版本',
            );
          }
          // Acknowledge never deletes a user-destination file, even if partial.
          await _clearJournal(journal);
          return null;
        });
      default:
        throw MissingPluginException(
          'Windows filesystem method $method is unavailable',
        );
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) async {
    if (_busy) throw PlatformException(code: 'busy', message: '正在处理另一个保存或恢复操作');
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<String> _copyForRead(String uri) async {
    final source = await access.sourceFile(uri);
    if (await source.length() > 512 * 1024 * 1024) {
      throw PlatformException(code: 'read_too_large', message: '单文件超过 512 MiB');
    }
    final root = await access.privateDirectory('windows_read_copies');
    final directory = await root.createTemp('read_');
    final output = File(
      p.join(directory.path, 'source${p.extension(source.path)}'),
    );
    try {
      await copyWindowsFile(source, output);
      if (await output.length() > 512 * 1024 * 1024) {
        throw PlatformException(
          code: 'read_too_large',
          message: '单文件超过 512 MiB',
        );
      }
      // A snapshot racing an external edit is never accepted as coherent input.
      if (await windowsFileSha256(output) != await windowsFileSha256(source)) {
        throw PlatformException(
          code: 'source_changed',
          message: '音频正在被其他程序更改，请稍后重新读取',
        );
      }
      _readCopies.add(output.path);
      return output.path;
    } catch (_) {
      if (await output.exists()) await output.delete();
      if (await directory.list().isEmpty) await directory.delete();
      rethrow;
    }
  }

  Future<Directory> _recoveryDirectory() =>
      access.privateDirectory('windows_recovery');

  Future<File> _journalFile() async =>
      File(p.join((await _recoveryDirectory()).path, 'pending.json'));

  Future<Map<String, dynamic>?> _readJournal() async {
    final file = await _journalFile();
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.equals(await file.resolveSymbolicLinks(), file.path)) {
      throw const FormatException('恢复记录路径无效');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        !const ['original', 'export'].contains(value['kind']) ||
        value['targetUri'] is! String ||
        value['outputSha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['outputSha256'] as String)) {
      throw const FormatException('恢复记录无效；为保留原文件，已停止写入');
    }
    access.filePath(value['targetUri'] as String);
    if (value['kind'] == 'original') {
      if (value['session'] is! String ||
          !RegExp(r'^save_[a-zA-Z0-9_-]+$')
              .hasMatch(value['session'] as String) ||
          value['versions'] is! List) {
        throw const FormatException('原文件备份记录无效');
      }
      for (final item in value['versions'] as List) {
        if (item is! Map ||
            item['id'] is! String ||
            item['fileName'] is! String ||
            !RegExp(r'^[a-zA-Z0-9_-]+\.audio$')
                .hasMatch(item['fileName'] as String) ||
            item['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(item['sha256'] as String) ||
            item['sizeBytes'] is! int ||
            item['label'] is! String) {
          throw const FormatException('原文件备份版本无效');
        }
      }
    }
    return value;
  }

  Future<void> _writeJournal(Map<String, dynamic> value) async =>
      writeWindowsJson(await _journalFile(), value);

  Future<void> _requireNoJournal() async {
    if (await _readJournal() != null) {
      throw PlatformException(
        code: 'recovery_pending',
        message: '请先处理上次保存的恢复提醒，再进行新的写入',
      );
    }
  }

  Future<File> _versionFile(
    Map<String, dynamic> journal,
    Map<String, dynamic> version,
  ) async {
    final root = await _recoveryDirectory();
    final file = File(
      p.join(
        root.path,
        journal['session'] as String,
        version['fileName'] as String,
      ),
    );
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.equals(await file.resolveSymbolicLinks(), file.path) ||
        await file.length() != version['sizeBytes'] ||
        await windowsFileSha256(file) != version['sha256']) {
      throw PlatformException(
        code: 'recovery_invalid',
        message: '保留版本不存在或校验失败，已停止恢复及清理',
      );
    }
    return file;
  }

  List<Map<String, dynamic>> _versions(Map<String, dynamic> journal) =>
      (journal['versions'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();

  Future<String> _saveOriginal(Map<String, dynamic> arguments) async {
    await _requireNoJournal();
    final uri = arguments['sourceUri'] as String;
    final expectedSourceHash = arguments['sourceSha256'] as String;
    final source = await access.sourceFile(uri, forWrite: true);
    final prepared = await access.preparedFile(arguments['path'] as String);
    if (await source.length() > 512 * 1024 * 1024 ||
        await prepared.length() > 512 * 1024 * 1024) {
      throw PlatformException(code: 'read_too_large', message: '单文件超过 512 MiB');
    }
    final root = await _recoveryDirectory();
    final session = await root.createTemp('save_');
    final original = File(p.join(session.path, 'original.audio'));
    final tagged = File(p.join(session.path, 'tagged.audio'));
    final handle = await source.open(mode: FileMode.append);
    var locked = false;
    var writing = false;
    Map<String, dynamic>? journal;
    try {
      await handle.lock(FileLock.exclusive);
      locked = true;
      if (await _handleHash(handle) != expectedSourceHash) {
        throw PlatformException(
          code: 'source_changed',
          message: '原文件自审核后已变化，请重新读取与审核',
        );
      }
      await _handleToFile(handle, original);
      if (await windowsFileSha256(original) != expectedSourceHash) {
        throw PlatformException(
          code: 'source_changed',
          message: '原文件备份校验不通过，未写入',
        );
      }
      await copyWindowsFile(prepared, tagged);
      final outputHash = await windowsFileSha256(tagged);
      if (outputHash != await windowsFileSha256(prepared)) {
        throw PlatformException(
          code: 'source_changed',
          message: '待写入副本已变化，未写入',
        );
      }
      journal = {
        'version': 1,
        'kind': 'original',
        'status': 'prepared',
        'session': p.basename(session.path),
        'targetUri': uri,
        'sourceSha256': expectedSourceHash,
        'outputSha256': outputHash,
        'versions': [
          await _version('original', '原始备份', original, expectedSourceHash),
          await _version('tagged', '已校验的修复版本', tagged, outputHash),
        ],
      };
      // Backup bytes and journal are flushed before the first target mutation.
      await _writeJournal(journal);
      await access.sourceFile(uri, forWrite: true);
      if (await _handleHash(handle) != expectedSourceHash) {
        throw PlatformException(
          code: 'source_changed',
          message: '原文件在写入前发生变化，备份已保留',
        );
      }
      journal['status'] = 'writing';
      await _writeJournal(journal);
      writing = true;
      await _fileToHandle(tagged, handle);
      if (await _handleHash(handle) != outputHash) {
        throw PlatformException(
          code: 'original_save_failed',
          message: '写入后的文件摘要校验失败',
        );
      }
      journal['status'] = 'saved';
      await _writeJournal(journal);
    } catch (error) {
      if (writing && journal != null) {
        try {
          await _fileToHandle(original, handle);
          if (await _handleHash(handle) != expectedSourceHash) {
            throw const FileSystemException('原始备份恢复校验失败');
          }
          journal['status'] = 'rolledBack';
          await _writeJournal(journal);
        } catch (_) {
          // Never hide the durable original/tagged copies when rollback fails.
          throw PlatformException(
            code: 'original_recovery_required',
            message: '保存或回滚未完成，已保留备份。请先在恢复面板处理，勿清除应用数据',
          );
        }
      }
      rethrow;
    } finally {
      try {
        if (locked) await handle.unlock();
      } finally {
        await handle.close();
      }
      if (journal == null) {
        for (final file in [original, tagged]) {
          if (await file.exists()) await file.delete();
        }
        if (await session.list().isEmpty) await session.delete();
      }
    }
    // Verify the live pathname too: a concurrent rename must not report success
    // for a detached handle. Unknown current content is never auto-overwritten.
    if (await _targetHash(journal) != journal['outputSha256']) {
      throw PlatformException(
        code: 'original_recovery_required',
        message: '原文件路径在保存时发生变化，已保留全部备份，请检查恢复面板',
      );
    }
    return uri;
  }

  Future<Map<String, dynamic>> _version(
    String id,
    String label,
    File file,
    String hash,
  ) async => {
    'id': id,
    'label': label,
    'fileName': p.basename(file.path),
    'sha256': hash,
    'sizeBytes': await file.length(),
  };

  Future<String> _export(File source, String name, String directoryUri) async {
    final directory = await access.exportDirectory(directoryUri);
    final hash = await windowsFileSha256(source);
    final output = await createWindowsOutput(directory, name);
    final journal = <String, dynamic>{
      'version': 1,
      'kind': 'export',
      'status': 'writing',
      'targetUri': output.uri.toString(),
      'outputSha256': hash,
    };
    try {
      await _writeJournal(journal);
      await copyWindowsReservedOutput(source, output);
      if (await windowsFileSha256(output) != hash) {
        throw PlatformException(
          code: 'export_failed',
          message: '副本保存校验失败，请检查目标位置，可能保留不完整副本',
        );
      }
      journal['status'] = 'saved';
      await _writeJournal(journal);
      return output.uri.toString();
    } catch (_) {
      // The journal keeps the exact partial path; never erase unknown bytes.
      rethrow;
    }
  }

  Future<String?> _targetHash(Map<String, dynamic> journal) async {
    try {
      final file = journal['kind'] == 'original'
          ? await access.sourceFile(journal['targetUri'] as String)
          : File(access.filePath(journal['targetUri'] as String));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !p.equals(await file.resolveSymbolicLinks(), file.path)) {
        return null;
      }
      return await windowsFileSha256(file);
    } on FileSystemException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<String?> _recoveryNotice() async {
    final journal = await _readJournal();
    if (journal == null) return null;
    final hash = await _targetHash(journal);
    final path = access.filePath(journal['targetUri'] as String);
    if (journal['kind'] == 'export') {
      return hash == journal['outputSha256']
          ? '上次副本已完整保存，任务记录可能未更新。请核对：$path'
          : '上次副本保存未确认完整，目标位置可能有不完整文件。请核对：$path';
    }
    if (hash == journal['sourceSha256']) {
      return '原文件与原始备份一致；保留了上次保存的恢复版本，请核对后处理。';
    }
    if (hash == journal['outputSha256']) {
      return '原文件与已校验的修复版本一致；任务记录可能未更新。已保留原始备份，请在恢复面板确认。';
    }
    return '原文件已变化或暂时不可访问。未自动覆盖；原始备份与修复版本仍保留，请在恢复面板选择处理方式。';
  }

  Future<Map<String, dynamic>?> _recoveryState() async {
    final journal = await _readJournal();
    if (journal == null || journal['kind'] != 'original') return null;
    final current = await _targetHash(journal);
    final versions = _versions(journal);
    var intact = true;
    var allPreserved = true;
    for (final version in versions) {
      try {
        await _versionFile(journal, version);
      } catch (_) {
        intact = false;
      }
      if (version['sha256'] == current) continue;
      final exportedUri = version['exportedUri'];
      if (exportedUri is! String ||
          await _targetHash({'kind': 'export', 'targetUri': exportedUri}) !=
              version['sha256']) {
        allPreserved = false;
      }
    }
    var writable = false;
    try {
      await access.sourceFile(journal['targetUri'] as String, forWrite: true);
      writable = true;
    } catch (_) {
      // A disconnected or redirected target cannot safely be restored.
    }
    final knownCurrent =
        current != null && versions.any((v) => v['sha256'] == current);
    return {
      'status': current == journal['sourceSha256']
          ? 'originalIntact'
          : current == journal['outputSha256']
          ? 'saved'
          : 'conflict',
      'targetUri': journal['targetUri'],
      'canRestore': intact && writable && current != journal['sourceSha256'],
      'canFinish': intact && allPreserved && knownCurrent,
      'versions': versions,
    };
  }

  Future<String?> _restoreOriginal() async {
    final journal = await _readJournal();
    if (journal == null || journal['kind'] != 'original') return null;
    final versions = _versions(journal);
    final originalVersion = versions.singleWhere((v) => v['id'] == 'original');
    final original = await _versionFile(journal, originalVersion);
    final source = await access.sourceFile(
      journal['targetUri'] as String,
      forWrite: true,
    );
    final handle = await source.open(mode: FileMode.append);
    var locked = false;
    try {
      await handle.lock(FileLock.exclusive);
      locked = true;
      final currentHash = await _handleHash(handle);
      if (currentHash == originalVersion['sha256']) {
        return '原文件已经与原始备份一致，未重复写入。';
      }
      final retainedCurrent = versions
          .where((v) => v['sha256'] == currentHash)
          .toList();
      if (retainedCurrent.isNotEmpty) {
        await _versionFile(journal, retainedCurrent.first);
      } else {
        final root = await _recoveryDirectory();
        final file = File(
          p.join(
            root.path,
            journal['session'] as String,
            'current_${DateTime.now().microsecondsSinceEpoch}.audio',
          ),
        );
        await _handleToFile(handle, file);
        if (await windowsFileSha256(file) != currentHash) {
          throw PlatformException(
            code: 'recovery_invalid',
            message: '当前版本未能安全保留，未恢复原始备份',
          );
        }
        versions.add(
          await _version(
            p.basenameWithoutExtension(file.path),
            '恢复前保留的当前版本',
            file,
            currentHash,
          ),
        );
        journal['versions'] = versions;
      }
      journal['status'] = 'restoring';
      await _writeJournal(journal);
      await access.sourceFile(journal['targetUri'] as String, forWrite: true);
      if (await _handleHash(handle) != currentHash) {
        throw PlatformException(
          code: 'source_changed',
          message: '当前版本已变化，未开始恢复',
        );
      }
      await _fileToHandle(original, handle);
      if (await _handleHash(handle) != originalVersion['sha256']) {
        throw PlatformException(
          code: 'original_recovery_required',
          message: '恢复结果校验失败，全部版本仍保留',
        );
      }
      journal['status'] = 'restored';
      await _writeJournal(journal);
    } finally {
      try {
        if (locked) await handle.unlock();
      } finally {
        await handle.close();
      }
    }
    if (await _targetHash(journal) != originalVersion['sha256']) {
      throw PlatformException(
        code: 'original_recovery_required',
        message: '恢复时原文件路径发生变化，全部版本仍保留',
      );
    }
    return '已恢复并校验原始备份；不同的修复版本与恢复前版本仍保留，请先导出再结束恢复。';
  }

  Future<String?> _exportRecoveryVersion(String id) async {
    final journal = await _readJournal();
    if (journal == null || journal['kind'] != 'original') return null;
    final versions = _versions(journal);
    final matches = versions.where((v) => v['id'] == id).toList();
    if (matches.length != 1) throw const FormatException('未知恢复版本');
    final version = matches.single;
    final source = await _versionFile(journal, version);
    final directoryUri = await access.chooseExportDirectory(
      title: '选择恢复版本副本的保存文件夹',
    );
    if (directoryUri == null) return null;
    final directory = await access.exportDirectory(directoryUri);
    final target = File(access.filePath(journal['targetUri'] as String));
    final output = await createWindowsOutput(
      directory,
      '${p.basenameWithoutExtension(target.path)}-$id${p.extension(target.path)}',
    );
    await copyWindowsReservedOutput(source, output);
    if (await windowsFileSha256(output) != version['sha256']) {
      throw PlatformException(
        code: 'recovery_export_failed',
        message: '恢复版本副本校验失败，原备份仍保留，请检查目标文件',
      );
    }
    version['exportedUri'] = output.uri.toString();
    journal['versions'] = versions;
    await _writeJournal(journal);
    return output.uri.toString();
  }

  Future<void> _clearJournal(Map<String, dynamic> journal) async {
    // Remove only exact owned files from the validated journal. Unknown contents
    // are left in place; no recursive deletion of a derived path is performed.
    if (journal['kind'] == 'original') {
      final versions = _versions(journal);
      final files = <File>[];
      for (final version in versions) {
        files.add(await _versionFile(journal, version));
      }
      // Removing the journal first means a crash can leave only harmless backups,
      // never an unrecoverable active record that points at removed versions.
      await (await _journalFile()).delete();
      for (final file in files) {
        await file.delete();
      }
      final directory = files.first.parent;
      if (await directory.list().isEmpty) await directory.delete();
    } else {
      await (await _journalFile()).delete();
    }
  }
}

class _HashSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

Future<String> _handleHash(RandomAccessFile handle) async {
  await handle.setPosition(0);
  final result = _HashSink();
  final sink = sha256.startChunkedConversion(result);
  while (true) {
    final bytes = await handle.read(1024 * 1024);
    if (bytes.isEmpty) break;
    sink.add(bytes);
  }
  sink.close();
  return result.digest.toString();
}

Future<void> _handleToFile(RandomAccessFile handle, File file) async {
  await handle.setPosition(0);
  final output = await file.open(mode: FileMode.write);
  try {
    while (true) {
      final bytes = await handle.read(1024 * 1024);
      if (bytes.isEmpty) break;
      await output.writeFrom(bytes);
    }
    await output.flush();
  } finally {
    await output.close();
  }
}

Future<void> _fileToHandle(File file, RandomAccessFile handle) async {
  await handle.setPosition(0);
  final input = await file.open();
  var length = 0;
  try {
    while (true) {
      final bytes = await input.read(1024 * 1024);
      if (bytes.isEmpty) break;
      await handle.writeFrom(bytes);
      length += bytes.length;
    }
    await handle.truncate(length);
    await handle.flush();
  } finally {
    await input.close();
  }
}
