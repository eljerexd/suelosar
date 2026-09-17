import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/paths.dart';

/// Result of checking a GIS source's geometries with GDAL/OGR.
class GeometryCheckResult {
  const GeometryCheckResult({
    required this.features,
    required this.nullGeometries,
    required this.invalidGeometries,
    required this.examples,
  });

  final int features;
  final int nullGeometries;
  final int invalidGeometries;

  /// `null:<fid>` / `invalid:<fid>`.
  final List<String> examples;

  Map<String, Object?> toJson() => {
    'features': features,
    'nullGeometries': nullGeometries,
    'invalidGeometries': invalidGeometries,
    'examples': examples,
  };
}

/// Counts null and invalid geometries *before* the pipeline repairs them
/// (`ogr2ogr -makevalid` in `docker/build_map.sh`), using GDAL inside the
/// existing `suelosar-gis-builder` image — Python/GDAL are only available
/// there.
Future<GeometryCheckResult> checkGeometriesWithDocker({
  required String sourceFile,
  required String image,
}) async {
  const script = '''
import json, sys
from osgeo import gdal, ogr
gdal.UseExceptions()
gdal.PushErrorHandler("CPLQuietErrorHandler")
dataset = ogr.Open(sys.argv[1], 0)
layer = dataset.GetLayer(0)
total = null_count = invalid_count = 0
examples = []
for feature in layer:
    total += 1
    geometry = feature.GetGeometryRef()
    if geometry is None:
        null_count += 1
        if len(examples) < 12: examples.append("null:%d" % feature.GetFID())
    elif not geometry.IsValid():
        invalid_count += 1
        if len(examples) < 12: examples.append("invalid:%d" % feature.GetFID())
print("SUELOSAR_RESULT " + json.dumps({"features": total, "null": null_count, "invalid": invalid_count, "examples": examples}))
''';
  final ProcessResult result;
  try {
    result = await Process.run(
      'docker',
      [
        'run',
        '--rm',
        '--mount',
        'type=bind,source=${p.dirname(sourceFile)},target=/src,readonly',
        '--entrypoint',
        'python3',
        image,
        '-c',
        script,
        '/src/${p.basename(sourceFile)}',
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  } on ProcessException catch (e) {
    throw ConfigException('No se pudo ejecutar docker: ${e.message}');
  }
  final line = const LineSplitter()
      .convert(result.stdout as String)
      .where((l) => l.startsWith('SUELOSAR_RESULT '))
      .firstOrNull;
  if (result.exitCode != 0 || line == null) {
    final stderr = (result.stderr as String).trim();
    throw ConfigException(
      'La revisión de geometrías con Docker falló (código ${result.exitCode}). '
      '¿Está Docker Desktop iniciado y existe la imagen $image? '
      '(se construye con: docker compose -f docker/docker-compose.yml build map-builder)\n'
      '${stderr.length > 600 ? stderr.substring(stderr.length - 600) : stderr}',
    );
  }
  final json =
      jsonDecode(line.substring('SUELOSAR_RESULT '.length))
          as Map<String, Object?>;
  return GeometryCheckResult(
    features: json['features'] as int,
    nullGeometries: json['null'] as int,
    invalidGeometries: json['invalid'] as int,
    examples: [for (final e in json['examples'] as List) e as String],
  );
}
