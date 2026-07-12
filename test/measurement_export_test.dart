import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/export/measurement_export.dart';

void main() {
  const coordinates = <MeasurementExportCoordinate>[
    MeasurementExportCoordinate(latitude: -36.5, longitude: -60),
    MeasurementExportCoordinate(latitude: -36.5, longitude: -59.9),
    MeasurementExportCoordinate(latitude: -36.4, longitude: -59.9),
  ];

  final areaMeasurement = MeasurementExportData(
    id: 'measurement-1',
    type: MeasurementExportType.area,
    title: 'Lote norte',
    createdAt: DateTime.utc(2026, 7, 12, 10),
    coordinates: coordinates,
    areaSquareMeters: 25000,
    perimeterMeters: 800,
    color: 'orange',
  );

  test('GeoJSON exporter creates a closed WGS84 polygon feature', () {
    final decoded =
        jsonDecode(const MeasurementGeoJsonExporter().encode(areaMeasurement))
            as Map<String, dynamic>;
    final geometry = decoded['geometry'] as Map<String, dynamic>;
    final properties = decoded['properties'] as Map<String, dynamic>;
    final ring = (geometry['coordinates'] as List).single as List;

    expect(decoded['type'], 'Feature');
    expect(geometry['type'], 'Polygon');
    expect(ring, hasLength(4));
    expect(ring.first, <double>[-60, -36.5]);
    expect(ring.last, ring.first);
    expect(properties['id'], 'measurement-1');
    expect(properties['area_ha'], 2.5);
    expect(properties['color'], 'orange');
  });

  test('CSV exporter includes the required measurement fields', () {
    final csv = const MeasurementCsvExporter().encode(areaMeasurement);

    expect(
      csv,
      contains(
        '"Name","Type","Area (ha)","Perimeter (m)","Vertex count","Created date","Coordinates"',
      ),
    );
    expect(csv, contains('"Lote norte","Área","2.5000","800.00","3"'));
    expect(csv, contains('-36.500000, -60.000000'));
  });
}
