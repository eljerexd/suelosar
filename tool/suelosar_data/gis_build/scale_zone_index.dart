import 'dart:convert';
import 'dart:io';

/// The official scale-coverage polygons (IDECOR's `escalas_cartograficas`)
/// used to decide, geographically, which additional-source features belong
/// in the merged collection (Parte 12): a feature is kept only where its own
/// declared scale is what the official index says applies there — never by
/// file order, and never by inferring coverage from our own downloaded
/// features.
///
/// Loaded once (it's a handful of large polygons, not per-feature data) and
/// queried per candidate feature via [scaleAt].
class ScaleZoneIndex {
  ScaleZoneIndex._(this._zones);

  final List<_ScaleZone> _zones;

  factory ScaleZoneIndex.load(File file, {required String field}) {
    final json =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final features = json['features'] as List;
    final zones = <_ScaleZone>[];
    for (final rawFeature in features) {
      final feature = rawFeature as Map<String, dynamic>;
      final properties = feature['properties'] as Map<String, dynamic>?;
      final scale = properties?[field]?.toString();
      final geometry = feature['geometry'] as Map<String, dynamic>?;
      if (scale == null || geometry == null) continue;
      zones.add(_ScaleZone(scale, _ringsOf(geometry)));
    }
    if (zones.isEmpty) {
      throw FormatException(
        '${file.path}: no se encontró ningún feature con la propiedad '
        '"$field" — no es el índice oficial de escalas esperado.',
      );
    }
    return ScaleZoneIndex._(zones);
  }

  /// The scale label of whichever zone contains ([lon], [lat]), or null when
  /// the point falls outside every declared zone (e.g. just outside the
  /// province, or in a real gap of the official index itself).
  ///
  /// Ties (a point inside two zones — normally impossible for a
  /// non-overlapping official partition, but the input is real-world data)
  /// resolve to the first match, in the index file's own feature order.
  String? scaleAt(double lon, double lat) {
    for (final zone in _zones) {
      if (zone.contains(lon, lat)) return zone.scale;
    }
    return null;
  }

  /// Every scale label the index declares, for reporting.
  Set<String> get scales => {for (final z in _zones) z.scale};
}

class _ScaleZone {
  _ScaleZone(this.scale, this.rings);

  final String scale;

  /// Every ring (outer and inner) of every polygon part, flattened — the
  /// even-odd rule below doesn't need to distinguish them.
  final List<List<(double, double)>> rings;

  bool contains(double lon, double lat) {
    var inside = false;
    for (final ring in rings) {
      if (_pointInRing(lon, lat, ring)) inside = !inside;
    }
    return inside;
  }
}

/// Standard ray-casting point-in-polygon test (even-odd rule) against one
/// ring. Boundary points may go either way — irrelevant here, since a
/// feature's representative point is its own area centroid, essentially
/// never exactly on a zone's border.
bool _pointInRing(double lon, double lat, List<(double, double)> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final (xi, yi) = ring[i];
    final (xj, yj) = ring[j];
    final crosses = (yi > lat) != (yj > lat);
    if (!crosses) continue;
    final xIntersect = (xj - xi) * (lat - yi) / (yj - yi) + xi;
    if (lon < xIntersect) inside = !inside;
  }
  return inside;
}

List<List<(double, double)>> _ringsOf(Map<String, dynamic> geometry) {
  final type = geometry['type'] as String?;
  final coordinates = geometry['coordinates'];
  List<List<(double, double)>> ringsOfPolygon(List polygon) => [
    for (final ring in polygon) _asPoints(ring as List),
  ];
  return switch (type) {
    'Polygon' => ringsOfPolygon(coordinates as List),
    'MultiPolygon' => [
      for (final polygon in coordinates as List)
        ...ringsOfPolygon(polygon as List),
    ],
    _ => const [],
  };
}

List<(double, double)> _asPoints(List ring) => [
  for (final point in ring)
    (
      ((point as List)[0] as num).toDouble(),
      (point[1] as num).toDouble(),
    ),
];

/// Area-weighted centroid (shoelace formula) of a `Polygon`/`MultiPolygon`'s
/// exterior ring(s) — the same technique already used for the reference
/// basemap's department labels (Parte 6). Used here as each feature's
/// representative point for the zone lookup: far more robust than a plain
/// vertex average for the concave/irregular shapes soil map units often
/// have. Not a perfect "guaranteed inside" guarantee for extreme concave
/// shapes, but standard practice for this kind of zone classification.
(double, double)? polygonCentroid(Map<String, dynamic> geometry) {
  final type = geometry['type'] as String?;
  final coordinates = geometry['coordinates'];
  final outerRings = switch (type) {
    'Polygon' => [_asPoints((coordinates as List).first as List)],
    'MultiPolygon' => [
      for (final polygon in coordinates as List)
        _asPoints((polygon as List).first as List),
    ],
    _ => const <List<(double, double)>>[],
  };
  if (outerRings.isEmpty) return null;

  var totalArea = 0.0;
  var weightedX = 0.0;
  var weightedY = 0.0;
  for (final ring in outerRings) {
    if (ring.length < 3) continue;
    var signedArea = 0.0;
    var cx = 0.0;
    var cy = 0.0;
    for (var i = 0; i < ring.length; i++) {
      final (x0, y0) = ring[i];
      final (x1, y1) = ring[(i + 1) % ring.length];
      final cross = x0 * y1 - x1 * y0;
      signedArea += cross;
      cx += (x0 + x1) * cross;
      cy += (y0 + y1) * cross;
    }
    signedArea /= 2;
    if (signedArea == 0) continue;
    cx /= 6 * signedArea;
    cy /= 6 * signedArea;
    final area = signedArea.abs();
    totalArea += area;
    weightedX += cx * area;
    weightedY += cy * area;
  }
  if (totalArea == 0) return null;
  return (weightedX / totalArea, weightedY / totalArea);
}
