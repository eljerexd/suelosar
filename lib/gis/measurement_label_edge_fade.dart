import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Returns a smooth opacity for a geographically anchored label rectangle.
///
/// The transition is based on the nearest edge clearance of the full label,
/// rather than its geographic anchor, so wide cards begin fading at the right
/// time as they enter or leave the map viewport.
double measurementLabelEdgeOpacity(
  Rect labelRect,
  Size viewport, {
  double fadeDistance = 56,
}) {
  if (!labelRect.left.isFinite ||
      !labelRect.top.isFinite ||
      !labelRect.right.isFinite ||
      !labelRect.bottom.isFinite ||
      !viewport.width.isFinite ||
      !viewport.height.isFinite ||
      labelRect.isEmpty ||
      viewport.width <= 0 ||
      viewport.height <= 0 ||
      !fadeDistance.isFinite ||
      fadeDistance <= 0) {
    return 0;
  }

  final edgeClearance = math.min(
    math.min(labelRect.left, viewport.width - labelRect.right),
    math.min(labelRect.top, viewport.height - labelRect.bottom),
  );
  final progress = ((edgeClearance + fadeDistance) / (2 * fadeDistance)).clamp(
    0.0,
    1.0,
  );
  return progress * progress * (3 - 2 * progress);
}
