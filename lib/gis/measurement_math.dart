import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Pure geodesic measurement math shared by every map engine.
///
/// Extracted from `_MeasurementLayer` (gis_map_screen.dart) so
/// `MapLibreEngine` can render distance/area readouts identical to
/// `FlutterMapEngine`'s, without duplicating the formulas. `_MeasurementLayer`
/// still owns the widget/UI side and simply delegates its private static
/// methods to these — its public behavior is unchanged.
const Distance measurementDistance = Distance(roundResult: false);
const double _wgs84AuthalicRadius = 6371007.1809;

String formatMeasurementDistance(double meters) {
  if (meters < 1000) {
    return '${meters.round()} m';
  }
  return '${(meters / 1000).toStringAsFixed(1)} km';
}

String formatMeasurementArea(double squareMeters) {
  if (squareMeters < 10000) {
    return '${squareMeters.round()} m²';
  }
  return '${(squareMeters / 10000).toStringAsFixed(1)} ha';
}

double calculateMeasurementPerimeter(List<LatLng> points) {
  var perimeter = 0.0;
  for (var index = 0; index < points.length; index++) {
    perimeter += measurementDistance(
      points[index],
      points[(index + 1) % points.length],
    );
  }
  return perimeter;
}

double calculateMeasurementPathDistance(List<LatLng> points) {
  var distance = 0.0;
  for (var index = 1; index < points.length; index++) {
    distance += measurementDistance(points[index - 1], points[index]);
  }
  return distance;
}

double calculateMeasurementArea(List<LatLng> points) {
  var sum = 0.0;
  for (var index = 0; index < points.length; index++) {
    final current = points[index];
    final next = points[(index + 1) % points.length];
    sum +=
        _toRadians(next.longitude - current.longitude) *
        (2 +
            math.sin(_toRadians(current.latitude)) +
            math.sin(_toRadians(next.latitude)));
  }
  return (sum * _wgs84AuthalicRadius * _wgs84AuthalicRadius / 2).abs();
}

double _toRadians(double degrees) => degrees * math.pi / 180;

/// Approximate meters-per-screen-pixel at [zoom] and [latitude], using the
/// standard Web Mercator tile-size formula (256px tiles). Used to convert
/// FlutterMapEngine's screen-pixel hit-test thresholds into an equivalent
/// geographic distance for engines that cannot project LatLng<->screen
/// synchronously (MapLibre) — see [nearestMeasurementEdgeIndex].
double metersPerScreenPixel({required double zoom, required double latitude}) {
  return 156543.03392804097 *
      math.cos(_toRadians(latitude)) /
      math.pow(2, zoom);
}

/// Geometric distance from [point] to the segment `a`-`b`, in the same
/// planar unit as the input coordinates (meters, if `a`/`b`/`point` are a
/// local meters projection — see [nearestMeasurementEdgeIndex]).
double _distanceToSegmentXY(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final segX = bx - ax;
  final segY = by - ay;
  final lengthSquared = segX * segX + segY * segY;
  if (lengthSquared == 0) {
    final dx = px - ax;
    final dy = py - ay;
    return math.sqrt(dx * dx + dy * dy);
  }
  final t = (((px - ax) * segX + (py - ay) * segY) / lengthSquared).clamp(
    0.0,
    1.0,
  );
  final closestX = ax + segX * t;
  final closestY = ay + segY * t;
  final dx = px - closestX;
  final dy = py - closestY;
  return math.sqrt(dx * dx + dy * dy);
}

/// Finds the index of the segment (in `points`, treated as closed if
/// [closed]) nearest to [tapPoint], for engines without synchronous
/// screen<->geo projection (MapLibre). Mirrors FlutterMapEngine's
/// `_nearestMeasurementEdgeIndex` (gis_map_screen.dart), which does the
/// equivalent comparison in screen pixels — this does it in a local
/// equirectangular meters projection around [tapPoint] instead, using
/// [metersPerScreenPixel] at the current [zoom]/[latitude] to convert the
/// same ~14px hit-test radius into an equivalent geographic distance.
/// Returns null if no segment is within that radius (caller then appends
/// the new point at the end, same fallback as the screen-based version).
int? nearestMeasurementEdgeIndex({
  required LatLng tapPoint,
  required List<LatLng> points,
  required bool closed,
  required double zoom,
  double pixelThreshold = 14,
}) {
  if (points.length < 2) return null;
  final metersPerDegreeLat = 111320.0;
  final metersPerDegreeLng =
      111320.0 * math.cos(_toRadians(tapPoint.latitude));
  double xOf(LatLng p) =>
      (p.longitude - tapPoint.longitude) * metersPerDegreeLng;
  double yOf(LatLng p) => (p.latitude - tapPoint.latitude) * metersPerDegreeLat;

  final thresholdMeters =
      pixelThreshold *
      metersPerScreenPixel(zoom: zoom, latitude: tapPoint.latitude);
  var nearestDistance = thresholdMeters;
  int? nearestIndex;
  final segmentCount = closed ? points.length : points.length - 1;
  for (var index = 0; index < segmentCount; index++) {
    final start = points[index];
    final end = points[(index + 1) % points.length];
    final distance = _distanceToSegmentXY(
      0,
      0,
      xOf(start),
      yOf(start),
      xOf(end),
      yOf(end),
    );
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestIndex = index;
    }
  }
  return nearestIndex;
}
