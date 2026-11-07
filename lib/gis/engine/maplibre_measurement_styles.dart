import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maplibre/maplibre.dart' as ml;

import '../measurement_render_style.dart';

abstract final class MapLibreMeasurementStyles {
  static ml.LineStyleLayer line({
    required String id,
    required String sourceId,
    required ml.Expression<bool> filter,
    required ml.Expression<Color> color,
    required MeasurementStrokeStyle stroke,
  }) => ml.LineStyleLayer(
    id: id,
    sourceId: sourceId,
    filter: filter,
    color: color,
    width: ml.Literal(stroke.width),
    cap: ml.Literal(_lineCap(stroke.cap)),
    join: ml.Literal(_lineJoin(stroke.join)),
  );

  static ml.FillStyleLayer areaFill({
    required String id,
    required String sourceId,
    required ml.Expression<bool> filter,
    required ml.Expression<Color> color,
    required double opacity,
  }) => ml.FillStyleLayer(
    id: id,
    sourceId: sourceId,
    filter: filter,
    color: color,
    opacity: ml.Literal(opacity),
  );

  static ml.LineCap _lineCap(ui.StrokeCap cap) => switch (cap) {
    ui.StrokeCap.butt => ml.LineCap.butt,
    ui.StrokeCap.round => ml.LineCap.round,
    ui.StrokeCap.square => ml.LineCap.square,
  };

  static ml.LineJoin _lineJoin(ui.StrokeJoin join) => switch (join) {
    ui.StrokeJoin.bevel => ml.LineJoin.bevel,
    ui.StrokeJoin.round => ml.LineJoin.round,
    ui.StrokeJoin.miter => ml.LineJoin.miter,
  };
}
