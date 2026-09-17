import 'dart:io';
import 'dart:typed_data';

/// Reads polygon geometries from a `.shp`, in record order, as GeoJSON
/// geometry objects. Coordinates are copied exactly as stored; only the
/// part structure is converted (outer rings are clockwise in a shapefile,
/// holes counter-clockwise, and each hole is attached to the outer ring
/// that contains it — the same reading OGR does).
class ShapefilePolygonReader {
  ShapefilePolygonReader(this.file);

  final File file;

  static const _polygonTypes = {5, 15, 25};

  /// Rejects projections Fase 1 cannot write as GeoJSON unchanged: the
  /// output must already be geographic WGS 84 (lon/lat).
  static void ensureGeographicWgs84(File shp) {
    final base = shp.path.substring(0, shp.path.length - 4);
    final prj = [
      File('$base.prj'),
      File('$base.PRJ'),
    ].where((f) => f.existsSync()).firstOrNull;
    if (prj == null) {
      throw const FormatException(
        'Falta el .prj: no se puede confirmar que el shapefile esté en WGS 84.',
      );
    }
    final wkt = prj.readAsStringSync().toUpperCase();
    final geographic =
        wkt.trimLeft().startsWith('GEOGCS') ||
        wkt.trimLeft().startsWith('GEOGCRS');
    final wgs84 =
        wkt.contains('WGS_1984') ||
        wkt.contains('WGS 84') ||
        wkt.contains('WGS84');
    if (!geographic || !wgs84) {
      throw FormatException(
        'El shapefile no está en coordenadas geográficas WGS 84 (${prj.path}). '
        'La normalización de Fase 1 no reproyecta; convertilo antes con GDAL.',
      );
    }
  }

  /// `(recordIndex, geometry)` for every record; geometry is null for null
  /// shapes.
  Iterable<(int, Map<String, Object?>?)> geometries() sync* {
    final raf = file.openSync();
    try {
      final header = raf.readSync(100);
      if (header.length < 100 ||
          ByteData.sublistView(header).getInt32(0, Endian.big) != 9994) {
        throw FormatException('No es un shapefile válido: ${file.path}');
      }
      final length = raf.lengthSync();
      var index = 0;
      while (raf.positionSync() + 8 <= length) {
        final recordHeader = raf.readSync(8);
        final contentLength =
            ByteData.sublistView(recordHeader).getInt32(4, Endian.big) * 2;
        final content = raf.readSync(contentLength);
        if (content.length != contentLength) {
          throw FormatException('Registro $index truncado en ${file.path}');
        }
        yield (index, _geometry(content, index));
        index++;
      }
    } finally {
      raf.closeSync();
    }
  }

  Map<String, Object?>? _geometry(Uint8List content, int index) {
    final data = ByteData.sublistView(content);
    final type = data.getInt32(0, Endian.little);
    if (type == 0) return null;
    if (!_polygonTypes.contains(type)) {
      throw FormatException(
        'Registro $index: tipo de geometría $type no soportado (solo polígonos).',
      );
    }
    final numParts = data.getInt32(36, Endian.little);
    final numPoints = data.getInt32(40, Endian.little);
    final parts = [
      for (var i = 0; i < numParts; i++)
        data.getInt32(44 + i * 4, Endian.little),
    ];
    final pointsStart = 44 + numParts * 4;
    final rings = <List<List<double>>>[];
    for (var part = 0; part < numParts; part++) {
      final from = parts[part];
      final to = part + 1 < numParts ? parts[part + 1] : numPoints;
      rings.add([
        for (var i = from; i < to; i++)
          [
            data.getFloat64(pointsStart + i * 16, Endian.little),
            data.getFloat64(pointsStart + i * 16 + 8, Endian.little),
          ],
      ]);
    }
    return polygonFromRings(rings);
  }

  /// Groups shapefile rings into a GeoJSON Polygon / MultiPolygon.
  static Map<String, Object?>? polygonFromRings(
    List<List<List<double>>> rings,
  ) {
    final polygons = <List<List<List<double>>>>[];
    final holes = <List<List<double>>>[];
    for (final ring in rings) {
      if (ring.length < 4) continue;
      if (_isClockwise(ring)) {
        polygons.add([ring]);
      } else {
        holes.add(ring);
      }
    }
    for (final hole in holes) {
      final owner = polygons
          .where((polygon) => _contains(polygon.first, hole.first))
          .firstOrNull;
      if (owner == null) {
        // An orphan counter-clockwise ring is an outer ring written the
        // other way round; OGR keeps it as its own polygon too.
        polygons.add([hole]);
      } else {
        owner.add(hole);
      }
    }
    if (polygons.isEmpty) return null;
    if (polygons.length == 1) {
      return {'type': 'Polygon', 'coordinates': polygons.single};
    }
    return {'type': 'MultiPolygon', 'coordinates': polygons};
  }

  static bool _isClockwise(List<List<double>> ring) {
    var sum = 0.0;
    for (var i = 0; i < ring.length - 1; i++) {
      sum += (ring[i + 1][0] - ring[i][0]) * (ring[i + 1][1] + ring[i][1]);
    }
    return sum > 0;
  }

  static bool _contains(List<List<double>> ring, List<double> point) {
    final x = point[0];
    final y = point[1];
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i][0];
      final yi = ring[i][1];
      final xj = ring[j][0];
      final yj = ring[j][1];
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }
}
