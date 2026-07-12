import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'measurement_export_models.dart';

class MeasurementGeoJsonExporter {
  const MeasurementGeoJsonExporter();

  Future<File> export(MeasurementExportData data) async {
    final directory = await getTemporaryDirectory();
    final output = File(
      '${directory.path}${Platform.pathSeparator}'
      '${measurementExportFileStem(data)}.geojson',
    );
    await output.writeAsString(encode(data), encoding: utf8, flush: true);
    return output;
  }

  String encode(MeasurementExportData data) {
    final coordinates = data.coordinates
        .map(
          (coordinate) => <double>[coordinate.longitude, coordinate.latitude],
        )
        .toList(growable: false);
    final geometry = data.isArea
        ? <String, Object?>{
            'type': 'Polygon',
            'coordinates': <List<List<double>>>[_closedRing(coordinates)],
          }
        : <String, Object?>{'type': 'LineString', 'coordinates': coordinates};

    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'type': 'Feature',
      'geometry': geometry,
      // RFC 7946 GeoJSON coordinates are WGS84 longitude, latitude pairs.
      'properties': <String, Object?>{
        'id': data.id,
        'name': data.title,
        'type': data.type.name,
        'area_ha': data.areaSquareMeters == null
            ? null
            : data.areaSquareMeters! / 10000,
        'perimeter_m': data.perimeterMeters,
        'created_at': data.createdAt.toIso8601String(),
        'color': data.color,
      },
    });
  }

  List<List<double>> _closedRing(List<List<double>> coordinates) {
    if (coordinates.isEmpty ||
        _samePosition(coordinates.first, coordinates.last)) {
      return coordinates;
    }
    return <List<double>>[...coordinates, coordinates.first];
  }

  bool _samePosition(List<double> first, List<double> last) =>
      first[0] == last[0] && first[1] == last[1];
}

String measurementExportFileStem(MeasurementExportData data) {
  final timestamp = DateTime.now().toIso8601String().replaceAll(
    RegExp(r'[:.]'),
    '-',
  );
  final title = data.title?.trim().isNotEmpty == true
      ? data.title!.trim()
      : 'medicion';
  final safeTitle = title
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return 'suelosar_medicion_${safeTitle}_$timestamp';
}
