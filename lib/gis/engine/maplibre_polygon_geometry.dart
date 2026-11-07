/// Returns a GeoJSON Polygon/MultiPolygon with valid closed linear rings.
///
/// MapLibre's rendered vector-tile query can return a three-vertex ring that
/// omits its repeated closing coordinate. Close valid rings, but reject
/// degenerate or malformed geometry instead of passing invalid GeoJSON to the
/// native style source.
Map<String, Object?>? normalizeMapLibrePolygonGeometry(
  String type,
  Object? coordinates,
) {
  if (type == 'Polygon') {
    final rings = _asList(coordinates);
    if (rings == null || rings.isEmpty) return null;
    final normalized = <List<List<Object?>>>[];
    for (final ring in rings) {
      final positions = _normalizeRing(ring);
      if (positions == null) return null;
      normalized.add(positions);
    }
    return {'type': type, 'coordinates': normalized};
  }

  if (type == 'MultiPolygon') {
    final polygons = _asList(coordinates);
    if (polygons == null || polygons.isEmpty) return null;
    final normalized = <List<List<List<Object?>>>>[];
    for (final polygon in polygons) {
      final rings = _asList(polygon);
      if (rings == null || rings.isEmpty) return null;
      final normalizedRings = <List<List<Object?>>>[];
      for (final ring in rings) {
        final positions = _normalizeRing(ring);
        if (positions == null) return null;
        normalizedRings.add(positions);
      }
      normalized.add(normalizedRings);
    }
    return {'type': type, 'coordinates': normalized};
  }

  return null;
}

List<Object?>? _asList(Object? value) => value is List ? value : null;

List<List<Object?>>? _normalizeRing(Object? value) {
  final rawPositions = _asList(value);
  if (rawPositions == null || rawPositions.length < 3) return null;

  final positions = <List<Object?>>[];
  for (final rawPosition in rawPositions) {
    final rawCoordinates = _asList(rawPosition);
    if (rawCoordinates == null || rawCoordinates.length < 2) return null;
    if (rawCoordinates.any(
      (coordinate) => coordinate is! num || !coordinate.isFinite,
    )) {
      return null;
    }
    positions.add(List<Object?>.of(rawCoordinates));
  }

  final uniqueVertices = <List<Object?>>[];
  for (final position in positions) {
    if (!uniqueVertices.any((other) => _sameVertex(position, other))) {
      uniqueVertices.add(position);
    }
  }
  if (uniqueVertices.length < 3) return null;

  if (!_sameVertex(positions.first, positions.last)) {
    positions.add(List<Object?>.of(positions.first));
  }
  if (positions.length < 4) return null;
  return positions;
}

bool _sameVertex(List<Object?> first, List<Object?> second) =>
    first[0] == second[0] && first[1] == second[1];
