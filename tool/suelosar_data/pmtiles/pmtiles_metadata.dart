import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:pmtiles/pmtiles.dart';
import 'package:vector_tile/raw/raw_vector_tile.dart' as raw;

class GeoBoundsValue {
  const GeoBoundsValue({
    required this.minLatitude,
    required this.maxLatitude,
    required this.minLongitude,
    required this.maxLongitude,
  });

  final double minLatitude;
  final double maxLatitude;
  final double minLongitude;
  final double maxLongitude;

  Map<String, Object?> toJson() => {
    'minLatitude': minLatitude,
    'maxLatitude': maxLatitude,
    'minLongitude': minLongitude,
    'maxLongitude': maxLongitude,
  };
}

/// Everything the app needs to know about a PMTiles archive, read from the
/// file itself.
class PmtilesMetadata {
  const PmtilesMetadata({
    required this.file,
    required this.sizeBytes,
    required this.sha256,
    required this.sidecarSha256,
    required this.version,
    required this.tileType,
    required this.minZoom,
    required this.maxZoom,
    required this.bounds,
    required this.centerLatitude,
    required this.centerLongitude,
    required this.centerZoom,
    required this.layers,
    required this.attributesSeen,
    required this.sampledTiles,
  });

  final String file;
  final int sizeBytes;
  final String sha256;

  /// Content of `<file>.sha256`, or null when there is no sidecar.
  final String? sidecarSha256;
  final int version;
  final String tileType;
  final int minZoom;
  final int maxZoom;
  final GeoBoundsValue bounds;
  final double centerLatitude;
  final double centerLongitude;
  final int centerZoom;

  /// Vector layer names found in the sampled tiles.
  final List<String> layers;

  /// Attribute keys found in the sampled tiles of the requested layer.
  final List<String> attributesSeen;
  final int sampledTiles;

  double get sizeMiB => sizeBytes / (1024 * 1024);

  bool? get sidecarMatches =>
      sidecarSha256 == null ? null : sidecarSha256 == sha256;

  Map<String, Object?> toJson() => {
    'file': file,
    'sizeBytes': sizeBytes,
    'sizeMiB': double.parse(sizeMiB.toStringAsFixed(2)),
    'sha256': sha256,
    'sha256Sidecar': sidecarSha256,
    'sha256SidecarMatches': sidecarMatches,
    'pmtilesVersion': version,
    'tileType': tileType,
    'minZoom': minZoom,
    'maxZoom': maxZoom,
    'bounds': bounds.toJson(),
    'center': {
      'latitude': centerLatitude,
      'longitude': centerLongitude,
      'zoom': centerZoom,
    },
    'layers': layers,
    'attributesSeen': attributesSeen,
    'sampledTiles': sampledTiles,
  };

  /// Reads [file]. Attribute keys are sampled from the tiles covering the
  /// archive center at every zoom plus a grid over the bounds at the
  /// deepest zooms, for [layer].
  static Future<PmtilesMetadata> read(
    File file, {
    String layer = 'soil_polygons',
  }) async {
    final digest = await crypto.sha256.bind(file.openRead()).first;
    final sidecarFile = File('${file.path}.sha256');
    String? sidecar;
    if (sidecarFile.existsSync()) {
      final text = sidecarFile.readAsStringSync().trim();
      sidecar = text.isEmpty
          ? ''
          : text.split(RegExp(r'\s+')).first.toLowerCase();
    }
    final archive = await PmTilesArchive.fromFile(file);
    try {
      final header = archive.header;
      final min = header.minPosition;
      final max = header.maxPosition;
      final center = header.centerPosition;
      final layers = <String>{};
      final attributes = <String>{};
      var sampled = 0;
      for (final zxy in _sampleTiles(
        header.minZoom,
        header.maxZoom,
        min,
        max,
        center,
      )) {
        final tile = await archive.tile(zxy.toTileId());
        final List<int> bytes;
        try {
          bytes = tile.bytes();
        } on Exception {
          continue; // No tile at this position.
        }
        sampled++;
        final decoded = raw.VectorTile.fromBuffer(bytes);
        for (final vectorLayer in decoded.layers) {
          layers.add(vectorLayer.name);
          if (vectorLayer.name == layer) attributes.addAll(vectorLayer.keys);
        }
      }
      return PmtilesMetadata(
        file: file.path,
        sizeBytes: file.lengthSync(),
        sha256: digest.toString(),
        sidecarSha256: sidecar,
        version: header.version,
        tileType: header.tileType.name,
        minZoom: header.minZoom,
        maxZoom: header.maxZoom,
        bounds: GeoBoundsValue(
          minLatitude: min.latitude,
          maxLatitude: max.latitude,
          minLongitude: min.longitude,
          maxLongitude: max.longitude,
        ),
        centerLatitude: center.latitude,
        centerLongitude: center.longitude,
        centerZoom: header.centerZoom,
        layers: layers.toList()..sort(),
        attributesSeen: attributes.toList()..sort(),
        sampledTiles: sampled,
      );
    } finally {
      await archive.close();
    }
  }

  static Iterable<ZXY> _sampleTiles(
    int minZoom,
    int maxZoom,
    LatLng min,
    LatLng max,
    LatLng center,
  ) sync* {
    final seen = <int>{};
    Iterable<ZXY> once(ZXY zxy) sync* {
      if (seen.add(zxy.toTileId())) yield zxy;
    }

    for (var z = minZoom; z <= maxZoom; z++) {
      yield* once(_tileAt(z, center.latitude, center.longitude));
    }
    // A 5x5 grid over the bounds at the three deepest zooms: the detail
    // levels are where attributes matter and where a sparse sample of the
    // center alone could miss rare fields.
    for (var z = math.max(minZoom, maxZoom - 2); z <= maxZoom; z++) {
      for (var i = 0; i < 5; i++) {
        for (var j = 0; j < 5; j++) {
          final lat =
              min.latitude + (max.latitude - min.latitude) * (i + 0.5) / 5;
          final lon =
              min.longitude + (max.longitude - min.longitude) * (j + 0.5) / 5;
          yield* once(_tileAt(z, lat, lon));
        }
      }
    }
  }

  static ZXY _tileAt(int z, double latitude, double longitude) {
    final scale = 1 << z;
    final x = ((longitude + 180) / 360 * scale).floor().clamp(0, scale - 1);
    final lat = latitude.clamp(-85.05112878, 85.05112878) * math.pi / 180;
    final y =
        ((1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) /
                2 *
                scale)
            .floor()
            .clamp(0, scale - 1);
    return ZXY(z, x, y);
  }
}
