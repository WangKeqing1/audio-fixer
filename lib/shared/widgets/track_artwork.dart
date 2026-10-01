import 'dart:io';

import 'package:flutter/material.dart';

class TrackArtwork extends StatelessWidget {
  const TrackArtwork({super.key, this.path, this.size = 56});
  final String? path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.secondaryContainer,
      child: Center(
        child: Icon(
          Icons.album_outlined,
          size: size * .5,
          color: colors.onSecondaryContainer,
        ),
      ),
    );
    return Semantics(
      label: path == null ? '暂无封面' : '音频内嵌封面',
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox.square(
          dimension: size,
          child: path == null
              ? fallback
              : Image.file(
                  File(path!),
                  fit: BoxFit.cover,
                  cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}
