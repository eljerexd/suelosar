import 'package:latlong2/latlong.dart';

import '../models/saved_measurement.dart';

/// Stable geographic anchor used for saved measurement labels.
///
/// The anchor is derived from persisted geographic geometry rather than a
/// cached screen position, so restoring the measurement produces the same
/// location and map movement only changes its screen projection.
LatLng? savedMeasurementLabelAnchor(SavedMeasurement measurement) {
  final points = measurement.geometry;
  if (measurement.type == SavedMeasurementType.distance) {
    if (points.length < 2) return null;
    final index = points.length ~/ 2;
    final start = points[index - 1];
    final end = points[index];
    return LatLng(
      (start.latitude + end.latitude) / 2,
      (start.longitude + end.longitude) / 2,
    );
  }
  if (points.length < 3) return null;
  return LatLng(
    points.fold<double>(0, (sum, point) => sum + point.latitude) /
        points.length,
    points.fold<double>(0, (sum, point) => sum + point.longitude) /
        points.length,
  );
}
