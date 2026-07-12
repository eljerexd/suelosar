import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'measurement_export_models.dart';
import 'measurement_geojson_exporter.dart' show measurementExportFileStem;

class MeasurementCsvExporter {
  const MeasurementCsvExporter();

  Future<File> export(MeasurementExportData data) async {
    final directory = await getTemporaryDirectory();
    final output = File(
      '${directory.path}${Platform.pathSeparator}'
      '${measurementExportFileStem(data)}.csv',
    );
    await output.writeAsString(encode(data), encoding: utf8, flush: true);
    return output;
  }

  String encode(MeasurementExportData data) {
    final row = <String>[
      data.title ?? '',
      data.isArea ? 'Área' : 'Distancia',
      data.areaSquareMeters == null
          ? ''
          : (data.areaSquareMeters! / 10000).toStringAsFixed(4),
      data.perimeterMeters?.toStringAsFixed(2) ?? '',
      '${data.coordinates.length}',
      data.createdAt.toIso8601String(),
      data.coordinates
          .map(
            (coordinate) =>
                '${coordinate.latitude.toStringAsFixed(6)}, ${coordinate.longitude.toStringAsFixed(6)}',
          )
          .join(' | '),
    ];
    return '${<String>['Name', 'Type', 'Area (ha)', 'Perimeter (m)', 'Vertex count', 'Created date', 'Coordinates'].map(_escape).join(',')}\n${row.map(_escape).join(',')}\n';
  }

  String _escape(String value) => '"${value.replaceAll('"', '""')}"';
}
