/// Geometry data expressed independently from its storage format.
class GisGeometry {
  const GisGeometry({required this.type, required this.coordinates});

  /// Geometry type, such as `Point`, `LineString`, or `Polygon`.
  final String type;

  /// Coordinate structure associated with [type].
  final Object? coordinates;
}

/// A spatial feature associated with a locality and a soil map.
class GisFeature {
  const GisFeature({
    required this.id,
    required this.geometry,
    required this.properties,
    required this.locality,
    required this.soilMapId,
  });

  final String id;
  final GisGeometry geometry;
  final Map<String, Object?> properties;
  final String locality;
  final int soilMapId;
}
