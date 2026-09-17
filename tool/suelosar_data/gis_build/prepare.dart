import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../config/province_definition.dart';
import '../normalize/field_mapping.dart';
import '../schema/suelosar_schema.dart';
import '../sources/geojson_reader.dart';

/// Which file the Docker pipeline receives.
enum MapInputKind {
  /// The province's original GIS file, unchanged.
  source('source'),

  /// `work/map_input/map_input.geojson`, built from the normalized GIS.
  normalized('normalized');

  const MapInputKind(this.key);
  final String key;
}

/// A geographic extent in degrees.
class Extent {
  const Extent(
    this.minLongitude,
    this.minLatitude,
    this.maxLongitude,
    this.maxLatitude,
  );

  factory Extent.fromJson(Map<String, Object?> json) => Extent(
    (json['minLongitude']! as num).toDouble(),
    (json['minLatitude']! as num).toDouble(),
    (json['maxLongitude']! as num).toDouble(),
    (json['maxLatitude']! as num).toDouble(),
  );

  final double minLongitude;
  final double minLatitude;
  final double maxLongitude;
  final double maxLatitude;

  Map<String, Object?> toJson() => {
    'minLongitude': minLongitude,
    'minLatitude': minLatitude,
    'maxLongitude': maxLongitude,
    'maxLatitude': maxLatitude,
  };
}

class MapInputDecision {
  const MapInputDecision({
    required this.kind,
    required this.reason,
    required this.file,
    required this.optionalAttributes,
  });

  final MapInputKind kind;
  final String reason;

  /// The file handed to Docker (its directory is mounted read-only).
  final String file;

  /// Schema fields the province declares `absent` (build_map.sh's
  /// OPTIONAL_ATTRIBUTES).
  final List<String> optionalAttributes;

  /// Every file Docker reads: the input plus shapefile sidecars.
  List<String> get inputFiles {
    if (p.extension(file).toLowerCase() != '.shp') return [file];
    final base = file.substring(0, file.length - 4);
    // One path per sidecar: on case-insensitive file systems both spellings
    // exist.
    return [
      for (final extension in ['.shp', '.dbf', '.shx', '.prj', '.cpg'])
        ?[
          '$base$extension',
          '$base${extension.toUpperCase()}',
        ].where((candidate) => File(candidate).existsSync()).firstOrNull,
    ];
  }
}

/// True when every mapped field is copied from a column with its own name
/// — the source already follows the SuelosAR schema.
bool isDirectMapping(FieldMapping mapping) {
  for (final field in SuelosArSchema.requiredFields) {
    final rule = mapping.ruleFor(field);
    if (rule is! CopyRule || rule.source != field) return false;
  }
  return mapping.rules.every(
    (rule) => rule is CopyRule && rule.source == rule.target,
  );
}

/// Schema fields declared `absent`.
List<String> absentFields(FieldMapping mapping) => [
  for (final rule in mapping.rules.whereType<AbsentRule>())
    if (SuelosArSchema.requiredFields.contains(rule.target)) rule.target,
];

/// Decides the Docker input (design D2): the original file when it is a
/// shapefile mapped column-for-column (`pmtiles.input: auto`), otherwise the
/// normalized GIS. Returns `(decision, problem)`; a problem means the
/// declared `pmtiles.input` cannot be honoured (PRE001).
(MapInputDecision?, String?) decideMapInput(ProvinceDefinition d) {
  final pmtiles = d.pmtiles!;
  final direct = isDirectMapping(d.gis.mapping);
  final optional = absentFields(d.gis.mapping);
  MapInputDecision source(String reason) => MapInputDecision(
    kind: MapInputKind.source,
    reason: reason,
    file: d.gis.source,
    optionalAttributes: optional,
  );
  MapInputDecision normalized(String reason) => MapInputDecision(
    kind: MapInputKind.normalized,
    reason: reason,
    file: d.mapInputFile,
    optionalAttributes: optional,
  );
  switch (pmtiles.input) {
    case PmtilesInput.source:
      if (!direct) {
        return (
          null,
          'pmtiles.input: source requiere que gis.mapping copie cada campo desde '
              'una columna con el mismo nombre; esta fuente necesita normalización.',
        );
      }
      return (source('pmtiles.input: source'), null);
    case PmtilesInput.normalized:
      return (normalized('pmtiles.input: normalized'), null);
    case PmtilesInput.auto:
      if (direct && d.gis.format == GisFormat.shapefile) {
        return (
          source(
            'auto: shapefile con mapeo directo; Docker recibe la fuente original',
          ),
          null,
        );
      }
      return (
        normalized(
          direct
              ? 'auto: la fuente no es shapefile; Docker recibe el GIS normalizado'
              : 'auto: el mapeo no es directo; Docker recibe el GIS normalizado',
        ),
        null,
      );
  }
}

/// Bounding box stored in a shapefile header.
Extent? shapefileExtent(File shp) {
  if (!shp.existsSync()) return null;
  final raf = shp.openSync();
  try {
    final header = raf.readSync(100);
    if (header.length < 100) return null;
    final data = ByteData.sublistView(header);
    return Extent(
      data.getFloat64(36, Endian.little),
      data.getFloat64(44, Endian.little),
      data.getFloat64(52, Endian.little),
      data.getFloat64(60, Endian.little),
    );
  } finally {
    raf.closeSync();
  }
}

class MapInputStats {
  const MapInputStats({
    required this.features,
    required this.emptiedValues,
    required this.extent,
  });

  final int features;

  /// Field -> text values turned into null.
  final Map<String, int> emptiedValues;
  final Extent? extent;
}

final _number = RegExp(r'-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?');

/// Writes the Docker input from the normalized GIS: same features, same
/// geometry text, with empty (or blank) text values replaced by null —
/// what the shapefile route does implicitly, so empty attributes are
/// omitted from the tiles (design D3). The normalized file is not touched.
Future<MapInputStats> writeMapInput(File normalized, File output) async {
  output.parent.createSync(recursive: true);
  final temp = File('${output.path}.tmp');
  final sink = temp.openWrite();
  final emptied = <String, int>{};
  var features = 0;
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  try {
    sink.write(
      '{"type":"FeatureCollection","name":"map_input",'
      '"crs":{"type":"name","properties":{"name":"urn:ogc:def:crs:OGC:1.3:CRS84"}},"features":[\n',
    );
    await for (final feature in readGeoJsonLines(
      normalized,
      withGeometry: true,
    )) {
      final properties = <String, Object?>{};
      feature.properties.forEach((key, value) {
        if (value is String && value.trim().isEmpty) {
          emptied[key] = (emptied[key] ?? 0) + 1;
          properties[key] = null;
        } else {
          properties[key] = value;
        }
      });
      final geometry = feature.rawGeometry;
      if (geometry != null) {
        final coordinatesAt = geometry.indexOf('"coordinates"');
        final numbers = _number
            .allMatches(
              coordinatesAt < 0 ? geometry : geometry.substring(coordinatesAt),
            )
            .toList();
        for (var i = 0; i + 1 < numbers.length; i += 2) {
          final x = double.parse(numbers[i].group(0)!);
          final y = double.parse(numbers[i + 1].group(0)!);
          minX = math.min(minX, x);
          maxX = math.max(maxX, x);
          minY = math.min(minY, y);
          maxY = math.max(maxY, y);
        }
      }
      if (features > 0) sink.write(',\n');
      sink
        ..write('{"type":"Feature","properties":')
        ..write(jsonEncode(properties))
        ..write(',"geometry":')
        ..write(geometry ?? 'null')
        ..write('}');
      features++;
    }
    sink.write('\n]}\n');
  } finally {
    await sink.close();
  }
  if (output.existsSync()) output.deleteSync();
  temp.renameSync(output.path);
  return MapInputStats(
    features: features,
    emptiedValues: emptied,
    extent: minX.isFinite ? Extent(minX, minY, maxX, maxY) : null,
  );
}
