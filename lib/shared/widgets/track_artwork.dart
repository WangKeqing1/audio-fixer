import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class TrackArtwork extends StatefulWidget {
  const TrackArtwork({
    super.key,
    this.path,
    this.bytes,
    this.size = 56,
    this.placeholderLabel = '暂无封面',
    this.onError,
    this.onLoaded,
    this.validationPending = false,
  });
  final String? path;
  final Uint8List? bytes;
  final double size;
  final String placeholderLabel;
  final ValueChanged<String>? onError;
  final VoidCallback? onLoaded;
  final bool validationPending;

  @override
  State<TrackArtwork> createState() => _TrackArtworkState();
}

class _TrackArtworkState extends State<TrackArtwork> {
  bool _errorReported = false;
  bool _loadedReported = false;
  int _generation = 0;

  @override
  void didUpdateWidget(TrackArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.validationPending && !oldWidget.validationPending) {
      _loadedReported = false;
    }
    if (oldWidget.path != widget.path || oldWidget.bytes != widget.bytes) {
      _errorReported = false;
      _loadedReported = false;
      _generation++;
    }
  }

  Widget _fallback(BuildContext context, String label) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: label,
      image: true,
      child: ColoredBox(
        color: colors.secondaryContainer,
        child: Center(
          child: Icon(
            label == '暂无封面'
                ? Icons.album_outlined
                : Icons.broken_image_outlined,
            size: widget.size * .5,
            color: colors.onSecondaryContainer,
          ),
        ),
      ),
    );
  }

  Widget _imageFailed(BuildContext context, Object _, StackTrace? _) {
    if (!_errorReported) {
      _errorReported = true;
      final generation = _generation;
      // Image errors may arrive while widgets are building. Notify once after
      // the frame and ignore errors from a replaced/disposed image request.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) {
          widget.onError?.call('封面无法显示，请重新读取或手动更换封面。');
        }
      });
    }
    return _fallback(context, '封面无法显示');
  }

  Widget _imageFrame(BuildContext context, Widget child, int? frame, bool _) {
    if (frame != null && !_loadedReported) {
      _loadedReported = true;
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) widget.onLoaded?.call();
      });
    }
    return child;
  }

  @override
  Widget build(BuildContext context) {
    final hasPath = widget.path != null && widget.path!.trim().isNotEmpty;
    final cacheWidth = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.size >= 160 ? 24 : 12),
      child: SizedBox.square(
        dimension: widget.size,
        child: hasPath
            ? Image.file(
                File(widget.path!),
                fit: BoxFit.cover,
                semanticLabel: '音频内嵌封面',
                cacheWidth: cacheWidth,
                errorBuilder: _imageFailed,
                frameBuilder: _imageFrame,
              )
            : widget.bytes != null
            ? Image.memory(
                widget.bytes!,
                fit: BoxFit.cover,
                semanticLabel: '音频内嵌封面',
                cacheWidth: cacheWidth,
                errorBuilder: _imageFailed,
                frameBuilder: _imageFrame,
              )
            : _fallback(context, widget.placeholderLabel),
      ),
    );
  }
}
