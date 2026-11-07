import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/measurement_math.dart';

const Distance _baselineDistance = Distance(roundResult: false);
const double _baselineEarthRadius = 6371007.1809;

void main() {
  test('distance and perimeter preserve the prior geographic calculation', () {
    final paths = <List<LatLng>>[
      const [LatLng(-34.6037, -58.3816), LatLng(-34.61, -58.37)],
      const [
        LatLng(-34.6037, -58.3816),
        LatLng(-34.61, -58.37),
        LatLng(-34.62, -58.35),
        LatLng(-34.60, -58.33),
      ],
      const [LatLng(-34.6, -58.4), LatLng(-31.4, -64.2)],
    ];

    for (final points in paths) {
      expect(
        calculateMeasurementPathDistance(points),
        baselinePathDistance(points),
      );
      expect(calculateMeasurementPerimeter(points), baselinePerimeter(points));
      expect(
        formatMeasurementDistance(calculateMeasurementPathDistance(points)),
        baselineFormatDistance(baselinePathDistance(points)),
      );
    }
  });

  test('area results and formatting preserve the prior spherical formula', () {
    final polygons = <List<LatLng>>[
      const [
        LatLng(-34.60, -58.42),
        LatLng(-34.60, -58.40),
        LatLng(-34.62, -58.40),
        LatLng(-34.62, -58.42),
      ],
      const [
        LatLng(-34.60, -58.42),
        LatLng(-34.59, -58.39),
        LatLng(-34.63, -58.38),
        LatLng(-34.65, -58.41),
        LatLng(-34.62, -58.44),
      ],
      const [
        LatLng(-34.60, -58.42),
        LatLng(-34.60, -58.32),
        LatLng(-34.70, -58.32),
        LatLng(-34.70, -58.42),
      ],
    ];

    for (final points in polygons) {
      final area = calculateMeasurementArea(points);
      expect(area, baselineArea(points));
      expect(formatMeasurementArea(area), baselineFormatArea(area));
      expect(calculateMeasurementPerimeter(points), baselinePerimeter(points));
    }

    final sample = polygons.last;
    final beforeCameraMovement = calculateMeasurementArea(sample);
    final afterCameraMovement = calculateMeasurementArea(sample);
    expect(afterCameraMovement, beforeCameraMovement);
  });
}

double baselinePathDistance(List<LatLng> points) {
  var result = 0.0;
  for (var i = 1; i < points.length; i++) {
    result += _baselineDistance(points[i - 1], points[i]);
  }
  return result;
}

double baselinePerimeter(List<LatLng> points) {
  var result = 0.0;
  for (var i = 0; i < points.length; i++) {
    result += _baselineDistance(points[i], points[(i + 1) % points.length]);
  }
  return result;
}

double baselineArea(List<LatLng> points) {
  var sum = 0.0;
  for (var i = 0; i < points.length; i++) {
    final current = points[i];
    final next = points[(i + 1) % points.length];
    sum +=
        _radians(next.longitude - current.longitude) *
        (2 +
            math.sin(_radians(current.latitude)) +
            math.sin(_radians(next.latitude)));
  }
  return (sum * _baselineEarthRadius * _baselineEarthRadius / 2).abs();
}

double _radians(double value) => value * math.pi / 180;

String baselineFormatDistance(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(1)} km';

String baselineFormatArea(double squareMeters) => squareMeters < 10000
    ? '${squareMeters.round()} m²'
    : '${(squareMeters / 10000).toStringAsFixed(1)} ha';
