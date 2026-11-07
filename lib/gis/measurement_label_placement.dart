import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Chooses a label offset once per stable measurement/viewport pair.
/// Camera movement changes only the geographic anchor projection; it cannot
/// flip the card to another side from frame to frame.
class MeasurementLabelPlacementCache {
  final Map<String, _Entry> _entries = {};

  Rect resolve({
    required String id,
    required Object geometryKey,
    required Offset anchor,
    required Size size,
    required Size viewport,
    required List<Rect> occupied,
    required EdgeInsets safeInsets,
  }) {
    final old = _entries[id];
    final offset =
        old != null &&
            old.geometryKey == geometryKey &&
            old.size == size &&
            old.viewport == viewport
        ? old.offset
        : _chooseOffset(
            anchor: anchor,
            size: size,
            viewport: viewport,
            occupied: occupied,
            safeInsets: safeInsets,
          );
    _entries[id] = _Entry(
      geometryKey: geometryKey,
      size: size,
      viewport: viewport,
      offset: offset,
    );
    return Rect.fromLTWH(
      anchor.dx + offset.dx,
      anchor.dy + offset.dy,
      size.width,
      size.height,
    );
  }

  void retainOnly(Iterable<String> ids) {
    final retained = ids.toSet();
    _entries.removeWhere((id, _) => !retained.contains(id));
  }

  Offset _chooseOffset({
    required Offset anchor,
    required Size size,
    required Size viewport,
    required List<Rect> occupied,
    required EdgeInsets safeInsets,
  }) {
    const gap = 12.0;
    final offsets = <Offset>[
      Offset(-size.width / 2, -size.height - gap),
      Offset(gap, -size.height / 2),
      Offset(-size.width - gap, -size.height / 2),
      Offset(-size.width / 2, gap),
      Offset(gap, -size.height - gap),
      Offset(-size.width - gap, -size.height - gap),
      Offset(gap, gap),
      Offset(-size.width - gap, gap),
    ];
    final bounds = Rect.fromLTRB(
      safeInsets.left,
      safeInsets.top,
      viewport.width - safeInsets.right,
      viewport.height - safeInsets.bottom,
    );
    Offset? fallback;
    var fallbackScore = double.infinity;
    for (final offset in offsets) {
      final candidate = Rect.fromLTWH(
        anchor.dx + offset.dx,
        anchor.dy + offset.dy,
        size.width,
        size.height,
      );
      final collision = occupied.fold<double>(0, (total, rect) {
        final intersection = rect.intersect(candidate);
        return total +
            (intersection.isEmpty
                ? 0
                : intersection.width * intersection.height);
      });
      final overflow =
          math.max(0, bounds.left - candidate.left) +
          math.max(0, candidate.right - bounds.right) +
          math.max(0, bounds.top - candidate.top) +
          math.max(0, candidate.bottom - bounds.bottom);
      if (bounds.contains(candidate.topLeft) &&
          bounds.contains(candidate.bottomRight) &&
          collision == 0) {
        return offset;
      }
      final score = collision * 1000 + overflow;
      if (score < fallbackScore) {
        fallback = offset;
        fallbackScore = score;
      }
    }
    return fallback ?? offsets.first;
  }
}

class _Entry {
  const _Entry({
    required this.geometryKey,
    required this.size,
    required this.viewport,
    required this.offset,
  });

  final Object geometryKey;
  final Size size;
  final Size viewport;
  final Offset offset;
}
