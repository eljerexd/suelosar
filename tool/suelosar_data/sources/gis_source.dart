import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/province_definition.dart';
import 'dbf_reader.dart';
import 'geojson_reader.dart';
import 'shapefile_reader.dart';

/// One source feature: attribute values and, when requested, its geometry
/// as GeoJSON text.
class GisRecord {
  const GisRecord(this.index, this.properties, this.geometryJson);

  final int index;
  final Map<String, Object?> properties;
  final String? geometryJson;
}

/// A text value that is not valid in the source's encoding, or already
/// contains U+FFFD (a replacement character left by an earlier bad
/// conversion).
class EncodingIssue {
  const EncodingIssue(
    this.record,
    this.field, {
    this.value,
    this.suspected = false,
  });

  final int record;
  final String field;

  /// The offending text, for suspected double encodings.
  final String? value;

  /// True for text that decodes fine but looks double-encoded
  /// (`CaÃ±ada` for `Cañada`); false for undecodable bytes.
  final bool suspected;
}

/// UTF-8 bytes read back as Latin-1/Windows-1252: `Ã` or `Â` followed by
/// a character from the U+0080-U+00BF range.
final _doubleEncoded = RegExp(r'[\u00C2\u00C3][\u0080-\u00BF]');

/// Uniform access to a province's GIS source, whatever its format.
class GisSource {
  GisSource._(this.config, this.file);

  factory GisSource.open(GisConfig config) =>
      GisSource._(config, File(config.source));

  final GisConfig config;
  final File file;

  /// Sidecar files of a shapefile: `(extension, required)`.
  static const shapefileSidecars = [
    ('.dbf', true),
    ('.shx', true),
    ('.prj', true),
    ('.cpg', false),
  ];

  bool get exists => file.existsSync();

  /// Missing sidecars, `(file, required)`. Empty for GeoJSON.
  List<(String, bool)> missingSidecars() {
    if (config.format != GisFormat.shapefile) return const [];
    final base = file.path.substring(
      0,
      file.path.length - p.extension(file.path).length,
    );
    return [
      for (final (extension, required) in shapefileSidecars)
        if (!File('$base$extension').existsSync() &&
            !File('$base${extension.toUpperCase()}').existsSync())
          ('${p.basename(base)}$extension', required),
    ];
  }

  File get _dbfFile {
    final base = file.path.substring(
      0,
      file.path.length - p.extension(file.path).length,
    );
    final lower = File('$base.dbf');
    return lower.existsSync() ? lower : File('$base.DBF');
  }

  /// Columns declared by the source schema (the DBF header). Null for
  /// GeoJSON, whose columns are only known after reading every feature.
  List<String>? declaredColumns() {
    if (config.format != GisFormat.shapefile) return null;
    return [
      for (final field in DbfTable.open(
        _dbfFile,
        encoding: config.encoding,
      ).fields)
        field.name,
    ];
  }

  /// Column types, when the source declares them.
  Map<String, String>? declaredColumnTypes() {
    if (config.format != GisFormat.shapefile) return null;
    return {
      for (final field in DbfTable.open(
        _dbfFile,
        encoding: config.encoding,
      ).fields)
        field.name: field.description,
    };
  }

  String _encodingName = '';

  /// Encoding actually used by the last [records] call.
  String get encodingName => _encodingName;

  final List<EncodingIssue> encodingIssues = [];

  /// Streams every feature. Text values containing U+FFFD are reported in
  /// [encodingIssues] once the stream is done.
  Stream<GisRecord> records({bool withGeometry = false}) async* {
    encodingIssues.clear();
    switch (config.format) {
      case GisFormat.shapefile:
        if (withGeometry) ShapefilePolygonReader.ensureGeographicWgs84(file);
        final table = DbfTable.open(_dbfFile, encoding: config.encoding);
        _encodingName = table.encodingName;
        final geometries = withGeometry
            ? ShapefilePolygonReader(file).geometries().iterator
            : null;
        for (final (index, values) in table.records()) {
          String? geometry;
          if (geometries != null) {
            // Deleted DBF records still have a .shp record: advance to the
            // record with the same index.
            while (geometries.moveNext()) {
              final (shapeIndex, shape) = geometries.current;
              if (shapeIndex == index) {
                geometry = shape == null ? null : jsonEncode(shape);
                break;
              }
            }
          }
          // Undecodable bytes were replaced by U+FFFD, so this also
          // catches every entry of table.encodingIssues.
          _scanText(index, values);
          yield GisRecord(index, values, geometry);
        }
      case GisFormat.geojsonLines:
      case GisFormat.geojson:
        _encodingName = config.encoding ?? 'UTF-8';
        if (_encodingName.toUpperCase().replaceAll('-', '') != 'UTF8') {
          throw FormatException(
            'GeoJSON debe ser UTF-8 (declarado: $_encodingName).',
          );
        }
        final features = config.format == GisFormat.geojsonLines
            ? readGeoJsonLines(file, withGeometry: withGeometry)
            : readGeoJsonDocument(file, withGeometry: withGeometry);
        await for (final feature in features) {
          _scanText(feature.index, feature.properties);
          yield GisRecord(
            feature.index,
            feature.properties,
            feature.rawGeometry,
          );
        }
    }
  }

  void _scanText(int index, Map<String, Object?> values) {
    values.forEach((field, value) {
      if (value is! String) return;
      if (value.contains('\uFFFD')) {
        encodingIssues.add(EncodingIssue(index, field));
      } else if (_doubleEncoded.hasMatch(value)) {
        encodingIssues.add(
          EncodingIssue(index, field, value: value, suspected: true),
        );
      }
    });
  }
}
