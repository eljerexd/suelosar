import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../models/measurement_color_option.dart';
import '../../models/saved_measurement.dart';
import 'soil_map_engine.dart';

/// GeoJSON snapshots consumed by the native measurement style layers.
/// Coordinates remain longitude/latitude in their original order.
class MapLibreMeasurementData {
  const MapLibreMeasurementData({
    required this.active,
    required this.saved,
    required this.snapshotVersion,
  });

  /// A complete replacement snapshot for the in-progress measurement.
  /// Lines, area fill, and numbered vertices share this source so one drag
  /// position can never be published through independent native updates.
  final String active;
  final String saved;
  final int snapshotVersion;

  factory MapLibreMeasurementData.build({
    required List<LatLng> distancePoints,
    required List<LatLng> areaPoints,
    List<SoilMapMeasurementMarker> activeMarkers = const [],
    required Color activeColor,
    required List<SavedMeasurement> savedMeasurements,
    int snapshotVersion = 0,
    String? highlightedId,
    String? hoveredId,
  }) {
    final activeFeatures = <Map<String, Object?>>[];
    if (distancePoints.length >= 2) {
      activeFeatures.add(
        _lineFeature(
          id: 'active-distance',
          kind: 'active-distance',
          points: distancePoints,
          color: activeColor,
        ),
      );
    }
    if (areaPoints.length >= 2) {
      activeFeatures.add(
        _lineFeature(
          id: 'active-area-outline',
          kind: 'active-area-outline',
          points: areaPoints.length >= 3 ? _closed(areaPoints) : areaPoints,
          color: activeColor,
        ),
      );
    }

    if (areaPoints.length >= 3) {
      activeFeatures.add({
        'type': 'Feature',
        'id': 'active-area',
        'properties': {'kind': 'active-area', 'color': _hex(activeColor)},
        'geometry': {
          'type': 'Polygon',
          'coordinates': [_coordinates(_closed(areaPoints))],
        },
      });
    }
    for (var index = 0; index < activeMarkers.length; index++) {
      final marker = activeMarkers[index];
      if (marker.useFlutterOverlay) continue;
      activeFeatures.add({
        'type': 'Feature',
        'id': 'active-vertex-$index',
        'properties': {
          'kind': 'active-vertex',
          'label': marker.label,
          'radius': marker.radius,
          'fillColor': _hex(marker.fillColor),
          'textColor': _hex(marker.textColor),
          'strokeColor': _hex(marker.strokeColor),
          'strokeWidth': marker.strokeWidth,
          'sortKey': index,
          'imageId': vertexImageId(marker),
          'useFlutterOverlay': marker.useFlutterOverlay,
        },
        'geometry': {
          'type': 'Point',
          'coordinates': [marker.point.longitude, marker.point.latitude],
        },
      });
    }

    final savedFeatures = <Map<String, Object?>>[];
    for (final measurement in savedMeasurements) {
      final points = measurement.geometry;
      final type = measurement.type;
      if ((type == SavedMeasurementType.area && points.length < 3) ||
          (type == SavedMeasurementType.distance && points.length < 2)) {
        continue;
      }
      final state = measurement.id == highlightedId
          ? 'selected'
          : measurement.id == hoveredId
          ? 'hovered'
          : 'normal';
      final color = MeasurementColorOption.fromStorageValue(measurement.colorId)
          .color;
      if (type == SavedMeasurementType.distance) {
        savedFeatures.add(
          _lineFeature(
            id: measurement.id,
            kind: 'saved-distance',
            points: points,
            color: color,
            properties: {'measurementId': measurement.id, 'state': state},
          ),
        );
      } else {
        savedFeatures
          ..add({
            'type': 'Feature',
            'id': measurement.id,
            'properties': {
              'measurementId': measurement.id,
              'kind': 'saved-area',
              'state': state,
              'color': _hex(color),
            },
            'geometry': {
              'type': 'Polygon',
              'coordinates': [_coordinates(_closed(points))],
            },
          })
          ..add(
            _lineFeature(
              id: '${measurement.id}:outline',
              kind: 'saved-area-outline',
              points: _closed(points),
              color: color,
              properties: {'measurementId': measurement.id, 'state': state},
            ),
          );
      }
    }

    return MapLibreMeasurementData(
      active: _collection(activeFeatures, snapshotVersion),
      saved: _collection(savedFeatures, snapshotVersion),
      snapshotVersion: snapshotVersion,
    );
  }

  static Map<String, Object?> _lineFeature({
    required String id,
    required String kind,
    required List<LatLng> points,
    required Color color,
    Map<String, Object?> properties = const {},
  }) => {
    'type': 'Feature',
    'id': id,
    'properties': {...properties, 'kind': kind, 'color': _hex(color)},
    'geometry': {'type': 'LineString', 'coordinates': _coordinates(points)},
  };

  static String _collection(
    List<Map<String, Object?>> features,
    int snapshotVersion,
  ) => jsonEncode({
    'type': 'FeatureCollection',
    'properties': {'snapshotVersion': snapshotVersion},
    'features': features,
  });

  static List<LatLng> _closed(List<LatLng> points) =>
      points.isNotEmpty && points.first != points.last
      ? [...points, points.first]
      : points;

  static List<List<double>> _coordinates(List<LatLng> points) => [
    for (final point in points) [point.longitude, point.latitude],
  ];

  static String _hex(Color color) =>
      '#${(color.toARGB32() & 0x00FFFFFF).toRadixString(16).padLeft(6, '0')}';

  static String vertexImageId(SoilMapMeasurementMarker marker) =>
      'suelosar-measure-vertex-${base64Url.encode(utf8.encode([marker.label, _hex(marker.textColor)].join('|'))).replaceAll('=', '')}';
}
