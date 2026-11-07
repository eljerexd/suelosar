import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:suelosar/gis/engine/maplibre_measurement_styles.dart';
import 'package:suelosar/gis/measurement_render_style.dart';

void main() {
  test('typed MapLibre line width matches the unoutlined FlutterMap line', () {
    final style = MeasurementRenderStyles.normalSaved.distance;
    final foreground = MapLibreMeasurementStyles.line(
      id: 'foreground',
      sourceId: 'measurements',
      filter: const ml.Literal(true),
      color: const ml.Literal(Colors.blue),
      stroke: style,
    );

    expect(_paint(foreground)['line-width'], style.width);
    expect(_layout(foreground)['line-cap'], 'round');
    expect(_layout(foreground)['line-join'], 'round');
  });

  test('active area fill has no second outline stroke', () {
    final fill = MapLibreMeasurementStyles.areaFill(
      id: 'area-fill',
      sourceId: 'measurements',
      filter: const ml.Literal(true),
      color: const ml.Literal(Colors.blue),
      opacity: MeasurementRenderStyles.activeAreaFillOpacity,
    );
    final fillJson = fill.toJson();
    final paint = fillJson['paint']! as Map<String, Object?>;

    expect(paint['fill-opacity'], 0.25);
    expect(paint.containsKey('fill-outline-color'), isFalse);
    expect(
      _paint(
        MapLibreMeasurementStyles.line(
          id: 'area-outline',
          sourceId: 'measurements',
          filter: const ml.Literal(true),
          color: const ml.Literal(Colors.blue),
          stroke: MeasurementRenderStyles.activeAreaOutline,
        ),
      )['line-width'],
      3,
    );
  });

  test('each saved state maps to its established width and round geometry', () {
    for (final (state, lineWidth, areaWidth) in [
      (SavedMeasurementVisualState.normal, 4.0, 3.0),
      (SavedMeasurementVisualState.hovered, 5.5, 4.5),
      (SavedMeasurementVisualState.selected, 8.0, 6.0),
    ]) {
      final saved = MeasurementRenderStyles.saved(state);
      final line = MapLibreMeasurementStyles.line(
        id: 'saved-line',
        sourceId: 'measurements',
        filter: const ml.Literal(true),
        color: const ml.Literal(Colors.blue),
        stroke: saved.distance,
      );
      final area = MapLibreMeasurementStyles.line(
        id: 'saved-area',
        sourceId: 'measurements',
        filter: const ml.Literal(true),
        color: const ml.Literal(Colors.blue),
        stroke: saved.areaOutline,
      );

      expect(_paint(line)['line-width'], lineWidth);
      expect(_paint(area)['line-width'], areaWidth);
      expect(_layout(area)['line-cap'], 'round');
      expect(_layout(area)['line-join'], 'round');
    }
  });
}

Map<String, Object?> _paint(ml.StyleLayer layer) =>
    layer.toJson()['paint']! as Map<String, Object?>;

Map<String, Object?> _layout(ml.StyleLayer layer) =>
    layer.toJson()['layout']! as Map<String, Object?>;
