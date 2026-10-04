import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models/audio_track.dart';
import '../../core/services/device_artwork_cache.dart';
import 'track_artwork.dart';

class LibraryTrackArtwork extends StatefulWidget {
  const LibraryTrackArtwork({
    super.key,
    required this.track,
    this.cache,
    this.size = 52,
    this.onError,
    this.onLoaded,
  });

  final AudioTrack track;
  final DeviceArtworkCache? cache;
  final double size;
  final ValueChanged<String>? onError;
  final VoidCallback? onLoaded;

  @override
  State<LibraryTrackArtwork> createState() => _LibraryTrackArtworkState();
}

class _LibraryTrackArtworkState extends State<LibraryTrackArtwork> {
  ArtworkThumbnailRequest? _request;
  Uint8List? _bytes;
  bool _pathFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LibraryTrackArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache ||
        oldWidget.track.artworkPath != widget.track.artworkPath ||
        oldWidget.track.artworkError != widget.track.artworkError ||
        _request?.key != widget.cache?.keyFor(widget.track)) {
      _pathFailed = false;
      _load();
    }
  }

  void _load() {
    _request?.release();
    _request = null;
    _bytes = null;
    final cache = widget.cache;
    if (cache == null ||
        !widget.track.isDeviceTrack ||
        (hasText(widget.track.artworkPath) &&
            widget.track.artworkError == null &&
            !_pathFailed)) {
      return;
    }
    final request = cache.request(widget.track);
    _request = request;
    request.result.then((bytes) {
      if (mounted && identical(_request, request)) {
        setState(() => _bytes = bytes);
      }
    });
  }

  @override
  void dispose() {
    _request?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TrackArtwork(
    path: _pathFailed || widget.track.artworkError != null
        ? null
        : widget.track.artworkPath,
    placeholderLabel: _pathFailed || widget.track.artworkError != null
        ? '封面无法显示'
        : '暂无封面',
    onLoaded: () {
      if (!_pathFailed &&
          widget.track.artworkError == null &&
          hasText(widget.track.artworkPath)) {
        widget.onLoaded?.call();
      }
    },
    onError: (message) {
      widget.onError?.call(message);
      if (!_pathFailed && hasText(widget.track.artworkPath)) {
        setState(() {
          _pathFailed = true;
          _load();
        });
      }
    },
    bytes: _bytes,
    size: widget.size,
    validationPending: !widget.track.hasArtwork,
  );
}
