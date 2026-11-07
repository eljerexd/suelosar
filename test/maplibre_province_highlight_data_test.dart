import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/engine/maplibre_province_highlight_data.dart';

void main() {
  test('one geographic snapshot drives both native province layers', () {
    const ring = [
      LatLng(-34.0, -58.0),
      LatLng(-35.0, -58.0),
      LatLng(-35.0, -59.0),
      LatLng(-34.0, -58.0),
    ];
    final data = MapLibreProvinceHighlightData.build(
      provinces: {
        'cordoba': [ring],
      },
      fillColors: {'cordoba': const Color(0x1A62695C)},
      borderColors: {'cordoba': const Color(0x73765D83)},
      revision: 17,
    );
    final collection = jsonDecode(data.geoJson) as Map<String, dynamic>;
    final feature = (collection['features'] as List).single as Map;
    final coordinates = feature['geometry']['coordinates'];

    expect(collection['properties']['snapshotVersion'], 17);
    expect(feature['id'], 'cordoba');
    expect(feature['properties']['snapshotVersion'], 17);
    expect(coordinates, [
      [
        [
          [-58.0, -34.0],
          [-58.0, -35.0],
          [-59.0, -35.0],
          [-58.0, -34.0],
        ],
      ],
    ]);
    expect(feature['properties']['fillColor'], '#62695c');
    expect(feature['properties']['borderColor'], '#765d83');
    expect(
      (feature['properties']['fillOpacity'] as num).toDouble(),
      closeTo(0.102, 0.001),
    );
    expect(
      (feature['properties']['borderOpacity'] as num).toDouble(),
      closeTo(0.451, 0.001),
    );
    expect(data.revision, 17);
  });

  test('cleared highlights produce an empty native source snapshot', () {
    final data = MapLibreProvinceHighlightData.build(
      provinces: const {},
      fillColors: const {},
      borderColors: const {},
      revision: 18,
    );
    final collection = jsonDecode(data.geoJson) as Map<String, dynamic>;
    expect(collection['features'], isEmpty);
    expect(collection['properties']['snapshotVersion'], 18);
  });
}
