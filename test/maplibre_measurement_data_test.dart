import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/engine/maplibre_measurement_data.dart';
import 'package:suelosar/gis/engine/soil_map_engine.dart';
import 'package:suelosar/models/saved_measurement.dart';

void main() {
  test('keeps distance vertex order and exact longitude/latitude values', () {
    final data = MapLibreMeasurementData.build(
      distancePoints: [const LatLng(-34.5, -58.2), const LatLng(-34.6, -58.3)],
      areaPoints: const [],
      activeColor: Colors.orange,
      savedMeasurements: const [],
    );

    final collection = jsonDecode(data.active) as Map<String, dynamic>;
    final feature = (collection['features'] as List).single as Map;
    expect(feature['id'], 'active-distance');
    expect(feature['geometry']['coordinates'], [
      [-58.2, -34.5],
      [-58.3, -34.6],
    ]);
    expect(
      (collection['features'] as List).where(
        (feature) => feature['properties']['kind'] == 'active-area',
      ),
      isEmpty,
    );
  });

  test(
    'closes only the GeoJSON area ring and retains active outline order',
    () {
      final points = [
        const LatLng(-34.5, -58.2),
        const LatLng(-34.6, -58.3),
        const LatLng(-34.7, -58.4),
      ];
      final data = MapLibreMeasurementData.build(
        distancePoints: const [],
        areaPoints: points,
        activeColor: Colors.blue,
        savedMeasurements: const [],
      );

      final activeFeatures = (jsonDecode(data.active)['features'] as List)
          .cast<Map>();
      final areaFeature = activeFeatures.singleWhere(
        (feature) => feature['properties']['kind'] == 'active-area',
      );
      final ring = areaFeature['geometry']['coordinates'][0] as List;
      expect(ring, [
        [-58.2, -34.5],
        [-58.3, -34.6],
        [-58.4, -34.7],
        [-58.2, -34.5],
      ]);
      final outline = activeFeatures.singleWhere(
        (feature) => feature['properties']['kind'] == 'active-area-outline',
      );
      expect(outline['properties']['kind'], 'active-area-outline');
      expect(outline['geometry']['coordinates'], ring);
    },
  );

  test(
    'preserves saved ids, properties, geometry and visual state buckets',
    () {
      final measurements = [
        SavedMeasurement(
          id: 'distance-1',
          type: SavedMeasurementType.distance,
          name: 'Tramo',
          geometry: const [LatLng(-34.5, -58.2), LatLng(-34.6, -58.3)],
          createdAt: DateTime.utc(2026),
          colorId: 'orange',
        ),
        SavedMeasurement(
          id: 'area-1',
          type: SavedMeasurementType.area,
          name: 'Lote',
          geometry: const [
            LatLng(-34.1, -58.1),
            LatLng(-34.2, -58.2),
            LatLng(-34.3, -58.3),
          ],
          createdAt: DateTime.utc(2026),
          colorId: 'red',
        ),
      ];
      final data = MapLibreMeasurementData.build(
        distancePoints: const [],
        areaPoints: const [],
        activeColor: Colors.blue,
        savedMeasurements: measurements,
        highlightedId: 'area-1',
        hoveredId: 'distance-1',
      );

      final features = (jsonDecode(data.saved)['features'] as List)
          .cast<Map<String, dynamic>>();
      expect(features.map((feature) => feature['id']), [
        'distance-1',
        'area-1',
        'area-1:outline',
      ]);
      expect(features.first['properties']['measurementId'], 'distance-1');
      expect(features.first['properties']['state'], 'hovered');
      expect(features.first['properties']['kind'], 'saved-distance');
      expect(features[1]['properties']['state'], 'selected');
      expect(features[1]['geometry']['type'], 'Polygon');
      expect(features[2]['properties']['measurementId'], 'area-1');
      expect(features[2]['properties']['kind'], 'saved-area-outline');
    },
  );

  test('does not create native features for incomplete measurements', () {
    final data = MapLibreMeasurementData.build(
      distancePoints: const [LatLng(-34.5, -58.2)],
      areaPoints: const [LatLng(-34.5, -58.2), LatLng(-34.6, -58.3)],
      activeColor: Colors.blue,
      savedMeasurements: [
        SavedMeasurement(
          id: 'incomplete-area',
          type: SavedMeasurementType.area,
          name: 'Lote incompleto',
          geometry: const [LatLng(-34.5, -58.2), LatLng(-34.6, -58.3)],
          createdAt: DateTime.utc(2026),
        ),
      ],
    );
    final features = (jsonDecode(data.active)['features'] as List).cast<Map>();
    final outlines = features.where(
      (feature) => feature['properties']['kind'] == 'active-area-outline',
    );
    expect(outlines, hasLength(1));
    expect(outlines.single['geometry']['coordinates'], [
      [-58.2, -34.5],
      [-58.3, -34.6],
    ]);
    expect(
      features.where(
        (feature) => feature['properties']['kind'] == 'active-area',
      ),
      isEmpty,
    );
    expect(jsonDecode(data.saved)['features'], isEmpty);
  });

  test('line and numbered vertices share one replaceable snapshot', () {
    final moved = const LatLng(-34.8, -58.4);
    final previous = MapLibreMeasurementData.build(
      distancePoints: const [LatLng(-34.5, -58.2), LatLng(-34.6, -58.3)],
      areaPoints: const [],
      activeColor: Colors.blue,
      savedMeasurements: const [],
      activeMarkers: [
        _vertex(const LatLng(-34.5, -58.2), 1),
        _vertex(const LatLng(-34.6, -58.3), 2),
      ],
      snapshotVersion: 41,
    );
    final next = MapLibreMeasurementData.build(
      distancePoints: [const LatLng(-34.5, -58.2), moved],
      areaPoints: const [],
      activeColor: Colors.blue,
      savedMeasurements: const [],
      activeMarkers: [
        _vertex(const LatLng(-34.5, -58.2), 1),
        _vertex(moved, 2),
      ],
      snapshotVersion: 42,
    );

    final oldFeatures = (jsonDecode(previous.active)['features'] as List)
        .cast<Map>();
    final nextFeatures = (jsonDecode(next.active)['features'] as List)
        .cast<Map>();
    final line = nextFeatures.singleWhere(
      (feature) => feature['properties']['kind'] == 'active-distance',
    );
    final movedVertex = nextFeatures.singleWhere(
      (feature) => feature['id'] == 'active-vertex-1',
    );

    expect(line['geometry']['coordinates'].last, [
      moved.longitude,
      moved.latitude,
    ]);
    expect(movedVertex['geometry']['coordinates'], [
      moved.longitude,
      moved.latitude,
    ]);
    expect(nextFeatures, hasLength(3));
    expect(previous.active, isNot(next.active));
    expect(oldFeatures, hasLength(3));
    expect(jsonDecode(next.active)['properties']['snapshotVersion'], 42);
    expect(next.snapshotVersion, 42);
  });

  test('dragged vertices stay in the native geometry snapshot', () {
    final data = MapLibreMeasurementData.build(
      distancePoints: const [LatLng(-34.5, -58.2), LatLng(-34.6, -58.3)],
      areaPoints: const [],
      activeColor: Colors.blue,
      savedMeasurements: const [],
      activeMarkers: [
        _vertex(const LatLng(-34.5, -58.2), 1),
        SoilMapMeasurementMarker(
          point: const LatLng(-34.6, -58.3),
          size: const Size.square(44),
          label: '2',
          useFlutterOverlay: false,
          child: const SizedBox.shrink(),
        ),
      ],
    );
    final features = (jsonDecode(data.active)['features'] as List).cast<Map>();
    final vertices = features
        .where((feature) => feature['properties']['kind'] == 'active-vertex')
        .toList();

    expect(vertices[0]['properties']['useFlutterOverlay'], isFalse);
    expect(vertices[1]['properties']['useFlutterOverlay'], isFalse);
  });

  test('Flutter-only overlay markers do not create native vertex features', () {
    final data = MapLibreMeasurementData.build(
      distancePoints: const [LatLng(-34.5, -58.2), LatLng(-34.6, -58.3)],
      areaPoints: const [],
      activeColor: Colors.blue,
      savedMeasurements: const [],
      activeMarkers: [
        _vertex(const LatLng(-34.5, -58.2), 1),
        SoilMapMeasurementMarker(
          point: const LatLng(-34.55, -58.25),
          size: const Size(112, 36),
          useFlutterOverlay: true,
          child: const SizedBox.shrink(),
        ),
        _vertex(const LatLng(-34.6, -58.3), 2),
      ],
    );
    final features = (jsonDecode(data.active)['features'] as List).cast<Map>();
    final vertices = features
        .where((feature) => feature['properties']['kind'] == 'active-vertex')
        .toList();

    expect(vertices.map((feature) => feature['id']), [
      'active-vertex-0',
      'active-vertex-2',
    ]);
    expect(vertices.map((feature) => feature['geometry']['coordinates']), [
      [-58.2, -34.5],
      [-58.3, -34.6],
    ]);
  });

  test(
    'first middle and last vertex edits rebuild every connected segment',
    () {
      const original = [
        LatLng(-34.5, -58.2),
        LatLng(-34.6, -58.3),
        LatLng(-34.7, -58.4),
        LatLng(-34.8, -58.5),
      ];
      for (final index in [0, 2, 3]) {
        final points = List<LatLng>.of(original);
        final moved = LatLng(
          points[index].latitude + 0.01,
          points[index].longitude - 0.02,
        );
        points[index] = moved;
        final data = MapLibreMeasurementData.build(
          distancePoints: points,
          areaPoints: const [],
          activeColor: Colors.blue,
          savedMeasurements: const [],
          activeMarkers: [
            for (
              var vertexIndex = 0;
              vertexIndex < points.length;
              vertexIndex++
            )
              _vertex(points[vertexIndex], vertexIndex + 1),
          ],
        );
        final features = (jsonDecode(data.active)['features'] as List)
            .cast<Map>();
        final line = features.singleWhere(
          (feature) => feature['properties']['kind'] == 'active-distance',
        );
        final expectedCoordinates = [
          for (final point in points) [point.longitude, point.latitude],
        ];
        expect(line['geometry']['coordinates'], expectedCoordinates);
        expect(
          features
              .where(
                (feature) => feature['properties']['kind'] == 'active-vertex',
              )
              .map((feature) => feature['geometry']['coordinates'])
              .toList(),
          expectedCoordinates,
        );
        expect(features.map((feature) => feature['id']).toSet(), {
          'active-distance',
          for (var vertexIndex = 0; vertexIndex < points.length; vertexIndex++)
            'active-vertex-$vertexIndex',
        });
      }
    },
  );
}

SoilMapMeasurementMarker _vertex(LatLng point, int number) =>
    SoilMapMeasurementMarker(
      point: point,
      size: const Size.square(30),
      label: '$number',
      child: const SizedBox.shrink(),
    );
