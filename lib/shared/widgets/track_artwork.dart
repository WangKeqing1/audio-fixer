import 'dart:io';

import 'package:flutter/material.dart';

class TrackArtwork extends StatelessWidget {
  const TrackArtwork({super.key, this.path, this.size = 56});
  final String? path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = Semantics(
      label: '暂无封面',
      image: true,
      child: ColoredBox(
        color: colors.secondaryContainer,
        child: Center(
          child: Icon(
            Icons.album_outlined,
            size: size * .5,
            color: colors.onSecondaryContainer,
          ),
        ),
      ),
    );
    final hasArtwork = path != null && path!.trim().isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size >= 160 ? 24 : 12),
      child: SizedBox.square(
        dimension: size,
        child: !hasArtwork
            ? fallback
            : Image.file(
                File(path!),
                fit: BoxFit.cover,
                semanticLabel: '音频内嵌封面',
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
