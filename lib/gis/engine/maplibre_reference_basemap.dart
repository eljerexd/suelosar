import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../constants/asset_paths.dart';

/// Converts the bundled reference-map line arrays into native MapLibre
/// GeoJSON sources without simplifying or reordering their coordinates.
class MapLibreReferenceBasemapData {
  MapLibreReferenceBasemapData._(this.featureCollections, this.cities);

  static const lineCategories = <String>[
    'provincialBoundaries',
    'departmentBoundaries',
    'majorRivers',
    'nationalRoads',
    'provincialRoads',
  ];

  static const provinceIds = <String>['buenos_aires', 'santa_fe', 'cordoba'];

  // Keep source IDs independent of the generic line-style list: jurisdiction
  // boundaries have their own foreground layers and are not part of that list.
  static const sourceIdsByCategory = <String, String>{
    'provincialBoundaries': 'suelosar-reference-province-source',
    'departmentBoundaries': 'suelosar-reference-department-boundaries-source',
    'majorRivers': 'suelosar-reference-rivers-source',
    'nationalRoads': 'suelosar-reference-national-roads-source',
    'provincialRoads': 'suelosar-reference-provincial-roads-source',
  };

  static String sourceIdForCategory(String category) {
    final sourceId = sourceIdsByCategory[category];
    if (sourceId == null) {
      throw ArgumentError.value(category, 'category', 'Unknown map category');
    }
    return sourceId;
  }

  static List<MapLibreReferenceCity> prioritizeLabelRegistration(
    List<MapLibreReferenceCity> cities, {
    required double zoom,
  }) {
    final indexed = cities.indexed.toList();
    int priority(MapLibreReferenceCity city) {
      if (city.isAdministrative && city.minZoom <= zoom) return 0;
      if (city.isPrimary) return 0;
      if (city.isAdministrative) return 3;
      return zoom >= 6.7 ? 2 : 4;
    }

    indexed.sort((first, second) {
      final priorityOrder = priority(first.$2).compareTo(priority(second.$2));
      return priorityOrder == 0 ? first.$1.compareTo(second.$1) : priorityOrder;
    });
    return List.unmodifiable(indexed.map((entry) => entry.$2));
  }

  static const Map<String, String> _provinceIdByAsset = {
    AssetPaths.agronomicReferenceMap: 'buenos_aires',
    AssetPaths.santaFeAgronomicReferenceMap: 'santa_fe',
    AssetPaths.cordobaAgronomicReferenceMap: 'cordoba',
  };

  final Map<String, String> featureCollections;
  final List<MapLibreReferenceCity> cities;

  int featureCount(String category) {
    final collection = jsonDecode(featureCollections[category]!) as Map;
    return (collection['features'] as List).length;
  }

  static MapLibreReferenceBasemapData fromAssetJson(
    List<MapEntry<String, String>> assets,
  ) {
    final featuresByCategory = <String, List<Map<String, Object?>>>{
      for (final category in lineCategories) category: <Map<String, Object?>>[],
    };
    final cities = <MapLibreReferenceCity>[];

    for (final asset in assets) {
      final document = jsonDecode(asset.value) as Map<String, dynamic>;
      if (document['crs'] != 'EPSG:4326') {
        throw FormatException('Reference map ${asset.key} must use EPSG:4326.');
      }
      final provinceId = _provinceIdByAsset[asset.key] ?? 'unknown';
      final layers = Map<String, dynamic>.from(document['layers'] as Map);
      for (final category in lineCategories) {
        final lines = layers[category] as List<dynamic>? ?? const [];
        final output = featuresByCategory[category]!;
        for (var index = 0; index < lines.length; index++) {
          final coordinates = lines[index] as List<dynamic>;
          if (coordinates.length < 2 ||
              coordinates.any(
                (coordinate) =>
                    coordinate is! List ||
                    coordinate.length < 2 ||
                    coordinate[0] is! num ||
                    coordinate[1] is! num ||
                    !(coordinate[0] as num).toDouble().isFinite ||
                    !(coordinate[1] as num).toDouble().isFinite,
              )) {
            throw FormatException(
              'Invalid $category line $index in ${asset.key}.',
            );
          }
          output.add({
            'type': 'Feature',
            'id': '${asset.key}:$category:$index',
            'properties': {
              'sourceAsset': asset.key,
              'sourceIndex': index,
              if (category == 'departmentBoundaries') 'provinceId': provinceId,
            },
            'geometry': {'type': 'LineString', 'coordinates': coordinates},
          });
        }
      }
      final rawCities = layers['majorCities'] as List<dynamic>? ?? const [];
      for (var index = 0; index < rawCities.length; index++) {
        final rawCity = Map<String, dynamic>.from(rawCities[index] as Map);
        final latitude = (rawCity['lat'] as num).toDouble();
        final longitude = (rawCity['lon'] as num).toDouble();
        final name = rawCity['name'] as String;
        if (!latitude.isFinite || !longitude.isFinite || name.trim().isEmpty) {
          throw FormatException('Invalid major city $index in ${asset.key}.');
        }
        cities.add(
          MapLibreReferenceCity(
            id: '${asset.key}:majorCities:$index',
            name: name,
            point: LatLng(latitude, longitude),
            isPrimary: rawCity['importance'] == 'primary',
            provinceId: provinceId,
          ),
        );
      }
      final rawDepartments =
          layers['departmentLabels'] as List<dynamic>? ?? const [];
      final departmentRecords = [
        for (final rawDepartment in rawDepartments)
          Map<String, dynamic>.from(rawDepartment as Map),
      ];
      final departmentPositions = [
        for (final department in departmentRecords)
          LatLng(
            (department['lat'] as num).toDouble(),
            (department['lon'] as num).toDouble(),
          ),
      ];
      final progressiveZooms = progressiveJurisdictionMinZooms(
        departmentPositions,
      );
      for (var index = 0; index < rawDepartments.length; index++) {
        final label = departmentRecords[index];
        final latitude = (label['lat'] as num).toDouble();
        final longitude = (label['lon'] as num).toDouble();
        final name = label['name'] as String;
        if (!latitude.isFinite || !longitude.isFinite || name.trim().isEmpty) {
          throw FormatException(
            'Invalid department label $index in ${asset.key}.',
          );
        }
        cities.add(
          MapLibreReferenceCity(
            id: '${asset.key}:departmentLabels:$index',
            name: name,
            point: LatLng(latitude, longitude),
            isPrimary: false,
            isAdministrative: true,
            provinceId: provinceId,
            minZoom:
                (label['minZoom'] as num?)?.toDouble() ??
                progressiveZooms[index],
          ),
        );
      }
    }

    final prioritizedCities = cities.indexed.toList()
      ..sort((first, second) {
        final firstPriority = first.$2.isPrimary
            ? 0
            : first.$2.isAdministrative
            ? 2
            : 1;
        final secondPriority = second.$2.isPrimary
            ? 0
            : second.$2.isAdministrative
            ? 2
            : 1;
        if (firstPriority != secondPriority) {
          return firstPriority - secondPriority;
        }
        return first.$1.compareTo(second.$1);
      });

    return MapLibreReferenceBasemapData._({
      for (final entry in featuresByCategory.entries)
        entry.key: jsonEncode({
          'type': 'FeatureCollection',
          'features': entry.value,
        }),
    }, List.unmodifiable(prioritizedCities.map((entry) => entry.$2)));
  }
}

/// Uses the stable app's progressive density tiers for jurisdictions whose
/// bundled centroids predate explicit minimum zoom metadata.
List<double> progressiveJurisdictionMinZooms(List<LatLng> positions) => [
  for (var index = 0; index < positions.length; index++)
    _jurisdictionMinZoomForNearestDistance(
      _nearestJurisdictionDistanceKm(positions, index),
    ),
];

double _nearestJurisdictionDistanceKm(List<LatLng> positions, int index) {
  if (positions.length < 2) return double.infinity;
  final point = positions[index];
  var nearest = double.infinity;
  for (var otherIndex = 0; otherIndex < positions.length; otherIndex++) {
    if (otherIndex == index) continue;
    final other = positions[otherIndex];
    const radians = math.pi / 180;
    final latitudeDelta = (other.latitude - point.latitude) * radians;
    final longitudeDelta = (other.longitude - point.longitude) * radians;
    final a =
        math.pow(math.sin(latitudeDelta / 2), 2) +
        math.cos(point.latitude * radians) *
            math.cos(other.latitude * radians) *
            math.pow(math.sin(longitudeDelta / 2), 2);
    final distance = 2 * 6371 * math.asin(math.sqrt(a));
    if (distance < nearest) nearest = distance;
  }
  return nearest;
}

double _jurisdictionMinZoomForNearestDistance(double distanceKm) {
  if (distanceKm >= 90) return 7;
  if (distanceKm >= 65) return 7.7;
  if (distanceKm >= 45) return 8.6;
  return 9.4;
}

typedef MapLibreAdministrativeBoundaryStyle = ({
  Color color,
  double strokeWidth,
  double opacity,
});

MapLibreAdministrativeBoundaryStyle administrativeBoundaryStyleAtZoom({
  required bool enhancedForSoilPolygons,
  required double zoom,
}) => enhancedForSoilPolygons
    ? (
        color: const Color(0xFF252A25),
        strokeWidth: 2.5,
        opacity: enhancedAdministrativeBoundaryOpacityAtZoom(zoom),
      )
    : (color: const Color(0xFF62695C), strokeWidth: 1.5, opacity: 0.78);

double enhancedAdministrativeBoundaryOpacityAtZoom(double zoom) {
  const points = <(double, double)>[
    (10, 1),
    (11, 0.75),
    (12, 0.5),
    (13, 0.3),
    (14, 0.15),
    (15, 0.08),
    (16, 0.045),
  ];
  if (zoom <= points.first.$1) return points.first.$2;
  if (zoom >= points.last.$1) return points.last.$2;
  for (var index = 0; index < points.length - 1; index++) {
    final (startZoom, startOpacity) = points[index];
    final (endZoom, endOpacity) = points[index + 1];
    if (zoom <= endZoom) {
      final progress = (zoom - startZoom) / (endZoom - startZoom);
      return startOpacity + (endOpacity - startOpacity) * progress;
    }
  }
  return points.last.$2;
}

int _jurisdictionMinZoomTier(double minZoom) {
  if (minZoom <= 7) return 0;
  if (minZoom <= 7.7) return 1;
  if (minZoom <= 8.6) return 2;
  return 3;
}

double jurisdictionLabelOpacityForTier({
  required int tier,
  required double zoom,
}) {
  const minZooms = [7.0, 7.7, 8.6, 9.4];
  if (tier < 0 || tier >= minZooms.length || !zoom.isFinite) return 0;
  final minZoom = minZooms[tier];
  if (zoom < minZoom) return 0;
  if (zoom <= 8) return 1;
  return (1 - (zoom - 8) / 4).clamp(0.0, 1.0);
}

class MapLibreReferenceCity {
  const MapLibreReferenceCity({
    required this.id,
    required this.name,
    required this.point,
    required this.isPrimary,
    this.isAdministrative = false,
    this.provinceId = 'unknown',
    this.minZoom = 0,
  });

  final String id;
  final String name;
  final LatLng point;
  final bool isPrimary;
  final bool isAdministrative;
  final String provinceId;
  final double minZoom;
  int get minZoomTier => _jurisdictionMinZoomTier(minZoom);
}
