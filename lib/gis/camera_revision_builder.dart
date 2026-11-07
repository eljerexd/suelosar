import 'package:flutter/widgets.dart';

/// Rebuilds projection-dependent overlays whenever the map camera changes.
class CameraRevisionBuilder extends StatelessWidget {
  const CameraRevisionBuilder({
    required this.cameraChanges,
    required this.builder,
    super.key,
  });

  final Listenable cameraChanges;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: cameraChanges,
    builder: (context, _) => builder(context),
  );
}
