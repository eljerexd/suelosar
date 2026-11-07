import 'dart:ui' as ui;

/// Shared foreground widths for measurement geometry. Distance strokes have
/// no casing so they use the same simple outline treatment as area edges.
class MeasurementStrokeStyle {
  const MeasurementStrokeStyle({required this.width});

  final double width;

  ui.StrokeCap get cap => ui.StrokeCap.round;
  ui.StrokeJoin get join => ui.StrokeJoin.round;
}

enum SavedMeasurementVisualState { normal, hovered, selected }

class SavedMeasurementRenderStyle {
  const SavedMeasurementRenderStyle({
    required this.areaFillOpacity,
    required this.areaOutline,
    required this.distance,
  });

  final double areaFillOpacity;
  final MeasurementStrokeStyle areaOutline;
  final MeasurementStrokeStyle distance;
}

abstract final class MeasurementRenderStyles {
  static const activeDistance = MeasurementStrokeStyle(width: 4);
  static const activeAreaOutline = MeasurementStrokeStyle(width: 3);
  static const activeAreaFillOpacity = 0.25;

  static const normalSaved = SavedMeasurementRenderStyle(
    areaFillOpacity: 0.25,
    areaOutline: MeasurementStrokeStyle(width: 3),
    distance: MeasurementStrokeStyle(width: 4),
  );
  static const hoveredSaved = SavedMeasurementRenderStyle(
    areaFillOpacity: 0.34,
    areaOutline: MeasurementStrokeStyle(width: 4.5),
    distance: MeasurementStrokeStyle(width: 5.5),
  );
  static const selectedSaved = SavedMeasurementRenderStyle(
    areaFillOpacity: 0.42,
    areaOutline: MeasurementStrokeStyle(width: 6),
    distance: MeasurementStrokeStyle(width: 8),
  );

  static SavedMeasurementRenderStyle saved(SavedMeasurementVisualState state) =>
      switch (state) {
        SavedMeasurementVisualState.normal => normalSaved,
        SavedMeasurementVisualState.hovered => hoveredSaved,
        SavedMeasurementVisualState.selected => selectedSaved,
      };
}
