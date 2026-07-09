import 'gis_feature.dart';

/// A named collection of related spatial features.
///
/// This domain model deliberately omits storage details.
class GisLayer {
  const GisLayer({
    required this.id,
    required this.name,
    required this.features,
    this.properties = const <String, Object?>{},
  });

  final String id;
  final String name;
  final List<GisFeature> features;

  /// Optional metadata that applies to the complete layer.
  final Map<String, Object?> properties;
}

/// Coordinates identifying one tile in a slippy-map pyramid.
class GisTileCoordinates {
  const GisTileCoordinates({
    required this.zoom,
    required this.x,
    required this.y,
  });

  final int zoom;
  final int x;
  final int y;

  @override
  bool operator ==(Object other) {
    return other is GisTileCoordinates &&
        other.zoom == zoom &&
        other.x == x &&
        other.y == y;
  }

  @override
  int get hashCode => Object.hash(zoom, x, y);
}

/// Metadata needed by the UI without exposing the archive implementation.
class GisArchiveInfo {
  const GisArchiveInfo({
    required this.minZoom,
    required this.maxZoom,
    required this.centerLatitude,
    required this.centerLongitude,
  });

  final int minZoom;
  final int maxZoom;
  final double centerLatitude;
  final double centerLongitude;
}
