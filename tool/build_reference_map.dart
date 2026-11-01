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
//   dart run tool/build_reference_map.dart cordoba --northern-reference-only
//   dart run tool/build_reference_map.dart santa_fe --department-labels-only
//   dart run tool/build_reference_map.dart <province> --localities-only
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

const String _santaFeReferenceMapPath =
    'assets/maps/agronomic_reference_map_santa_fe.json';
const String _santaFeIndecCode = '82';
const int _santaFeDepartmentCount = 19;
const String _buenosAiresReferenceMapPath =
    'assets/maps/agronomic_reference_map.json';
const String _indecWfsEndpoint =
    'https://geonode.indec.gob.ar/geoserver/geonode/ows';
const String _buenosAiresIndecCode = '06';

// These neighbouring settlements have separate official GeoRef identities,
// but their labels overlap at the shared locality zoom tier. Keep Arroyo
// Dulce ahead of Villa San Jose in the renderer's collision pass.
const Map<String, String> _buenosAiresLocalityImportanceOverrides = {
  '06623140': 'secondary', // Villa San Jose, Partido de Pergamino.
  '06714010': 'primary', // Arroyo Dulce, Partido de Salto.
};
const int _buenosAiresPartidoCount = 135;
const double _buenosAiresAreaKm2PerSphericalDegree = 6371.0088;

Future<void> main(List<String> arguments) async {
  final departmentLabelsOnly = arguments.contains('--department-labels-only');
  final localitiesOnly = arguments.contains('--localities-only');
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
  final validTarget =
      positional.length == 1 &&
      (_provinces.containsKey(positional.single) ||
          (departmentLabelsOnly &&
              (positional.single == 'santa_fe' ||
                  positional.single == 'buenos_aires')) ||
          (localitiesOnly &&
              (positional.single == 'buenos_aires' ||
                  positional.single == 'santa_fe' ||
                  positional.single == 'cordoba')));
  if (!validTarget) {
    stderr.writeln(
      'Usage: dart run tool/build_reference_map.dart cordoba '
      '[--cache-dir <dir>] [--dry-run]\n'
      '   or: dart run tool/build_reference_map.dart santa_fe '
      '--department-labels-only [--cache-dir <dir>] [--dry-run]\n'
      '   or: dart run tool/build_reference_map.dart buenos_aires '
      '--department-labels-only [--dry-run]\n'
      '   or: dart run tool/build_reference_map.dart <province> '
      '--localities-only [--dry-run]',
    );
    exitCode = 64;
    return;
  }

  final dryRun = arguments.contains('--dry-run');
  final cacheIndex = arguments.indexOf('--cache-dir');
  final cacheDir = cacheIndex >= 0 && cacheIndex + 1 < arguments.length
      ? Directory(arguments[cacheIndex + 1])
      : null;

  if (localitiesOnly) {
    if (positional.single == 'buenos_aires') {
      await _regenerateBuenosAiresLocalitiesOnly(dryRun: dryRun);
    } else {
      await _regenerateOtherProvinceLocalitiesOnly(
        provinceId: positional.single,
        dryRun: dryRun,
      );
    }
    return;
  }

  if (departmentLabelsOnly) {
    if (positional.single == 'buenos_aires') {
      await _regenerateBuenosAiresPartidoLabelsOnly(dryRun: dryRun);
      return;
    }
    if (positional.single != 'santa_fe') return;
    await _regenerateDepartmentLabelsOnly(
      outputPath: _santaFeReferenceMapPath,
      indecCode: _santaFeIndecCode,
      expectedCount: _santaFeDepartmentCount,
      dryRun: dryRun,
      cacheDir: cacheDir,
    );
    return;
  }

  final spec = _provinces[positional.single]!;

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

  if (arguments.contains('--northern-reference-only')) {
    await _regenerateNorthernReferenceLinesOnly(
      spec,
      dryRun: dryRun,
      cacheDir: cacheDir,
    );
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

/// Rebuilds only Buenos Aires locality point records from the official
/// Georef API. Existing curated major cities keep their names, coordinates,
/// and importance; additional settlements are introduced at close zoom.
Future<void> _regenerateBuenosAiresLocalitiesOnly({
  required bool dryRun,
}) async {
  final endpoint = Uri.parse(
    'https://apis.datos.gob.ar/georef/api/v2.0/localidades'
    '?provincia=$_buenosAiresIndecCode&max=5000',
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 60);
  late final Map<String, dynamic> responseJson;
  try {
    final response = await (await client.getUrl(endpoint)).close();
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('GeoRef localidades: HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('GeoRef localidades: respuesta inesperada');
    }
    responseJson = decoded;
  } finally {
    client.close();
  }

  final rawRecords = responseJson['localidades'];
  if (rawRecords is! List ||
      rawRecords.length != responseJson['total'] ||
      responseJson['total'] != responseJson['cantidad']) {
    throw StateError('GeoRef localidades: respuesta incompleta');
  }
  final records = rawRecords.cast<Map<String, dynamic>>();
  final output = File(_buenosAiresReferenceMapPath);
  final original = output.readAsStringSync();
  final document = jsonDecode(original) as Map<String, dynamic>;
  final layers = Map<String, Object?>.from(document['layers'] as Map);
  final existing = (layers['majorCities'] as List)
      .cast<Map<String, dynamic>>()
      .where((record) => record['officialSupplement'] != true)
      .toList();
  final localities = buildBuenosAiresLocalityRecords(
    officialRecords: records,
    existingRecords: existing,
  );
  layers['majorCities'] = localities;
  document['layers'] = layers;
  document['localitySource'] =
      'GeoRef Argentina API v2.0 /localidades?provincia=06; '
      'official locality IDs, categories, centroids and Partido IDs; '
      'retrieved 2026-10-31. Duplicate same-name records within one Partido '
      'resolve to one source record, preferring component, simple locality, '
      'then entity. Existing curated labels retain their display name, point '
      'and importance; added simple/component labels fade in z9.5-10.3, '
      'entities z11.5-12.3.';

  final encoded = jsonEncode(document);
  stdout.writeln(
    'Buenos Aires: ${records.length} official rows -> '
    '${localities.length} point labels (${localities.length - existing.length} '
    'added); ${encoded.length} bytes (was ${original.length})',
  );
  if (dryRun) {
    stdout.writeln('--dry-run: $_buenosAiresReferenceMapPath not written');
    return;
  }
  output.writeAsStringSync(encoded);
  stdout.writeln('wrote $_buenosAiresReferenceMapPath');
}

Future<void> _regenerateOtherProvinceLocalitiesOnly({
  required String provinceId,
  required bool dryRun,
}) async {
  final (provinceCode, assetPath) = switch (provinceId) {
    'santa_fe' => (_santaFeIndecCode, _santaFeReferenceMapPath),
    'cordoba' => (_cordoba.indecCode, _cordoba.outputPath),
    _ => throw ArgumentError.value(provinceId, 'provinceId'),
  };
  final endpoint = Uri.https(
    'apis.datos.gob.ar',
    '/georef/api/v2.0/localidades',
    {'provincia': provinceCode, 'max': '5000'},
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 60);
  late final Map<String, dynamic> responseJson;
  try {
    final response = await (await client.getUrl(endpoint)).close();
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('GeoRef localidades: HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(await response.transform(utf8.decoder).join());
    if (decoded is! Map<String, dynamic>) {
      throw StateError('GeoRef localidades: respuesta inesperada');
    }
    responseJson = decoded;
  } finally {
    client.close();
  }

  final rawRecords = responseJson['localidades'];
  if (rawRecords is! List ||
      rawRecords.length != responseJson['total'] ||
      responseJson['total'] != responseJson['cantidad']) {
    throw StateError('GeoRef localidades: respuesta incompleta');
  }
  final file = File(assetPath);
  final original = file.readAsStringSync();
  final document = jsonDecode(original) as Map<String, dynamic>;
  final layers = Map<String, Object?>.from(document['layers'] as Map);
  final existing = (layers['majorCities'] as List).cast<Map<String, dynamic>>();
  final localities = buildOfficialProvinceLocalityRecords(
    officialRecords: rawRecords.cast<Map<String, dynamic>>(),
    existingRecords: existing,
    provinceCode: provinceCode,
  );
  layers['majorCities'] = localities;
  document['layers'] = layers;
  document['localitySource'] =
      'GeoRef Argentina API v2.0 /localidades?provincia=$provinceCode; '
      'official locality IDs, categories, centroids and department IDs; '
      'retrieved 2026-10-31. Existing curated point names, coordinates and '
      'importance are retained; source identity is joined by exact normalized '
      'name and nearest official locality group. Added points use simple or '
      'compound locality visibility at z9.5-10.3 and entity visibility at '
      'z11.5-12.3.';

  final encoded = jsonEncode(document);
  stdout.writeln(
    '$provinceId: ${rawRecords.length} official rows -> '
    '${localities.length} point labels (${localities.length - existing.length} '
    'added); ${encoded.length} bytes (was ${original.length})',
  );
  if (dryRun) {
    stdout.writeln('--dry-run: $assetPath not written');
    return;
  }
  file.writeAsStringSync(encoded);
  stdout.writeln('wrote $assetPath');
}

/// Merges official GeoRef locality points into the existing Santa Fe or
/// Córdoba basemap. Curated points retain their exact display name,
/// coordinates, and importance; verified GeoRef identity enriches locality
/// priority, while only genuinely unmatched department/name groups add a
/// new point.
List<Map<String, Object?>> buildOfficialProvinceLocalityRecords({
  required List<Map<String, dynamic>> officialRecords,
  required List<Map<String, dynamic>> existingRecords,
  required String provinceCode,
}) {
  final sourceIds = <String>{};
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final record in officialRecords) {
    final id = record['id'];
    final province = record['provincia'] as Map?;
    final department = record['departamento'] as Map?;
    final centroid = record['centroide'] as Map?;
    final name = record['nombre'];
    if (id is! String ||
        id.isEmpty ||
        !sourceIds.add(id) ||
        province?['id'] != provinceCode ||
        department?['id'] is! String ||
        name is! String ||
        name.trim().isEmpty ||
        centroid?['lat'] is! num ||
        centroid?['lon'] is! num) {
      throw StateError(
        'GeoRef localidades contiene identidad o punto inválido',
      );
    }
    final latitude = (centroid!['lat'] as num).toDouble();
    final longitude = (centroid['lon'] as num).toDouble();
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw StateError('GeoRef localidad $id tiene coordenadas inválidas');
    }
    final key = '${department!['id']}|${_localityKey(name)}';
    groups.putIfAbsent(key, () => []).add(record);
  }
  for (final group in groups.values) {
    group.sort(_compareLocalitySourcePriority);
  }

  final consumedGroups = <String>{};
  final retained = <Map<String, Object?>>[];
  for (final current in existingRecords) {
    final name = current['name'];
    final latitude = current['lat'];
    final longitude = current['lon'];
    if (name is! String || latitude is! num || longitude is! num) {
      throw StateError(
        'El punto curado de localidad no tiene nombre/coordenadas',
      );
    }
    final matches = <(String, Map<String, dynamic>)>[];
    for (final entry in groups.entries) {
      if (consumedGroups.contains(entry.key)) continue;
      final source = entry.value.first;
      if (_localityKey(source['nombre'] as String) == _localityKey(name)) {
        matches.add((entry.key, source));
      }
    }
    if (matches.isEmpty) {
      retained.add(Map<String, Object?>.from(current));
      continue;
    }
    matches.sort((first, second) {
      double distance(Map<String, dynamic> source) {
        final point = source['centroide'] as Map;
        return _coordinateDistance(
          latitude.toDouble(),
          longitude.toDouble(),
          (point['lat'] as num).toDouble(),
          (point['lon'] as num).toDouble(),
        );
      }

      return distance(first.$2).compareTo(distance(second.$2));
    });
    final selected = matches.first;
    if (consumedGroups.add(selected.$1)) {
      final source = groups[selected.$1]!..sort(_compareLocalitySourcePriority);
      final canonical = source.first;
      final department = canonical['departamento'] as Map;
      retained.add({
        ...current,
        'sourceId': canonical['id'],
        'sourceCategory': canonical['categoria'],
        'departmentId': department['id'],
        'departmentName': department['nombre'],
        'provinceCode': provinceCode,
      });
    } else {
      retained.add(Map<String, Object?>.from(current));
    }
  }

  final added = <Map<String, Object?>>[];
  for (final entry in groups.entries) {
    if (consumedGroups.contains(entry.key)) continue;
    final candidates = entry.value..sort(_compareLocalitySourcePriority);
    final source = candidates.first;
    final centroid = source['centroide'] as Map;
    final department = source['departamento'] as Map;
    final category = source['categoria'] as String;
    final isEntity = category == 'Entidad';
    added.add({
      'name': source['nombre'],
      'lon': _roundToSixDecimals((centroid['lon'] as num).toDouble()),
      'lat': _roundToSixDecimals((centroid['lat'] as num).toDouble()),
      'importance': isEntity ? 'quaternary' : 'tertiary',
      'sourceId': source['id'],
      'sourceCategory': category,
      'departmentId': department['id'],
      'departmentName': department['nombre'],
      'provinceCode': provinceCode,
      'minZoom': isEntity ? 11.5 : 9.5,
      'fadeInEndZoom': isEntity ? 12.3 : 10.3,
      'markerRadius': 2.3,
      'officialSupplement': true,
    });
  }
  added.sort((first, second) {
    final zoom = (first['minZoom'] as double).compareTo(
      second['minZoom'] as double,
    );
    if (zoom != 0) return zoom;
    final department = (first['departmentId'] as String).compareTo(
      second['departmentId'] as String,
    );
    if (department != 0) return department;
    return (first['name'] as String).compareTo(second['name'] as String);
  });
  return [...retained, ...added];
}

/// Joins the 30 established cartographic labels to official Georef identity,
/// then adds one canonical point for each remaining official locality group.
/// Public so the source-selection rules can be covered with deterministic
/// fixtures without a network request.
List<Map<String, Object?>> buildBuenosAiresLocalityRecords({
  required List<Map<String, dynamic>> officialRecords,
  required List<Map<String, dynamic>> existingRecords,
}) {
  final ids = <String>{};
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final record in officialRecords) {
    final id = record['id'];
    final province = record['provincia'] as Map?;
    final department = record['departamento'] as Map?;
    final centroid = record['centroide'] as Map?;
    final name = record['nombre'];
    if (id is! String ||
        id.isEmpty ||
        !ids.add(id) ||
        province?['id'] != _buenosAiresIndecCode ||
        department?['id'] is! String ||
        name is! String ||
        name.trim().isEmpty ||
        centroid?['lat'] is! num ||
        centroid?['lon'] is! num) {
      throw StateError(
        'GeoRef localidades contiene identidad o punto inválido',
      );
    }
    final lat = (centroid!['lat'] as num).toDouble();
    final lon = (centroid['lon'] as num).toDouble();
    if (!lat.isFinite ||
        !lon.isFinite ||
        lat < -90 ||
        lat > 90 ||
        lon < -180 ||
        lon > 180) {
      throw StateError('GeoRef localidad $id tiene coordenadas inválidas');
    }
    final key = '${department!['id']}|${_localityKey(name)}';
    groups.putIfAbsent(key, () => []).add(record);
  }

  final result = <Map<String, Object?>>[];
  final consumedGroups = <String>{};
  for (final current in existingRecords) {
    final name = current['name'] as String;
    final oldLat = (current['lat'] as num).toDouble();
    final oldLon = (current['lon'] as num).toDouble();
    final candidates =
        officialRecords
            .where(
              (record) =>
                  _normalize(record['nombre'] as String) == _normalize(name),
            )
            .toList()
          ..sort((a, b) {
            final aPoint = a['centroide'] as Map;
            final bPoint = b['centroide'] as Map;
            final aDistance = _coordinateDistance(
              oldLat,
              oldLon,
              (aPoint['lat'] as num).toDouble(),
              (aPoint['lon'] as num).toDouble(),
            );
            final bDistance = _coordinateDistance(
              oldLat,
              oldLon,
              (bPoint['lat'] as num).toDouble(),
              (bPoint['lon'] as num).toDouble(),
            );
            return aDistance.compareTo(bDistance);
          });
    if (candidates.isEmpty ||
        _coordinateDistance(
              oldLat,
              oldLon,
              ((candidates.first['centroide'] as Map)['lat'] as num).toDouble(),
              ((candidates.first['centroide'] as Map)['lon'] as num).toDouble(),
            ) >
            0.002) {
      throw StateError('No hay identidad GeoRef inequívoca para $name');
    }
    final source = candidates.first;
    final sourceDepartment = source['departamento'] as Map;
    consumedGroups.add(
      '${sourceDepartment['id']}|${_localityKey(source['nombre'] as String)}',
    );
    result.add({
      ...current,
      'sourceId': source['id'],
      'sourceCategory': source['categoria'],
      'departmentId': sourceDepartment['id'],
      'departmentName': sourceDepartment['nombre'],
      'provinceCode': _buenosAiresIndecCode,
    });
  }

  final added = <Map<String, Object?>>[];
  for (final entry in groups.entries) {
    if (consumedGroups.contains(entry.key)) continue;
    final candidates = entry.value..sort(_compareLocalitySourcePriority);
    final source = candidates.first;
    final centroid = source['centroide'] as Map;
    final category = source['categoria'] as String;
    final isEntity = category == 'Entidad';
    final department = source['departamento'] as Map;
    added.add({
      'name': source['nombre'],
      'lon': _roundToSixDecimals((centroid['lon'] as num).toDouble()),
      'lat': _roundToSixDecimals((centroid['lat'] as num).toDouble()),
      'importance':
          _buenosAiresLocalityImportanceOverrides[source['id'] as String] ??
          (isEntity ? 'quaternary' : 'tertiary'),
      'sourceId': source['id'],
      'sourceCategory': category,
      'departmentId': department['id'],
      'departmentName': department['nombre'],
      'provinceCode': _buenosAiresIndecCode,
      'minZoom': isEntity ? 11.5 : 9.5,
      'fadeInEndZoom': isEntity ? 12.3 : 10.3,
      'officialSupplement': true,
    });
  }
  added.sort((a, b) {
    final zoom = (a['minZoom'] as double).compareTo(b['minZoom'] as double);
    if (zoom != 0) return zoom;
    final department = (a['departmentId'] as String).compareTo(
      b['departmentId'] as String,
    );
    if (department != 0) return department;
    return (a['name'] as String).compareTo(b['name'] as String);
  });
  return [...result, ...added];
}

int _compareLocalitySourcePriority(
  Map<String, dynamic> first,
  Map<String, dynamic> second,
) {
  int rank(Map<String, dynamic> record) => switch (record['categoria']) {
    'Componente de localidad compuesta' => 0,
    'Localidad simple' => 1,
    'Entidad' => 2,
    _ => 3,
  };
  final priority = rank(first).compareTo(rank(second));
  return priority != 0
      ? priority
      : (first['id'] as String).compareTo(second['id'] as String);
}

String _localityKey(String value) =>
    _normalize(value.replaceAll('ñ', '~').replaceAll('Ñ', '~'));

double _coordinateDistance(
  double latA,
  double lonA,
  double latB,
  double lonB,
) => math.sqrt(math.pow(latA - latB, 2) + math.pow(lonA - lonB, 2));

double _roundToSixDecimals(double value) => (value * 1000000).round() / 1000000;

/// Adds Buenos Aires' official Partido names and interior label points to the
/// existing basemap. The INDEC geometries are used only to derive positions;
/// the renderer and all existing IGN line layers remain unchanged.
Future<void> _regenerateBuenosAiresPartidoLabelsOnly({
  required bool dryRun,
}) async {
  final uri = Uri.parse(_indecWfsEndpoint).replace(
    queryParameters: {
      'service': 'WFS',
      'version': '1.1.0',
      'request': 'GetFeature',
      'typeName': 'geonode:departamentos',
      'outputFormat': 'application/json',
      'srsName': 'EPSG:4326',
      'CQL_FILTER': "cpr='$_buenosAiresIndecCode' AND gna='Partido'",
    },
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  late final Map<String, Object?> partidos;
  try {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('INDEC WFS: HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(await response.transform(utf8.decoder).join());
    if (decoded is! Map<String, dynamic>) {
      throw StateError('INDEC WFS returned an unexpected response');
    }
    partidos = decoded;
  } finally {
    client.close();
  }

  final features = partidos['features'] as List? ?? const [];
  if (features.length != _buenosAiresPartidoCount) {
    throw StateError(
      'Expected $_buenosAiresPartidoCount INDEC Partidos, got '
      '${features.length}',
    );
  }
  final names = <String>{};
  final codes = <String>{};
  for (final feature in features.cast<Map>()) {
    final properties = feature['properties'] as Map;
    final name = (properties['nam'] as String?)?.trim() ?? '';
    final code = (properties['cde'] as String?)?.trim() ?? '';
    if (properties['cpr'] != _buenosAiresIndecCode ||
        properties['gna'] != 'Partido' ||
        name.isEmpty ||
        code.isEmpty ||
        !names.add(name) ||
        !codes.add(code)) {
      throw StateError(
        'INDEC Partido record has missing or duplicate identity',
      );
    }
    if (feature['geometry'] is! Map) {
      throw StateError('$name has no polygon geometry in INDEC');
    }
  }

  final labels = _buildDepartmentLabels(
    partidos,
    minZoomForGeometry: (geometry) =>
        _buenosAiresPartidoMinZoom(_geometryAreaSquareKm(geometry)),
  );
  if (labels.length != _buenosAiresPartidoCount ||
      labels.map((label) => label['name']).toSet().length != names.length) {
    throw StateError(
      'Could not derive an interior label point for every INDEC Partido',
    );
  }
  for (final feature in features.cast<Map>()) {
    final properties = feature['properties'] as Map;
    final name = (properties['nam'] as String).trim();
    final label = labels.singleWhere((candidate) => candidate['name'] == name);
    final point = <double>[
      (label['lon']! as num).toDouble(),
      (label['lat']! as num).toDouble(),
    ];
    if (!point.every((coordinate) => coordinate.isFinite) ||
        !_geometryContainsPoint(feature['geometry'] as Map, point)) {
      throw StateError('$name label point is not inside its INDEC geometry');
    }
  }

  final output = File(_buenosAiresReferenceMapPath);
  final original = output.readAsStringSync();
  final document = jsonDecode(original) as Map<String, dynamic>;
  final layers = Map<String, Object?>.from(document['layers'] as Map);
  layers['departmentLabels'] = labels;
  document['layers'] = layers;
  document['departmentLabelSource'] =
      'INDEC WFS geonode:departamentos; cpr=$_buenosAiresIndecCode '
      'AND gna=Partido; source identity cde; positions derived from each '
      'EPSG:4326 MultiPolygon; one label per Partido. minZoom is derived '
      'from spherical area in km2: >=5000:7.0, >=2500:7.7, >=1000:8.6, '
      'otherwise:9.4.';

  final encoded = jsonEncode(document);
  stdout.writeln(
    'Buenos Aires: ${labels.length} INDEC Partido labels; '
    '${encoded.length} bytes (was ${original.length})',
  );
  if (dryRun) {
    stdout.writeln('--dry-run: $_buenosAiresReferenceMapPath not written');
    return;
  }
  output.writeAsStringSync(encoded);
  stdout.writeln('wrote $_buenosAiresReferenceMapPath');
}

/// Adds only department labels to an existing reference-map asset. All other
/// metadata and layers are copied through unchanged.
Future<void> _regenerateDepartmentLabelsOnly({
  required String outputPath,
  required String indecCode,
  required int expectedCount,
  required bool dryRun,
  required Directory? cacheDir,
}) async {
  final outputFile = File(outputPath);
  final existingRaw = outputFile.readAsStringSync();
  final document = jsonDecode(existingRaw) as Map<String, dynamic>;
  final layers = Map<String, Object?>.from(document['layers'] as Map);
  final departments = await _WfsFetcher(cacheDir: cacheDir).fetch(
    'departamento_labels_santa_fe',
    typeName: 'ign:departamento',
    query: {'CQL_FILTER': "in1 LIKE '$indecCode%'"},
  );
  final features = departments['features'] as List? ?? const [];
  if (features.length != expectedCount) {
    throw StateError(
      'Expected $expectedCount IGN departments for code $indecCode, got '
      '${features.length}',
    );
  }

  final labels = _buildDepartmentLabels(departments);
  final names = labels.map((label) => label['name']! as String).toSet();
  if (labels.length != expectedCount || names.length != expectedCount) {
    final sourceNames = features
        .map(
          (feature) =>
              ((((feature as Map)['properties'] as Map)['nam']) as String)
                  .trim(),
        )
        .toSet();
    throw StateError(
      'Expected $expectedCount unique department labels, got '
      '${labels.length} labels / ${names.length} names; '
      'missing=${sourceNames.difference(names).toList()..sort()}',
    );
  }

  for (final feature in features.cast<Map>()) {
    final name = ((feature['properties'] as Map)['nam'] as String).trim();
    final label = labels.singleWhere((candidate) => candidate['name'] == name);
    final point = <double>[
      (label['lon']! as num).toDouble(),
      (label['lat']! as num).toDouble(),
    ];
    if (!point.every((coordinate) => coordinate.isFinite) ||
        !_geometryContainsPoint(feature['geometry'] as Map, point)) {
      throw StateError(
        '$name label is not a finite point inside its department',
      );
    }
  }

  layers['departmentLabels'] = labels;
  document['layers'] = layers;
  final encoded = jsonEncode(document);
  stdout.writeln(
    'departmentLabels ${labels.length} labels; '
    'total ${encoded.length} bytes (was ${existingRaw.length})',
  );
  if (dryRun) {
    stdout.writeln('--dry-run: $outputPath not written');
    return;
  }
  outputFile.writeAsStringSync(encoded);
  stdout.writeln('wrote $outputPath');
}

/// Replaces only the four IGN line layers clipped by Córdoba's former
/// soil-archive-derived working bbox. The complete provincial boundary in the
/// existing asset defines the corrected extent, with the intended 0.2° margin.
/// Metadata, cities, labels, and the provincial boundary remain unchanged.
Future<void> _regenerateNorthernReferenceLinesOnly(
  ProvinceSpec spec, {
  required bool dryRun,
  required Directory? cacheDir,
}) async {
  final outputFile = File(spec.outputPath);
  final existingRaw = outputFile.readAsStringSync();
  final document = jsonDecode(existingRaw) as Map<String, dynamic>;
  final layers = Map<String, Object?>.from(document['layers'] as Map);
  final boundary = (layers['provincialBoundaries'] as List)
      .map(
        (line) => (line as List)
            .map(
              (point) => (point as List)
                  .map((coordinate) => (coordinate as num).toDouble())
                  .toList(),
            )
            .toList(),
      )
      .toList();
  final boundaryBounds = _lineBounds(boundary);
  const padding = 0.2;
  final correctedBbox = <double>[
    boundaryBounds[0] - padding,
    boundaryBounds[1] - padding,
    boundaryBounds[2] + padding,
    boundaryBounds[3] + padding,
  ];
  stdout.writeln(
    'corrected reference bbox ${correctedBbox.map(_round).toList()} '
    '(from stored provincial boundary)',
  );

  final fetcher = _WfsFetcher(cacheDir: cacheDir);
  final departments = await fetcher.fetch(
    'departamento_full_cordoba',
    typeName: 'ign:departamento',
    query: {'CQL_FILTER': "in1 LIKE '${spec.indecCode}%'"},
  );
  final nationalRoads = await fetcher.fetch(
    'vial_nacional_full_cordoba',
    typeName: 'ign:vial_nacional',
    query: {'bbox': _bboxParameter(correctedBbox)},
  );
  final provincialRoads = await fetcher.fetch(
    'vial_provincial_full_cordoba',
    typeName: 'ign:vial_provincial',
    query: {'bbox': _bboxParameter(correctedBbox)},
  );
  final rivers = await fetcher.fetch(
    'aguas_perenne_full_cordoba',
    typeName: 'ign:lineas_de_aguas_continentales_perenne',
    query: {'bbox': _bboxParameter(correctedBbox)},
  );

  final departmentFeatures = departments['features'] as List? ?? const [];
  if (departmentFeatures.length != 26) {
    throw StateError(
      'Expected 26 IGN departments for Córdoba, got '
      '${departmentFeatures.length}',
    );
  }

  final replacements = <String, List<List<List<double>>>>{
    'departmentBoundaries': _buildLines(
      departments,
      spec,
      'departmentBoundaries',
      clipBbox: correctedBbox,
    ),
    'majorRivers': _buildLines(
      rivers,
      spec,
      'majorRivers',
      clipBbox: correctedBbox,
    ),
    'nationalRoads': _buildLines(
      nationalRoads,
      spec,
      'nationalRoads',
      clipBbox: correctedBbox,
    ),
    'provincialRoads': _buildLines(
      provincialRoads,
      spec,
      'provincialRoads',
      clipBbox: correctedBbox,
    ),
  };

  for (final entry in replacements.entries) {
    final before = (layers[entry.key] as List?) ?? const [];
    final beforePoints = before.fold<int>(
      0,
      (sum, line) => sum + (line as List).length,
    );
    final afterPoints = entry.value.fold<int>(
      0,
      (sum, line) => sum + line.length,
    );
    final bounds = _lineBounds(entry.value);
    if (bounds[3] <= spec.bbox[3]) {
      throw StateError(
        '${entry.key} still does not extend north of ${spec.bbox[3]}: '
        '${bounds[3]}',
      );
    }
    stdout.writeln(
      '${entry.key.padRight(22)} ${before.length} lines / $beforePoints pts '
      '-> ${entry.value.length} lines / $afterPoints pts; '
      'bounds=${bounds.map(_round).toList()}',
    );
    layers[entry.key] = entry.value;
  }

  document['layers'] = layers;
  final encoded = jsonEncode(document);
  stdout.writeln('total ${encoded.length} bytes (was ${existingRaw.length})');

  if (dryRun) {
    stdout.writeln('--dry-run: ${spec.outputPath} not written');
    return;
  }

  outputFile.writeAsStringSync(encoded);
  stdout.writeln('wrote ${spec.outputPath}');
}

List<double> _lineBounds(List<List<List<double>>> lines) {
  var west = double.infinity;
  var south = double.infinity;
  var east = double.negativeInfinity;
  var north = double.negativeInfinity;
  for (final line in lines) {
    for (final point in line) {
      west = math.min(west, point[0]);
      south = math.min(south, point[1]);
      east = math.max(east, point[0]);
      north = math.max(north, point[1]);
    }
  }
  if (![west, south, east, north].every((value) => value.isFinite)) {
    throw StateError('Cannot derive bounds from empty or invalid linework');
  }
  return [west, south, east, north];
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
  final uri =
      Uri.parse(
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
  String layer, {
  List<double>? clipBbox,
}) {
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
      final pieces = skipClip
          ? [line]
          : _clipToBbox(line, clipBbox ?? spec.bbox);
      for (final clipped in pieces) {
        final simplified = _simplify(clipped, tolerance);
        if (simplified.length < 2) continue;
        output.add([
          for (final point in simplified) [_round(point[0]), _round(point[1])],
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
    [((point as List)[0] as num).toDouble(), (point[1] as num).toDouble()],
];

/// Splits a line into the pieces that fall inside [bbox], dropping the rest.
/// Deliberately vertex-based rather than a true Cohen-Sutherland clip: at
/// these tolerances a segment that merely crosses a corner is invisible, and
/// keeping whole vertices avoids inventing coordinates that are not in the
/// official source.
List<List<List<double>>> _clipToBbox(
  List<List<double>> line,
  List<double> bbox,
) {
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
      math.pow(point[0] - lineStart[0], 2) +
          math.pow(point[1] - lineStart[1], 2),
    );
  }
  final numerator =
      ((dy * point[0]) -
              (dx * point[1]) +
              (lineEnd[0] * lineStart[1]) -
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
    byNormalizedName.putIfAbsent(
      _normalize(name),
      () => {'name': name, 'lat': _round(latitude), 'lon': _round(longitude)},
    );
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
  Map<String, Object?> departments, {
  double Function(Map geometry)? minZoomForGeometry,
}) {
  final labels = <Map<String, Object?>>[];

  for (final feature in (departments['features'] as List? ?? const [])) {
    final properties = (feature as Map)['properties'] as Map;
    final name = (properties['nam'] as String?)?.trim();
    if (name == null || name.isEmpty) continue;

    final geometry = (feature['geometry'] as Map?);
    if (geometry == null) continue;
    final centroid = _departmentLabelPoint(geometry);
    if (centroid == null) continue;

    labels.add({
      'name': name,
      'lat': _round(centroid[1]),
      'lon': _round(centroid[0]),
      if (minZoomForGeometry != null) 'minZoom': minZoomForGeometry(geometry),
    });
  }

  labels.sort(
    (first, second) =>
        (first['name']! as String).compareTo(second['name']! as String),
  );
  return labels;
}

double _buenosAiresPartidoMinZoom(double areaSquareKm) {
  if (!areaSquareKm.isFinite || areaSquareKm <= 0) {
    throw StateError('INDEC Partido geometry has no measurable area');
  }
  if (areaSquareKm >= 5000) return 7.0;
  if (areaSquareKm >= 2500) return 7.7;
  if (areaSquareKm >= 1000) return 8.6;
  return 9.4;
}

double _geometryAreaSquareKm(Map geometry) {
  final type = geometry['type'];
  final coordinates = geometry['coordinates'];
  final polygons = switch (type) {
    'Polygon' => [coordinates as List],
    'MultiPolygon' => (coordinates as List).cast<List>(),
    _ => const <List>[],
  };
  if (polygons.isEmpty) return 0;

  var totalArea = 0.0;
  for (final polygon in polygons) {
    if (polygon.isEmpty) continue;
    var polygonArea = _sphericalRingAreaSquareKm(polygon.first as List);
    for (final hole in polygon.skip(1)) {
      polygonArea -= _sphericalRingAreaSquareKm(hole as List);
    }
    totalArea += math.max(0, polygonArea);
  }
  return totalArea;
}

double _sphericalRingAreaSquareKm(List rawRing) {
  final points = _asPoints(rawRing);
  if (points.length < 3) return 0;

  var sum = 0.0;
  for (var index = 0; index < points.length; index++) {
    final current = points[index];
    final next = points[(index + 1) % points.length];
    final longitudeDelta = (next[0] - current[0]) * math.pi / 180;
    final currentLatitude = current[1] * math.pi / 180;
    final nextLatitude = next[1] * math.pi / 180;
    sum +=
        longitudeDelta *
        (2 + math.sin(currentLatitude) + math.sin(nextLatitude));
  }
  final radiusSquared =
      _buenosAiresAreaKm2PerSphericalDegree *
      _buenosAiresAreaKm2PerSphericalDegree;
  return sum.abs() * radiusSquared / 2;
}

List<double>? _departmentLabelPoint(Map geometry) {
  final centroid = _polygonCentroid(geometry);
  if (centroid != null && _geometryContainsPoint(geometry, centroid)) {
    return centroid;
  }

  final polygons =
      switch (geometry['type']) {
        'Polygon' => [geometry['coordinates'] as List],
        'MultiPolygon' => (geometry['coordinates'] as List).cast<List>(),
        _ => const <List>[],
      }..sort(
        (first, second) => _ringArea(
          second.first as List,
        ).compareTo(_ringArea(first.first as List)),
      );
  for (final polygon in polygons) {
    final polygonGeometry = <String, Object?>{
      'type': 'Polygon',
      'coordinates': polygon,
    };
    final polygonCentroid = _polygonCentroid(polygonGeometry);
    if (polygonCentroid != null &&
        _geometryContainsPoint(polygonGeometry, polygonCentroid)) {
      return polygonCentroid;
    }
    final interiorPoint = _polygonInteriorPoint(polygon);
    if (interiorPoint != null &&
        _geometryContainsPoint(polygonGeometry, interiorPoint)) {
      return interiorPoint;
    }
  }
  return null;
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
      for (final polygon in coordinates as List)
        (polygon as List).first as List,
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

bool _geometryContainsPoint(Map geometry, List<double> point) {
  bool polygonContainsPoint(List polygon) {
    if (polygon.isEmpty || !_ringContainsPoint(polygon.first as List, point)) {
      return false;
    }
    return polygon
        .skip(1)
        .every((hole) => !_ringContainsPoint(hole as List, point));
  }

  return switch (geometry['type']) {
    'Polygon' => polygonContainsPoint(geometry['coordinates'] as List),
    'MultiPolygon' => (geometry['coordinates'] as List).any(
      (polygon) => polygonContainsPoint(polygon as List),
    ),
    _ => false,
  };
}

bool _ringContainsPoint(List ring, List<double> point) {
  final points = _asPoints(ring);
  if (points.length < 3) return false;
  var inside = false;
  for (
    var current = 0, previous = points.length - 1;
    current < points.length;
    previous = current++
  ) {
    final currentPoint = points[current];
    final previousPoint = points[previous];
    final crossesLatitude =
        (currentPoint[1] > point[1]) != (previousPoint[1] > point[1]);
    if (!crossesLatitude) continue;
    final crossingLongitude =
        (previousPoint[0] - currentPoint[0]) *
            (point[1] - currentPoint[1]) /
            (previousPoint[1] - currentPoint[1]) +
        currentPoint[0];
    if (point[0] < crossingLongitude) inside = !inside;
  }
  return inside;
}

double _ringArea(List ring) {
  final points = _asPoints(ring);
  var twiceArea = 0.0;
  for (var index = 0; index < points.length; index++) {
    final current = points[index];
    final next = points[(index + 1) % points.length];
    twiceArea += current[0] * next[1] - next[0] * current[1];
  }
  return twiceArea.abs() / 2;
}

List<double>? _polygonInteriorPoint(List polygon) {
  final latitudeBreaks = <double>{
    for (final ring in polygon)
      for (final point in _asPoints(ring as List)) point[1],
  }.toList()..sort();
  List<double>? bestPoint;
  var bestWidth = 0.0;

  for (var index = 0; index + 1 < latitudeBreaks.length; index++) {
    final south = latitudeBreaks[index];
    final north = latitudeBreaks[index + 1];
    if (south == north) continue;
    final latitude = (south + north) / 2;
    final crossings = <double>[];
    for (final rawRing in polygon) {
      final points = _asPoints(rawRing as List);
      for (
        var current = 0, previous = points.length - 1;
        current < points.length;
        previous = current++
      ) {
        final currentPoint = points[current];
        final previousPoint = points[previous];
        if ((currentPoint[1] > latitude) == (previousPoint[1] > latitude)) {
          continue;
        }
        crossings.add(
          (previousPoint[0] - currentPoint[0]) *
                  (latitude - currentPoint[1]) /
                  (previousPoint[1] - currentPoint[1]) +
              currentPoint[0],
        );
      }
    }
    crossings.sort();
    for (var crossing = 0; crossing + 1 < crossings.length; crossing += 2) {
      final width = crossings[crossing + 1] - crossings[crossing];
      if (width > bestWidth) {
        bestWidth = width;
        bestPoint = [
          (crossings[crossing] + crossings[crossing + 1]) / 2,
          latitude,
        ];
      }
    }
  }
  return bestPoint;
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 60);
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
