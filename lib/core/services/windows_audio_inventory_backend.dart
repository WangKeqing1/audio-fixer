import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import 'audio_inventory_service.dart';
import 'windows_file_access.dart';
import 'windows_music_library.dart';

/// Streams a UTF-8 TXT for precisely the selected Windows music roots. A
/// cancelled save dialog retains the completed private report for Retry Save.
class WindowsAudioInventoryBackend implements AudioInventoryBackend {
  WindowsAudioInventoryBackend(this.library, this.access);
  final WindowsMusicLibrary library;
  final WindowsFileAccess access;
  final _progress = StreamController<AudioInventoryProgress>.broadcast();
  File? _report;
  int? _operationId;
  bool _busy = false;
  bool _cancelled = false;
  int _total = 0;
  int _scanned = 0;
  int _unreadable = 0;

  @override
  Stream<AudioInventoryProgress> get progress => _progress.stream;

  void _emit(AudioInventoryPhase phase) {
    _progress.add(
      AudioInventoryProgress(
        operationId: _operationId!,
        phase: phase,
        scanned: _scanned,
        total: _total,
        readFailures: _unreadable,
      ),
    );
  }

  AudioInventoryResult _result(
    AudioInventoryStatus status, {
    String? fileName,
    String? message,
    bool retry = false,
    bool partialDocument = false,
  }) => AudioInventoryResult(
    operationId: _operationId!,
    status: status,
    fileName: fileName,
    totalIndexed: _total,
    scanned: _scanned,
    metadataSuccess: _scanned - _unreadable,
    unreadable: _unreadable,
    volumeErrors: library.lastScanErrors,
    coveragePartial: library.lastScanErrors > 0,
    canRetrySave: retry,
    possiblePartialDocument: partialDocument,
    message: message,
  );

  @override
  Future<AudioInventoryResult> exportInventory({
    required int operationId,
  }) async {
    if (_busy) {
      return AudioInventoryResult(
        operationId: operationId,
        status: AudioInventoryStatus.busy,
      );
    }
    _busy = true;
    _operationId = operationId;
    _cancelled = false;
    _total = 0;
    _scanned = 0;
    _unreadable = 0;
    try {
      await _clearReport();
      _emit(AudioInventoryPhase.querying);
      final tracks = await library.querySongs();
      _total = tracks.length;
      if (_cancelled) {
        return _result(AudioInventoryStatus.cancelled, message: '已取消生成，未保存清单。');
      }
      final directory = await access.privateDirectory('windows_inventory');
      final stage = await directory.createTemp('report_');
      _report = File(p.join(stage.path, 'audio-inventory.txt'));
      final sink = _report!.openWrite(encoding: utf8);
      try {
        sink.writeln('Audio Fixer · Windows 音频资料清单');
        sink.writeln('生成时间：${DateTime.now().toIso8601String()}');
        sink.writeln('范围：仅所选音乐文件夹，不扫描整台电脑');
        for (final root in access.roots) {
          sink.writeln('文件夹：${_text(root)}');
        }
        sink.writeln('文件数：$_total');
        sink.writeln();
        _emit(AudioInventoryPhase.scanning);
        for (final track in tracks) {
          if (_cancelled) break;
          final details = await library.readDetails(track);
          if (_cancelled) break;
          _scanned++;
          if (details.readError != null) _unreadable++;
          sink.writeln('[$_scanned] ${_text(details.fileName)}');
          sink.writeln('路径：${_text(details.localPath)}');
          sink.writeln('大小：${details.sizeBytes} bytes');
          sink.writeln(
            '时长：${details.durationMs == null ? "未知" : "${details.durationMs} ms"}',
          );
          for (final field in AudioField.values) {
            final value = switch (field) {
              AudioField.artwork =>
                details.readError != null
                    ? '读取失败'
                    : hasText(details.artworkPath)
                    ? '有嵌入封面'
                    : '无',
              AudioField.lyrics =>
                details.readError != null
                    ? '读取失败'
                    : hasText(details.lyrics)
                    ? '有'
                    : '无',
              _ => details.valueOf(field),
            };
            sink.writeln('${field.label}：${_text(value ?? "")}');
          }
          if (details.readError != null) {
            sink.writeln('读取错误：${_text(details.readError!)}');
          }
          if (details.tagReadWarnings.isNotEmpty) {
            sink.writeln(
              '读取提醒：${details.tagReadWarnings.map(_text).join("；")}',
            );
          }
          sink.writeln();
          _emit(AudioInventoryPhase.scanning);
        }
        sink.writeln('已读取：$_scanned；资料读取失败：$_unreadable');
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (_cancelled) {
        await _clearReport();
        return _result(AudioInventoryStatus.cancelled, message: '已取消生成，未保存清单。');
      }
      return await _saveReport();
    } catch (_) {
      if (_cancelled) {
        await _clearReport();
        return _result(AudioInventoryStatus.cancelled, message: '已取消生成，未保存清单。');
      }
      // A failed generation is not a complete report and cannot be retried as one.
      await _clearReport();
      return _result(
        AudioInventoryStatus.failed,
        message: '清单生成失败，请确认所选音乐文件夹可读取后重试。',
      );
    } finally {
      _busy = false;
    }
  }

  @override
  Future<AudioInventoryResult> retrySave({required int operationId}) async {
    if (_busy) {
      return AudioInventoryResult(
        operationId: operationId,
        status: AudioInventoryStatus.busy,
      );
    }
    _operationId = operationId;
    _cancelled = false;
    if (_report == null || !await _report!.exists()) {
      return _result(AudioInventoryStatus.failed, message: '完整清单已不存在，请重新生成。');
    }
    _busy = true;
    try {
      return await _saveReport();
    } finally {
      _busy = false;
    }
  }

  Future<AudioInventoryResult> _saveReport() async {
    File? destination;
    try {
      _emit(AudioInventoryPhase.choosingDestination);
      final uri = await access.chooseExportDirectory(title: '选择 TXT 音频清单保存文件夹');
      if (_cancelled) {
        await _clearReport();
        return _result(AudioInventoryStatus.cancelled, message: '已取消保存，未保存清单。');
      }
      if (uri == null) {
        return _result(
          AudioInventoryStatus.cancelled,
          retry: true,
          message: '已取消选择保存位置，可再次选择文件夹保存完整清单。',
        );
      }
      final directory = await access.exportDirectory(uri);
      final report = _report!;
      final hash = await windowsFileSha256(report);
      _emit(AudioInventoryPhase.saving);
      final date = DateTime.now().toIso8601String().substring(0, 10);
      destination = await createWindowsOutput(
        directory,
        'audio-inventory-$date.txt',
      );
      await copyWindowsReservedOutput(report, destination);
      if (await windowsFileSha256(destination) != hash) {
        throw const FileSystemException('TXT 摘要校验失败');
      }
      // Cancellation after the final write cannot turn an actually saved report
      // into a claimed failure. Report the verified file and preserve the truth.
      final result = _result(
        AudioInventoryStatus.saved,
        fileName: p.basename(destination.path),
        message: '清单已完整保存并校验：${destination.path}',
      );
      await _clearReport();
      return result;
    } catch (_) {
      return _result(
        AudioInventoryStatus.failed,
        retry: _report != null,
        partialDocument: destination != null,
        message: destination == null
            ? '未能打开保存位置，可重试保存完整清单。'
            : '清单保存未能通过完整校验，目标位置可能有不完整 TXT，可重试保存。',
      );
    }
  }

  @override
  Future<bool> cancelExport({required int operationId}) async {
    if (_operationId != operationId) return false;
    _cancelled = true;
    if (!_busy) await _clearReport();
    return true;
  }

  Future<void> _clearReport() async {
    final file = _report;
    _report = null;
    if (file == null) return;
    if (await file.exists()) await file.delete();
    if (await file.parent.exists() && await file.parent.list().isEmpty) {
      await file.parent.delete();
    }
  }
}

String _text(String value) =>
    value.replaceAll('\r', '').replaceAll('\n', r'\n');
