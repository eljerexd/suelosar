import '../models/saved_measurement.dart';

/// Omits a saved measurement while its editable copy is rendered as the active
/// measurement, preventing the two strokes from being composited together.
List<SavedMeasurement> savedMeasurementsBehindEditor({
  required Iterable<SavedMeasurement> measurements,
  required String? editingMeasurementId,
}) => [
  for (final measurement in measurements)
    if (measurement.isVisible && measurement.id != editingMeasurementId)
      measurement,
];
