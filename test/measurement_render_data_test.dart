import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/measurement_render_data.dart';
import 'package:suelosar/models/saved_measurement.dart';

void main() {
  test('does not render the saved copy underneath its active editor copy', () {
    final editing = _measurement('editing');
    final other = _measurement('other');
    final hidden = _measurement('hidden', isVisible: false);

    final rendered = savedMeasurementsBehindEditor(
      measurements: [editing, other, hidden],
      editingMeasurementId: editing.id,
    );

    expect(rendered.map((measurement) => measurement.id), ['other']);
  });

  test('retains every visible saved measurement when no editor is active', () {
    final rendered = savedMeasurementsBehindEditor(
      measurements: [_measurement('first'), _measurement('second')],
      editingMeasurementId: null,
    );

    expect(rendered.map((measurement) => measurement.id), ['first', 'second']);
  });
}

SavedMeasurement _measurement(String id, {bool isVisible = true}) =>
    SavedMeasurement(
      id: id,
      type: SavedMeasurementType.distance,
      name: id,
      geometry: const [LatLng(-34, -58), LatLng(-34.01, -58.01)],
      createdAt: DateTime.utc(2026),
      isVisible: isVisible,
    );
