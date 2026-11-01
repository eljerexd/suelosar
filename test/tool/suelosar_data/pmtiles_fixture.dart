import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pmtiles/pmtiles.dart' show ZXY;
import 'package:vector_tile/raw/raw_vector_tile.dart' as raw;

int _zigzag(int n) => (n << 1) ^ (n >> 31);

/// A closed square, as MVT geometry commands.
List<int> _square() => [
  (1 << 3) | 1, _zigzag(0), _zigzag(0), //
  (3 << 3) | 2, _zigzag(100), 0, 0, _zigzag(100), _zigzag(-100), 0,
  (1 << 3) | 7,
];

void _varint(BytesBuilder out, int value) {
  var v = value;
  while (true) {
    if (v & ~0x7F == 0) {
      out.addByte(v);
      return;
    }
    out.addByte((v & 0x7F) | 0x80);
    v >>= 7;
  }
}

Uint8List _mvt(String layer, List<Map<String, Object?>> features) {
  final keys = <String>[];
  final values = <raw.VectorTile_Value>[];
  final valueIndex = <String, int>{};
  final built = <raw.VectorTile_Feature>[];
  for (final properties in features) {
    final tags = <int>[];
    properties.forEach((key, value) {
      if (value == null) return;
      var k = keys.indexOf(key);
      if (k < 0) {
        k = keys.length;
        keys.add(key);
      }
      final token = '${value.runtimeType}:$value';
      final v = valueIndex.putIfAbsent(token, () {
        values.add(
          value is num
              ? raw.VectorTile_Value(doubleValue: value.toDouble())
              : raw.VectorTile_Value(stringValue: '$value'),
        );
        return values.length - 1;
      });
      tags
        ..add(k)
        ..add(v);
    });
    built.add(
      raw.VectorTile_Feature(
        tags: tags,
        type: raw.VectorTile_GeomType.POLYGON,
        geometry: _square(),
      ),
    );
  }
  return raw.VectorTile(
    layers: [
      raw.VectorTile_Layer(
        name: layer,
        extent: 4096,
        version: 2,
        keys: keys,
        values: values,
        features: built,
      ),
    ],
  ).writeToBuffer();
}

/// Writes a small, valid PMTiles v3 archive (clustered, gzip, MVT) with one
/// layer. [tiles] maps `(z, x, y)` to the properties of its features.
File writePmtiles(
  File file, {
  required Map<(int, int, int), List<Map<String, Object?>>> tiles,
  String layer = 'soil_polygons',
  (double, double, double, double) bounds = (-61, -36, -59, -34),
  (double, double, int) center = (-60, -35, 10),
  Map<String, Object?> metadata = const {'name': 'fixture'},
  int tileCompression = 2,
}) {
  final gzip = GZipCodec();
  final entries = [
    for (final entry in tiles.entries)
      (
        ZXY(entry.key.$1, entry.key.$2, entry.key.$3).toTileId(),
        entry.key.$1,
        gzip.encode(_mvt(layer, entry.value)),
      ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));

  final tileData = BytesBuilder();
  final offsets = <int>[];
  for (final (_, _, bytes) in entries) {
    offsets.add(tileData.length);
    tileData.add(bytes);
  }
  final directory = BytesBuilder();
  _varint(directory, entries.length);
  var last = 0;
  for (final (id, _, _) in entries) {
    _varint(directory, id - last);
    last = id;
  }
  for (final _ in entries) {
    _varint(directory, 1);
  }
  for (final (_, _, bytes) in entries) {
    _varint(directory, bytes.length);
  }
  for (final offset in offsets) {
    _varint(directory, offset + 1);
  }
  final root = gzip.encode(directory.toBytes());
  final meta = gzip.encode(utf8.encode(jsonEncode(metadata)));
  final zooms = [for (final (_, z, _) in entries) z];

  const rootOffset = 127;
  final metadataOffset = rootOffset + root.length;
  final tileOffset = metadataOffset + meta.length;
  final header = ByteData(127);
  final magic = ascii.encode('PMTiles');
  for (var i = 0; i < magic.length; i++) {
    header.setUint8(i, magic[i]);
  }
  int e7(double degrees) => (degrees * 10000000).round();
  header
    ..setUint8(7, 3)
    ..setUint64(0x08, rootOffset, Endian.little)
    ..setUint64(0x10, root.length, Endian.little)
    ..setUint64(0x18, metadataOffset, Endian.little)
    ..setUint64(0x20, meta.length, Endian.little)
    ..setUint64(0x28, tileOffset, Endian.little)
    ..setUint64(0x30, 0, Endian.little)
    ..setUint64(0x38, tileOffset, Endian.little)
    ..setUint64(0x40, tileData.length, Endian.little)
    ..setUint64(0x48, entries.length, Endian.little)
    ..setUint64(0x50, entries.length, Endian.little)
    ..setUint64(0x58, entries.length, Endian.little)
    ..setUint8(0x60, 1)
    ..setUint8(0x61, 2)
    ..setUint8(0x62, tileCompression)
    ..setUint8(0x63, 1)
    ..setUint8(0x64, zooms.reduce((a, b) => a < b ? a : b))
    ..setUint8(0x65, zooms.reduce((a, b) => a > b ? a : b))
    ..setInt32(0x66, e7(bounds.$1), Endian.little)
    ..setInt32(0x6A, e7(bounds.$2), Endian.little)
    ..setInt32(0x6E, e7(bounds.$3), Endian.little)
    ..setInt32(0x72, e7(bounds.$4), Endian.little)
    ..setUint8(0x76, center.$3)
    ..setInt32(0x77, e7(center.$1), Endian.little)
    ..setInt32(0x7B, e7(center.$2), Endian.little);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync([
    ...header.buffer.asUint8List(),
    ...root,
    ...meta,
    ...tileData.toBytes(),
  ]);
  return file;
}

/// Tile coordinates covering (-60, -35) at [z].
(int, int, int) tileAt(int z) {
  final zxy = _tileAt(z, -35, -60);
  return (z, zxy.$1, zxy.$2);
}

(int, int) _tileAt(int z, double lat, double lon) {
  final n = 1 << z;
  final x = ((lon + 180) / 360 * n).floor();
  final r = lat * math.pi / 180;
  final y = ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n).floor();
  return (x, y);
}
