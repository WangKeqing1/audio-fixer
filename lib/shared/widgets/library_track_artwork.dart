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
  });

  final AudioTrack track;
  final DeviceArtworkCache? cache;
  final double size;

  @override
  State<LibraryTrackArtwork> createState() => _LibraryTrackArtworkState();
}

class _LibraryTrackArtworkState extends State<LibraryTrackArtwork> {
  ArtworkThumbnailRequest? _request;
  Uint8List? _bytes;

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
        _request?.key != widget.cache?.keyFor(widget.track)) {
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
        hasText(widget.track.artworkPath)) {
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
    path: widget.track.artworkPath,
    bytes: _bytes,
    size: widget.size,
  );
}
