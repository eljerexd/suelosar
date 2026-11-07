import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/measurement_label_anchor.dart';
import 'package:suelosar/models/saved_measurement.dart';

void main() {
  test(
    'distance label anchor is geographic and survives persistence restore',
    () {
      final measurement = SavedMeasurement(
        id: 'distance-anchor',
        type: SavedMeasurementType.distance,
        name: 'Tramo',
        geometry: const [
          LatLng(-34.0, -58.0),
          LatLng(-34.2, -58.2),
          LatLng(-34.4, -58.4),
          LatLng(-34.6, -58.6),
        ],
        createdAt: DateTime.utc(2026),
      );
      final restored = SavedMeasurement.fromJson(measurement.toJson());

      expect(
        savedMeasurementLabelAnchor(measurement),
        const LatLng(-34.3, -58.3),
      );
      expect(
        savedMeasurementLabelAnchor(restored),
        savedMeasurementLabelAnchor(measurement),
      );
    },
  );

  test('area label anchor uses persisted geographic vertices', () {
    final measurement = SavedMeasurement(
      id: 'area-anchor',
      type: SavedMeasurementType.area,
      name: 'Lote',
      geometry: const [
        LatLng(-34.0, -58.0),
        LatLng(-34.0, -58.2),
        LatLng(-34.2, -58.2),
        LatLng(-34.2, -58.0),
      ],
      createdAt: DateTime.utc(2026),
    );

    expect(
      savedMeasurementLabelAnchor(measurement),
      const LatLng(-34.1, -58.1),
    );
  });
}
