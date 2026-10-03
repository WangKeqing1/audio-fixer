import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/services/audio_preview_service.dart';
import '../../shared/formatters.dart';

/// Only this control listens to playback, leaving the song row and cover intact.
class AudioPreviewButton extends StatelessWidget {
  const AudioPreviewButton({
    super.key,
    required this.preview,
    required this.track,
    this.enabled = true,
    this.canActivate,
  });

  final AudioPreviewController preview;
  final AudioTrack track;
  final bool enabled;
  final bool Function()? canActivate;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preview,
    builder: (context, _) {
      final current = preview.track?.id == track.id;
      final playing = current && preview.isPlaying;
      final loading = current && preview.isLoading;
      final action = loading
          ? '取消试听'
          : playing
          ? '暂停试听'
          : '试听';
      return IconButton(
        key: ValueKey('preview-track-${track.id}'),
        tooltip: '$action ${track.displayTitle}',
        onPressed: enabled && !preview.isBlocked
            ? () {
                if (canActivate?.call() == false) return;
                unawaited(loading ? preview.stop() : preview.toggle(track));
              }
            : null,
        icon: loading
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                playing
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
      );
    },
  );
}

/// Local audition controls; its progress updates never notify the library.
class AudioPreviewPlayer extends StatefulWidget {
  const AudioPreviewPlayer({
    super.key,
    required this.preview,
    this.enabled = true,
    this.bottomSafeArea = true,
    this.canActivate,
  });

  final AudioPreviewController preview;
  final bool enabled;
  final bool bottomSafeArea;
  final bool Function()? canActivate;

  @override
  State<AudioPreviewPlayer> createState() => _AudioPreviewPlayerState();
}

class _AudioPreviewPlayerState extends State<AudioPreviewPlayer> {
  String? _dragTrackId;
  int? _dragSessionId;
  int? _shownSessionId;
  double? _dragPosition;

  @override
  void didUpdateWidget(covariant AudioPreviewPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview != widget.preview) {
      _dragTrackId = null;
      _dragSessionId = null;
      _shownSessionId = null;
      _dragPosition = null;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.preview,
    builder: (context, _) {
      final preview = widget.preview;
      final track = preview.track;
      final sessionId = preview.sessionId;
      if (_shownSessionId != sessionId || !preview.canSeek) {
        _dragTrackId = null;
        _dragSessionId = null;
        _dragPosition = null;
      }
      _shownSessionId = sessionId;
      final colors = Theme.of(context).colorScheme;
      if (track == null) {
        final error = preview.errorMessage;
        if (error == null) return const SizedBox.shrink();
        return Material(
          key: const ValueKey('audio-preview-player'),
          color: colors.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            bottom: widget.bottomSafeArea,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      key: const ValueKey('audio-preview-status'),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.error),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('audio-preview-close'),
                    onPressed: () => unawaited(preview.stop()),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('重试关闭试听'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      final enabled = widget.enabled && !preview.isBlocked;
      final duration = preview.durationMs;
      final position = _dragTrackId == track.id && _dragPosition != null
          ? _dragPosition!.round()
          : preview.positionMs;
      final message =
          preview.errorMessage ??
          (preview.isBlocked
              ? '保存文件中，试听已停止'
              : switch (preview.status) {
                  AudioPreviewStatus.loading => '正在加载…',
                  AudioPreviewStatus.playing => '正在试听',
                  AudioPreviewStatus.paused => '已暂停',
                  AudioPreviewStatus.completed => '播放完毕',
                  AudioPreviewStatus.error => '试听失败，请重试',
                  _ => '试听',
                });
      final action = preview.isLoading
          ? '取消试听'
          : preview.isPlaying
          ? '暂停试听'
          : preview.status == AudioPreviewStatus.completed
          ? '重新试听'
          : preview.status == AudioPreviewStatus.error
          ? '重试试听'
          : '继续试听';
      return Material(
        key: const ValueKey('audio-preview-player'),
        color: colors.surfaceContainerHigh,
        elevation: 3,
        child: SafeArea(
          top: false,
          bottom: widget.bottomSafeArea,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        track.displayTitle,
                        key: const ValueKey('audio-preview-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('audio-preview-toggle'),
                      tooltip: action,
                      onPressed: enabled
                          ? () {
                              if (widget.canActivate?.call() == false) return;
                              unawaited(
                                preview.isLoading
                                    ? preview.stop()
                                    : preview.toggle(track),
                              );
                            }
                          : null,
                      icon: Icon(
                        preview.isLoading
                            ? Icons.stop_circle_outlined
                            : preview.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('audio-preview-close'),
                      tooltip: '关闭试听',
                      onPressed: () => unawaited(preview.stop()),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Semantics(
                  liveRegion: preview.errorMessage != null,
                  child: Text(
                    message,
                    key: const ValueKey('audio-preview-status'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: preview.errorMessage != null
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Slider(
                  key: const ValueKey('audio-preview-seek'),
                  value: position
                      .clamp(0, duration > 0 ? duration : 0)
                      .toDouble(),
                  max: duration > 0 ? duration.toDouble() : 1,
                  label: formatDuration(position),
                  semanticFormatterCallback: (value) =>
                      '试听进度 ${formatDuration(value.round())}',
                  onChangeStart: enabled && preview.canSeek
                      ? (value) => setState(() {
                          _dragTrackId = track.id;
                          _dragSessionId = sessionId;
                          _dragPosition = value;
                        })
                      : null,
                  onChanged: enabled && preview.canSeek
                      ? (value) {
                          if (_dragTrackId != track.id ||
                              _dragSessionId != sessionId ||
                              preview.sessionId != sessionId) {
                            return;
                          }
                          setState(() => _dragPosition = value);
                        }
                      : null,
                  onChangeEnd: enabled && preview.canSeek
                      ? (value) {
                          if (_dragTrackId == track.id &&
                              _dragSessionId == sessionId &&
                              preview.sessionId == sessionId &&
                              preview.track?.id == track.id) {
                            unawaited(preview.seek(value.round()));
                          }
                          setState(() {
                            _dragTrackId = null;
                            _dragSessionId = null;
                            _dragPosition = null;
                          });
                        }
                      : null,
                ),
                Text(
                  '${formatDuration(position)} / ${formatDuration(duration > 0 ? duration : null)}',
                  key: const ValueKey('audio-preview-position'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
