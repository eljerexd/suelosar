import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// One immutable geographic snapshot used by both native highlight layers.
class MapLibreProvinceHighlightData {
  const MapLibreProvinceHighlightData({
    required this.geoJson,
    required this.revision,
  });

  final String geoJson;
  final int revision;

  factory MapLibreProvinceHighlightData.build({
    required Map<String, List<List<LatLng>>> provinces,
    required Map<String, Color> fillColors,
    required Map<String, Color> borderColors,
    required int revision,
  }) {
    final features = <Map<String, Object?>>[];
    for (final entry in provinces.entries) {
      final rings = entry.value.where((ring) => ring.length >= 3).toList();
      if (rings.isEmpty) continue;
      final fill = fillColors[entry.key];
      final border = borderColors[entry.key];
      if (fill == null || border == null) continue;
      features.add({
        'type': 'Feature',
        'id': entry.key,
        'properties': {
          'coverageId': entry.key,
          'snapshotVersion': revision,
          'fillColor': _rgb(fill),
          'fillOpacity': fill.a,
          'borderColor': _rgb(border),
          'borderOpacity': border.a,
        },
        'geometry': {
          'type': 'MultiPolygon',
          'coordinates': [
            for (final ring in rings) [_closedCoordinates(ring)],
          ],
        },
      });
    }
    return MapLibreProvinceHighlightData(
      geoJson: jsonEncode({
        'type': 'FeatureCollection',
        'properties': {'snapshotVersion': revision},
        'features': features,
      }),
      revision: revision,
    );
  }

  static String _rgb(Color color) =>
      '#${(color.toARGB32() & 0x00FFFFFF).toRadixString(16).padLeft(6, '0')}';

  static List<List<double>> _closedCoordinates(List<LatLng> ring) {
    final coordinates = [
      for (final point in ring) [point.longitude, point.latitude],
    ];
    if (ring.first != ring.last) {
      coordinates.add([ring.first.longitude, ring.first.latitude]);
    }
    return coordinates;
  }
}
