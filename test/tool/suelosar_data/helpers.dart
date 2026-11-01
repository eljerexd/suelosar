import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final repoRoot = Directory.current.path;

/// A temporary directory removed after the test.
Directory tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync('suelosar_data_$prefix');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// `(name, type, length, decimals)` DBF field spec.
typedef FieldSpec = (String, String, int, int);

/// Builds a dBASE III table. Values are written left-aligned (text) or
/// right-aligned (numbers); a record whose first value is `#deleted` is
/// flagged as deleted. Text is encoded with [encoding].
Uint8List buildDbf(
  List<FieldSpec> fields,
  List<List<Object?>> records, {
  Encoding encoding = utf8,
}) {
  final recordLength = 1 + fields.fold<int>(0, (sum, f) => sum + f.$3);
  final headerLength = 32 + fields.length * 32 + 1;
  final out = BytesBuilder();
  final header = ByteData(32)
    ..setUint8(0, 3)
    ..setUint32(4, records.length, Endian.little)
    ..setUint16(8, headerLength, Endian.little)
    ..setUint16(10, recordLength, Endian.little);
  out.add(header.buffer.asUint8List());
  for (final (name, type, length, decimals) in fields) {
    final descriptor = Uint8List(32);
    descriptor.setAll(0, ascii.encode(name));
    descriptor[11] = type.codeUnitAt(0);
    descriptor[16] = length;
    descriptor[17] = decimals;
    out.add(descriptor);
  }
  out.addByte(0x0D);
  for (final record in records) {
    final deleted = record.isNotEmpty && record.first == '#deleted';
    final values = deleted ? record.sublist(1) : record;
    out.addByte(deleted ? 0x2A : 0x20);
    for (var i = 0; i < fields.length; i++) {
      final (_, type, length, _) = fields[i];
      final value = values[i];
      final bytes = value is Uint8List
          ? value
          : Uint8List.fromList(encoding.encode(value?.toString() ?? ''));
      final cell = Uint8List(length)..fillRange(0, length, 0x20);
      if (type == 'N') {
        cell.setAll(length - bytes.length, bytes);
      } else {
        cell.setAll(0, bytes.take(length));
      }
      out.add(cell);
    }
  }
  out.addByte(0x1A);
  return out.toBytes();
}

/// Builds a polygon `.shp` whose records are lists of rings (or null for a
/// null shape).
Uint8List buildShp(List<List<List<List<double>>>?> records) {
  final body = BytesBuilder();
  var number = 1;
  for (final rings in records) {
    final content = BytesBuilder();
    if (rings == null) {
      content.add(
        (ByteData(4)..setInt32(0, 0, Endian.little)).buffer.asUint8List(),
      );
    } else {
      final points = [for (final ring in rings) ...ring];
      final head = ByteData(44)
        ..setInt32(0, 5, Endian.little)
        ..setInt32(36, rings.length, Endian.little)
        ..setInt32(40, points.length, Endian.little);
      content.add(head.buffer.asUint8List());
      var offset = 0;
      for (final ring in rings) {
        content.add(
          (ByteData(
            4,
          )..setInt32(0, offset, Endian.little)).buffer.asUint8List(),
        );
        offset += ring.length;
      }
      for (final point in points) {
        content.add(
          (ByteData(16)
                ..setFloat64(0, point[0], Endian.little)
                ..setFloat64(8, point[1], Endian.little))
              .buffer
              .asUint8List(),
        );
      }
    }
    final bytes = content.toBytes();
    body.add(
      (ByteData(8)
            ..setInt32(0, number++, Endian.big)
            ..setInt32(4, bytes.length ~/ 2, Endian.big))
          .buffer
          .asUint8List(),
    );
    body.add(bytes);
  }
  final bodyBytes = body.toBytes();
  final header = ByteData(100)
    ..setInt32(0, 9994, Endian.big)
    ..setInt32(24, (100 + bodyBytes.length) ~/ 2, Endian.big)
    ..setInt32(28, 1000, Endian.little)
    ..setInt32(32, 5, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...bodyBytes]);
}

const wgs84Prj =
    'GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],'
    'PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]]';

/// Clockwise square (a shapefile outer ring).
List<List<double>> square(double x, double y, double size) => [
  [x, y],
  [x, y + size],
  [x + size, y + size],
  [x + size, y],
  [x, y],
];

/// Counter-clockwise square (a shapefile hole).
List<List<double>> hole(double x, double y, double size) =>
    square(x, y, size).reversed.toList();

/// Writes a GeoJSON FeatureCollection with one feature per line.
File writeGeoJsonLines(
  Directory dir,
  String name,
  List<Map<String, Object?>> properties,
) {
  final file = File(p.join(dir.path, name));
  final lines = [
    for (var i = 0; i < properties.length; i++)
      '{"type":"Feature","properties":${jsonEncode(properties[i])},'
          '"geometry":{"type":"Polygon","coordinates":[[[-60.0,-35.5],[-60.0,-35.0],[-59.5,-35.0],[-60.0,-35.5]]]}}',
  ];
  file.writeAsStringSync(
    '{"type":"FeatureCollection","name":"t","features":[\n${lines.join(',\n')}\n]}\n',
  );
  return file;
}

/// A complete province.yaml mapping every schema field from same-named
/// columns, for synthetic provinces.
String identityMapping({String indent = '    '}) => [
  for (final f in ['SIMBC', 'Nombre_UC', 'TIPO', 'CAP_USO', 'PAISAJE'])
    '$indent$f: { from: $f }',
  '$indent"SERIE{n}": { from: "SERIE{n}", n: [1, 6] }',
  '$indent"PORC{n}": { from: "PORC{n}", n: [1, 6] }',
].join('\n');

/// Properties with every schema column set.
Map<String, Object?> fullProperties({
  String simbc = 'U1',
  String? nombre = 'Unidad',
  String? tipo = 'Asociacion',
  String? cap = 'IIw',
  String? paisaje = 'Lomas',
  List<String?> series = const ['Serie A'],
  List<num?> porc = const [100],
}) => {
  'SIMBC': simbc,
  'Nombre_UC': nombre,
  'TIPO': tipo,
  'CAP_USO': cap,
  'PAISAJE': paisaje,
  for (var i = 1; i <= 6; i++)
    'SERIE$i': i <= series.length ? series[i - 1] : null,
  for (var i = 1; i <= 6; i++) 'PORC$i': i <= porc.length ? porc[i - 1] : 0,
};

/// Creates `<root>/<id>/province.yaml` with [yaml] and returns the root.
Directory writeProvince(Directory root, String id, String yaml) {
  final dir = Directory(p.join(root.path, id))..createSync(recursive: true);
  File(p.join(dir.path, 'province.yaml')).writeAsStringSync(yaml);
  return root;
}
