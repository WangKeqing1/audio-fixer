import 'package:flutter/material.dart';

/// A quiet entrance for new content. The same subtree stays mounted on resize;
/// there is never an outgoing, still-interactive copy of a form or song pane.
class PaneEntrance extends StatelessWidget {
  const PaneEntrance({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reducedMotion ? 1 : 0, end: 1),
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: child,
      builder: (context, opacity, child) =>
          Opacity(opacity: reducedMotion ? 1 : opacity, child: child),
    );
  }
}
