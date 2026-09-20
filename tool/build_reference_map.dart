// Builds an offline agronomic reference basemap asset
// (`assets/maps/agronomic_reference_map_<province>.json`) from the same
// official sources Buenos Aires' and Santa Fe's assets were built from:
// the IGN's public WFS (wms.ign.gob.ar/geoserver/wfs) for geometry and
// BAHRA/INDEC (published through that same WFS as `ign:localidad_bahra`)
// for locality coordinates.
//
// Buenos Aires' and Santa Fe's assets predate this script and were produced
// by hand; the output schema here is exactly theirs (schema 1), so the
// renderer (`lib/gis/offline_reference_map_layer.dart`) needs no changes and
// the three provinces stay visually consistent.
//
// Usage:
//   dart run tool/build_reference_map.dart cordoba [--cache-dir <dir>] [--dry-run]
//
// `--cache-dir` reuses (and populates) raw WFS downloads on disk, so the
// asset can be regenerated with different simplification tolerances without
// re-downloading ~7 MB from the IGN. Nothing outside the output asset is
// written into the repository.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const String _wfsEndpoint = 'https://wms.ign.gob.ar/geoserver/wfs';

/// Douglas-Peucker tolerances, in degrees, per layer. Chosen so the result
/// lands in the same size/vertex range as the two existing assets (Buenos
/// Aires 271 KB, Santa Fe 244 KB) — the renderer caps geometry at zoom 13,
/// so detail finer than roughly 0.002° never reaches a pixel.
const Map<String, double> _simplifyTolerance = {
  'provincialBoundaries': 0.0015,
  'departmentBoundaries': 0.0035,
  'majorRivers': 0.0055,
  'nationalRoads': 0.0035,
  'provincialRoads': 0.007,
};

/// Decimal places kept per coordinate. 5 ≈ 1.1 m at this latitude, far below
/// what a zoom-13 pixel resolves, and matches the precision already present
/// in the Buenos Aires/Santa Fe assets.
const int _coordinateDecimals = 5;

class ProvinceSpec {
  const ProvinceSpec({
    required this.id,
    required this.name,
    required this.indecCode,
    required this.bbox,
    required this.outputPath,
    required this.primaryCities,
    required this.secondaryCities,
  });

  final String id;

  /// As IGN's `ign:provincia.nam` spells it.
  final String name;

  /// INDEC province code, the prefix of every `ign:departamento.in1` and the
  /// `cod_pcia` of every BAHRA locality of the province.
  final String indecCode;

  /// [west, south, east, north] working extent — the province's own coverage
  /// plus a small margin, so roads and rivers do not stop exactly at the
  /// border.
  final List<double> bbox;

  final String outputPath;

  /// Rendered larger/earlier by the painter (`importance: primary`).
  final List<String> primaryCities;
  final List<String> secondaryCities;
}

/// Córdoba. The city list is curated, like Buenos Aires' and Santa Fe's:
/// BAHRA carries no population field, so there is no objective ranking to
/// sort by. It covers the 26 departmental capitals plus the largest towns,
/// which is what a reader orients by; coordinates come from BAHRA, never
/// typed in by hand.
const ProvinceSpec _cordoba = ProvinceSpec(
  id: 'cordoba',
  name: 'Córdoba',
  indecCode: '14',
  // MapCoverage.cordoba's real archive extent, padded ~0.2°.
  bbox: [-65.35, -35.25, -61.60, -30.10],
  outputPath: 'assets/maps/agronomic_reference_map_cordoba.json',
  primaryCities: [
    'Córdoba',
    'Río Cuarto',
    'Villa María',
    'San Francisco',
    'Villa Carlos Paz',
    'Río Tercero',
    'Alta Gracia',
    'Bell Ville',
    'Jesús María',
    'Villa Dolores',
  ],
  secondaryCities: [
    'Arroyito',
    'Cruz del Eje',
    'Deán Funes',
    'La Carlota',
    'La Falda',
    'Laboulaye',
    'Las Varillas',
    'Marcos Juárez',
    'Morteros',
    'Oliva',
    'Oncativo',
    'Pilar',
    'Río Segundo',
    'Rio Ceballos',
    'Salsipuedes',
    'San Carlos Minas',
    'Cosquín',
    'Corral de Bustos',
    'General Cabrera',
    'General Deheza',
    'Hernando',
    'Huinca Renancó',
    'Justiniano Posse',
    'Laguna Larga',
    'Leones',
    'Mina Clavero',
    'Monte Buey',
    'Montecristo',
    'Quilino',
    'Sampacho',
    'San José de la Dormida',
    'Santa Rosa de Calamuchita',
    'Serrezuela',
    'Tancacha',
    'Ucacha',
    'Unquillo',
    'Vicuña Mackenna',
    'Villa Cura Brochero',
    'Villa del Rosario',
    'Villa del Totoral',
    'Villa General Belgrano',
    'Villa Huidobro',
    'Villa de Soto',
  ],
);

const Map<String, ProvinceSpec> _provinces = {'cordoba': _cordoba};

Future<void> main(List<String> arguments) async {
  final cacheFlag = arguments.indexOf('--cache-dir');
  final positional = [
    for (var index = 0; index < arguments.length; index++)
      // Skip the flags themselves and `--cache-dir`'s own value. `cacheFlag`
      // is -1 when the flag isn't present at all — without the `cacheFlag
      // != -1` guard, `index != cacheFlag + 1` reads as `index != 0` and
      // silently drops the province argument every time `--cache-dir` is
      // omitted, which is the common case.
      if (!arguments[index].startsWith('--') &&
          (cacheFlag == -1 || index != cacheFlag + 1))
        arguments[index],
  ];
  if (positional.length != 1 || !_provinces.containsKey(positional.single)) {
    stderr.writeln(
      'Usage: dart run tool/build_reference_map.dart <${_provinces.keys.join('|')}> '
      '[--cache-dir <dir>] [--dry-run]',
    );
    exitCode = 64;
    return;
  }

  final spec = _provinces[positional.single]!;
  final dryRun = arguments.contains('--dry-run');
  final cacheIndex = arguments.indexOf('--cache-dir');
  final cacheDir = cacheIndex >= 0 && cacheIndex + 1 < arguments.length
      ? Directory(arguments[cacheIndex + 1])
      : null;

  // Fase 6 Parte 42B: `wms.ign.gob.ar` (the WFS endpoint every fetch below
  // uses) is unreachable from every network path available in this repo's
  // dev/CI environments — confirmed via curl, Dart's own HttpClient, and a
  // real browser, all failing the TCP handshake the same way. IGN's other
  // official geoservice, the ArcGIS REST endpoint at
  // ide.ign.gob.ar/geoservicios/rest/services/servicio_fondos/MapServer/0
  // ("Provincias", the same administrative product — polygon, EPSG:4326,
  // `IN1`/`FNA` fields matching WFS `ign:provincia`'s `in1`/`nam`), *is*
  // reachable, so `--boundary-only` regenerates just `provincialBoundaries`
  // from that source and merges it into the existing asset, touching
  // nothing else — roads/rivers/departments/cities/labels stay exactly as
  // they were, unrefetched, since this mode never calls the WFS at all.
  // The normal (no-flag) path below is untouched and still WFS-only, for
  // whenever `wms.ign.gob.ar` is reachable again.
  if (arguments.contains('--boundary-only')) {
    await _regenerateBoundaryOnly(spec, dryRun: dryRun);
    return;
  }

  final fetcher = _WfsFetcher(cacheDir: cacheDir);

  final province = await fetcher.fetch(
    'provincia',
    typeName: 'ign:provincia',
    query: {'CQL_FILTER': "nam='${spec.name}'"},
  );
  final departments = await fetcher.fetch(
    'departamento',
    typeName: 'ign:departamento',
    query: {'CQL_FILTER': "in1 LIKE '${spec.indecCode}%'"},
  );
  final nationalRoads = await fetcher.fetch(
    'vial_nacional',
    typeName: 'ign:vial_nacional',
    query: {'bbox': _bboxParameter(spec.bbox)},
  );
  final provincialRoads = await fetcher.fetch(
    'vial_provincial',
    typeName: 'ign:vial_provincial',
    query: {'bbox': _bboxParameter(spec.bbox)},
  );
  final rivers = await fetcher.fetch(
    'aguas_perenne',
    typeName: 'ign:lineas_de_aguas_continentales_perenne',
    query: {'bbox': _bboxParameter(spec.bbox)},
  );
  final localities = await fetcher.fetch(
    'localidad_bahra',
    typeName: 'ign:localidad_bahra',
    query: {'CQL_FILTER': "cod_pcia='${spec.indecCode}'"},
  );

  final layers = <String, Object?>{
    'provincialBoundaries': _buildLines(province, spec, 'provincialBoundaries'),
    'departmentBoundaries': _buildLines(
      departments,
      spec,
      'departmentBoundaries',
    ),
    'majorRivers': _buildLines(rivers, spec, 'majorRivers'),
    'nationalRoads': _buildLines(nationalRoads, spec, 'nationalRoads'),
    'provincialRoads': _buildLines(provincialRoads, spec, 'provincialRoads'),
    'majorCities': _buildCities(localities, spec),
    // Parte 6: one label per department/jurisdiction, positioned at its own
    // area-weighted centroid (not the bbox center, which can fall outside an
    // L-shaped or concave department) — rendered by
    // OfflineReferenceMapLayer's own decluttering, fading with the same
    // curve as the boundary lines so labels never outlive them.
    'departmentLabels': _buildDepartmentLabels(departments),
  };

  final document = <String, Object?>{
    'schema': 1,
    'name': 'SuelosAR agronomic reference basemap — ${spec.name}',
    'crs': 'EPSG:4326',
    'projection':
        'WGS84 lon/lat rendered by flutter_map with the same Web Mercator '
        'camera as soil PMTiles',
    'source':
        'Instituto Geografico Nacional de la Republica Argentina WFS '
        '(wms.ign.gob.ar/geoserver/wfs), clipped to the real ${spec.name} '
        'province polygon (layer ign:provincia)',
    'localitySource':
        'GeoRef Argentina (BAHRA/INDEC, layer ign:localidad_bahra), API '
        'oficial del Estado argentino',
    'bbox': spec.bbox,
    'layers': layers,
  };

  const pointLayers = {'majorCities', 'departmentLabels'};
  for (final entry in layers.entries) {
    final value = entry.value as List;
    final isPointLayer = pointLayers.contains(entry.key);
    final vertices = isPointLayer
        ? value.length
        : value.fold<int>(0, (sum, line) => sum + (line as List).length);
    stdout.writeln(
      '${entry.key.padRight(22)} ${value.length.toString().padLeft(5)} '
      '${isPointLayer ? 'labels' : 'lines / $vertices pts'}',
    );
  }

  final encoded = jsonEncode(document);
  stdout.writeln('total ${encoded.length} bytes');

  if (dryRun) {
    stdout.writeln('--dry-run: ${spec.outputPath} not written');
    return;
  }

  File(spec.outputPath).writeAsStringSync(encoded);
  stdout.writeln('wrote ${spec.outputPath}');
}

/// Fase 6 Parte 42B — see the call site in [main] for why this exists.
/// Re-reads the province's *current* output asset, replaces only its
/// `layers.provincialBoundaries` with freshly-fetched IGN geometry from the
/// ArcGIS REST "Provincias" layer, and writes it back. Every other field
/// (`bbox`, `source`, `localitySource`, and every other layer) is copied
/// through unchanged — this never touches roads/rivers/departments/cities,
/// since it never fetches or rebuilds them.
Future<void> _regenerateBoundaryOnly(
  ProvinceSpec spec, {
  required bool dryRun,
}) async {
  final existingRaw = File(spec.outputPath).readAsStringSync();
  final document = jsonDecode(existingRaw) as Map<String, dynamic>;
  final layers = Map<String, Object?>.from(document['layers'] as Map);

  final province = await _fetchProvinciaFromArcgisRest(spec);
  final boundaries = _buildLines(province, spec, 'provincialBoundaries');
  final points = boundaries.fold<int>(0, (sum, line) => sum + line.length);
  final closed =
      boundaries.length == 1 &&
      boundaries.single.first[0] == boundaries.single.last[0] &&
      boundaries.single.first[1] == boundaries.single.last[1];
  stdout.writeln(
    'provincialBoundaries (ArcGIS REST) ${boundaries.length} ring(s) / '
    '$points pts, closed=$closed',
  );

  layers['provincialBoundaries'] = boundaries;
  document['layers'] = layers;

  final encoded = jsonEncode(document);
  stdout.writeln('total ${encoded.length} bytes (was ${existingRaw.length})');

  if (dryRun) {
    stdout.writeln('--dry-run: ${spec.outputPath} not written');
    return;
  }

  File(spec.outputPath).writeAsStringSync(encoded);
  stdout.writeln('wrote ${spec.outputPath}');
}

/// IGN's ArcGIS REST "Provincias" layer (servicio_fondos/MapServer/0) —
/// the same official administrative product as the WFS `ign:provincia`
/// layer (`IN1`/`FNA` here are the same INDEC code / name fields the WFS
/// path filters on as `in1`/`nam`), reachable from this environment when
/// `wms.ign.gob.ar` is not. Returns a GeoJSON `FeatureCollection` shaped
/// exactly like the WFS responses `_buildLines`/`_extractLines` already
/// consume, so no separate parsing path is needed.
Future<Map<String, Object?>> _fetchProvinciaFromArcgisRest(
  ProvinceSpec spec,
) async {
  final uri = Uri.parse(
    'https://ide.ign.gob.ar/geoservicios/rest/services/servicio_fondos/'
    'MapServer/0/query',
  ).replace(
    queryParameters: {
      'where': "IN1='${spec.indecCode}'",
      'outFields': '*',
      'outSR': '4326',
      'f': 'geojson',
    },
  );

  stdout.writeln('fetch  ign:provincia (ArcGIS REST fallback)');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 60);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('provincia (ArcGIS REST): HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('provincia (ArcGIS REST): unexpected response');
    }
    final features = decoded['features'] as List?;
    if (features == null || features.isEmpty) {
      throw StateError(
        'provincia (ArcGIS REST): no feature for IN1=${spec.indecCode}',
      );
    }
    return decoded;
  } finally {
    client.close();
  }
}

String _bboxParameter(List<double> bbox) =>
    '${bbox[0]},${bbox[1]},${bbox[2]},${bbox[3]},EPSG:4326';

/// Every ring/line of every feature, clipped to the working bbox (except
/// `provincialBoundaries` — see below), simplified and rounded — the flat
/// `[[ [lon, lat], ... ], ...]` shape the renderer's `_parseLines` expects.
List<List<List<double>>> _buildLines(
  Map<String, Object?> collection,
  ProvinceSpec spec,
  String layer,
) {
  final tolerance = _simplifyTolerance[layer]!;
  final output = <List<List<double>>>[];

  // `provincialBoundaries` is fetched by exact name (`CQL_FILTER:
  // "nam='...'"`, not `bbox:`), so IGN already returns the complete,
  // correctly-closed province polygon regardless of `spec.bbox` — that
  // bbox is only a padded working extent for the *other* layers (roads,
  // rivers, departments), not the true province edge. Clipping the
  // boundary to it anyway can only ever cut real perimeter off, never
  // remove anything erroneous, and does exactly that whenever the bbox
  // (padded from the soil-PMTiles archive extent, not the political
  // border) is tighter than the true province somewhere — Córdoba's
  // northern edge reaches past its bbox's north side, so the ring came
  // out open there instead of closed.
  final skipClip = layer == 'provincialBoundaries';

  for (final feature in (collection['features'] as List? ?? const [])) {
    final geometry = (feature as Map)['geometry'] as Map?;
    if (geometry == null) continue;
    for (final line in _extractLines(geometry)) {
      final pieces = skipClip ? [line] : _clipToBbox(line, spec.bbox);
      for (final clipped in pieces) {
        final simplified = _simplify(clipped, tolerance);
        if (simplified.length < 2) continue;
        output.add([
          for (final point in simplified)
            [_round(point[0]), _round(point[1])],
        ]);
      }
    }
  }

  return output;
}

/// Flattens any GeoJSON geometry into plain lists of [lon, lat] points:
/// polygons contribute each of their rings as a closed line, which is how
/// the existing assets encode boundaries (the renderer only ever strokes
/// them, never fills).
List<List<List<double>>> _extractLines(Map geometry) {
  final type = geometry['type'] as String?;
  final coordinates = geometry['coordinates'];
  switch (type) {
    case 'LineString':
      return [_asPoints(coordinates as List)];
    case 'MultiLineString':
    case 'Polygon':
      return [for (final part in coordinates as List) _asPoints(part as List)];
    case 'MultiPolygon':
      return [
        for (final polygon in coordinates as List)
          for (final ring in polygon as List) _asPoints(ring as List),
      ];
    default:
      return const [];
  }
}

List<List<double>> _asPoints(List raw) => [
  for (final point in raw)
    [
      ((point as List)[0] as num).toDouble(),
      (point[1] as num).toDouble(),
    ],
];

/// Splits a line into the pieces that fall inside [bbox], dropping the rest.
/// Deliberately vertex-based rather than a true Cohen-Sutherland clip: at
/// these tolerances a segment that merely crosses a corner is invisible, and
/// keeping whole vertices avoids inventing coordinates that are not in the
/// official source.
List<List<List<double>>> _clipToBbox(List<List<double>> line, List<double> bbox) {
  final pieces = <List<List<double>>>[];
  var current = <List<double>>[];

  for (final point in line) {
    final inside =
        point[0] >= bbox[0] &&
        point[0] <= bbox[2] &&
        point[1] >= bbox[1] &&
        point[1] <= bbox[3];
    if (inside) {
      current.add(point);
    } else if (current.isNotEmpty) {
      // Keep the first outside vertex so the line visibly leaves the frame
      // instead of stopping short of it.
      current.add(point);
      pieces.add(current);
      current = <List<double>>[];
    }
  }
  if (current.length >= 2) pieces.add(current);

  return pieces;
}

/// Iterative Douglas-Peucker in degrees. Latitude/longitude are treated as a
/// plane, which at Córdoba's latitude distorts by ~cos(32°) on the longitude
/// axis — irrelevant for a tolerance chosen visually rather than metrically.
List<List<double>> _simplify(List<List<double>> points, double tolerance) {
  if (points.length <= 2) return points;

  final keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;

  final stack = <List<int>>[
    [0, points.length - 1],
  ];
  while (stack.isNotEmpty) {
    final range = stack.removeLast();
    final first = range[0];
    final last = range[1];
    var farthest = -1;
    var farthestDistance = tolerance;

    for (var index = first + 1; index < last; index++) {
      final distance = _perpendicularDistance(
        points[index],
        points[first],
        points[last],
      );
      if (distance > farthestDistance) {
        farthest = index;
        farthestDistance = distance;
      }
    }

    if (farthest != -1) {
      keep[farthest] = true;
      stack.add([first, farthest]);
      stack.add([farthest, last]);
    }
  }

  return [
    for (var index = 0; index < points.length; index++)
      if (keep[index]) points[index],
  ];
}

double _perpendicularDistance(
  List<double> point,
  List<double> lineStart,
  List<double> lineEnd,
) {
  final dx = lineEnd[0] - lineStart[0];
  final dy = lineEnd[1] - lineStart[1];
  if (dx == 0 && dy == 0) {
    return math.sqrt(
      math.pow(point[0] - lineStart[0], 2) + math.pow(point[1] - lineStart[1], 2),
    );
  }
  final numerator =
      ((dy * point[0]) - (dx * point[1]) + (lineEnd[0] * lineStart[1]) -
              (lineEnd[1] * lineStart[0]))
          .abs();
  return numerator / math.sqrt((dx * dx) + (dy * dy));
}

double _round(double value) {
  final factor = math.pow(10, _coordinateDecimals);
  return (value * factor).round() / factor;
}

/// The curated city list, resolved against BAHRA: each name is matched to
/// the locality record of the province, and its official coordinates are
/// taken from there. A name that BAHRA does not carry is reported rather
/// than silently dropped, so the list can't rot unnoticed.
List<Map<String, Object?>> _buildCities(
  Map<String, Object?> localities,
  ProvinceSpec spec,
) {
  final byNormalizedName = <String, Map<String, Object?>>{};
  for (final feature in (localities['features'] as List? ?? const [])) {
    final properties = (feature as Map)['properties'] as Map;
    final name = properties['fna'] as String?;
    if (name == null) continue;
    final latitude = double.tryParse('${properties['lat_gd']}');
    final longitude = double.tryParse('${properties['long_gd']}');
    if (latitude == null || longitude == null) continue;
    byNormalizedName.putIfAbsent(_normalize(name), () => {
      'name': name,
      'lat': _round(latitude),
      'lon': _round(longitude),
    });
  }

  final cities = <Map<String, Object?>>[];
  final missing = <String>[];

  void add(String name, String importance) {
    final record = byNormalizedName[_normalize(name)];
    if (record == null) {
      missing.add(name);
      return;
    }
    cities.add({
      // The curated spelling, which is the label the reader sees; BAHRA's
      // own `fna` sometimes carries administrative suffixes.
      'name': name,
      'lat': record['lat'],
      'lon': record['lon'],
      'importance': importance,
    });
  }

  for (final name in spec.primaryCities) {
    add(name, 'primary');
  }
  for (final name in spec.secondaryCities) {
    add(name, 'secondary');
  }

  if (missing.isNotEmpty) {
    stderr.writeln('BAHRA has no locality named: ${missing.join(', ')}');
  }

  return cities;
}

/// One label per department, at its own area-weighted polygon centroid
/// (shoelace formula on each exterior ring, combined by area across a
/// MultiPolygon's parts) — not the bounding-box center, which lands outside
/// an L-shaped or concave department, and not a name lookup against another
/// dataset: the geometry IS the source, so there is nothing to fail to
/// resolve.
List<Map<String, Object?>> _buildDepartmentLabels(
  Map<String, Object?> departments,
) {
  final labels = <Map<String, Object?>>[];

  for (final feature in (departments['features'] as List? ?? const [])) {
    final properties = (feature as Map)['properties'] as Map;
    final name = (properties['nam'] as String?)?.trim();
    if (name == null || name.isEmpty) continue;

    final geometry = (feature['geometry'] as Map?);
    if (geometry == null) continue;
    final centroid = _polygonCentroid(geometry);
    if (centroid == null) continue;

    labels.add({
      'name': name,
      'lat': _round(centroid[1]),
      'lon': _round(centroid[0]),
    });
  }

  labels.sort(
    (first, second) => (first['name']! as String).compareTo(
      second['name']! as String,
    ),
  );
  return labels;
}

/// Area-weighted centroid of a `Polygon`/`MultiPolygon`'s exterior ring(s),
/// as `[lon, lat]` — holes are ignored (an enclave inside a department would
/// pull the label off-center for no benefit; Córdoba's departments have
/// none). Returns null for any other geometry type or a degenerate (zero
/// total area) shape.
List<double>? _polygonCentroid(Map geometry) {
  final type = geometry['type'] as String?;
  final coordinates = geometry['coordinates'];
  final rings = switch (type) {
    'Polygon' => [(coordinates as List).first as List],
    'MultiPolygon' => [
        for (final polygon in coordinates as List) (polygon as List).first as List,
      ],
    _ => const <List>[],
  };
  if (rings.isEmpty) return null;

  var totalArea = 0.0;
  var weightedX = 0.0;
  var weightedY = 0.0;

  for (final ring in rings) {
    final points = _asPoints(ring);
    if (points.length < 3) continue;

    // Shoelace formula: signed area and centroid of one simple ring.
    var signedArea = 0.0;
    var centroidX = 0.0;
    var centroidY = 0.0;
    for (var i = 0; i < points.length; i++) {
      final current = points[i];
      final next = points[(i + 1) % points.length];
      final cross = current[0] * next[1] - next[0] * current[1];
      signedArea += cross;
      centroidX += (current[0] + next[0]) * cross;
      centroidY += (current[1] + next[1]) * cross;
    }
    signedArea /= 2;
    if (signedArea == 0) continue;
    centroidX /= 6 * signedArea;
    centroidY /= 6 * signedArea;

    final area = signedArea.abs();
    totalArea += area;
    weightedX += centroidX * area;
    weightedY += centroidY * area;
  }

  if (totalArea == 0) return null;
  return [weightedX / totalArea, weightedY / totalArea];
}

String _normalize(String value) {
  const replacements = {
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'ñ': 'n',
  };
  final buffer = StringBuffer();
  for (final character in value.toLowerCase().split('')) {
    buffer.write(replacements[character] ?? character);
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

class _WfsFetcher {
  _WfsFetcher({this.cacheDir});

  final Directory? cacheDir;

  Future<Map<String, Object?>> fetch(
    String cacheKey, {
    required String typeName,
    required Map<String, String> query,
  }) async {
    final cacheFile = cacheDir == null
        ? null
        : File('${cacheDir!.path}${Platform.pathSeparator}$cacheKey.json');
    if (cacheFile != null && cacheFile.existsSync()) {
      stdout.writeln('cache  $typeName');
      return jsonDecode(cacheFile.readAsStringSync()) as Map<String, Object?>;
    }

    final uri = Uri.parse(_wfsEndpoint).replace(
      queryParameters: {
        'service': 'WFS',
        'version': '2.0.0',
        'request': 'GetFeature',
        'outputFormat': 'application/json',
        'srsName': 'EPSG:4326',
        'typeNames': typeName,
        ...query,
      },
    );

    stdout.writeln('fetch  $typeName');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 60);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('$typeName: HTTP ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('$typeName: unexpected WFS response');
      }
      if (cacheFile != null) {
        cacheFile.parent.createSync(recursive: true);
        cacheFile.writeAsStringSync(body);
      }
      return decoded;
    } finally {
      client.close();
    }
  }
}
