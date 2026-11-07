import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/mvt_tile_projection.dart';

void main() {
  group('MvtTileProjection', () {
    test('matches the previous inverse-Mercator transform on tile samples', () {
      const cases = <({int z, int x, int y, int extent})>[
        (z: 0, x: 0, y: 0, extent: 4096),
        (z: 7, x: 42, y: 55, extent: 4096),
        (z: 9, x: 169, y: 309, extent: 4096),
        (z: 14, x: 8342, y: 12130, extent: 8192),
      ];
      const samples = <List<int>>[
        [0, 0],
        [1, 1],
        [2048, 2048],
        [4095, 3072],
        [4096, 4096],
      ];

      for (final tile in cases) {
        final projection = MvtTileProjection(
          zoom: tile.z,
          tileX: tile.x,
          tileY: tile.y,
          extent: tile.extent,
        );
        for (final point in samples) {
          final actual = projection.projectPoint(point);
          final expected = _legacyProjection(
            point,
            tile.extent,
            tile.z,
            tile.x,
            tile.y,
          );
          expect(actual[0], closeTo(expected[0], 1e-10));
          expect(actual[1], closeTo(expected[1], 1e-10));
          expect(actual.every((value) => value.isFinite), isTrue);
        }
      }
    });

    test('neighboring tile edges project continuously', () {
      const zoom = 9;
      const extent = 4096;
      const tileX = 169;
      const tileY = 309;
      final east = MvtTileProjection(
        zoom: zoom,
        tileX: tileX,
        tileY: tileY,
        extent: extent,
      ).projectPoint(const [extent, extent ~/ 2]);
      final west = MvtTileProjection(
        zoom: zoom,
        tileX: tileX + 1,
        tileY: tileY,
        extent: extent,
      ).projectPoint(const [0, extent ~/ 2]);
      expect(east[0], closeTo(west[0], 1e-10));
      expect(east[1], closeTo(west[1], 1e-10));
    });

    test('rejects invalid zoom and tile extent', () {
      expect(
        () => MvtTileProjection(zoom: -1, tileX: 0, tileY: 0, extent: 4096),
        throwsRangeError,
      );
      expect(
        () => MvtTileProjection(zoom: 1, tileX: 0, tileY: 0, extent: 0),
        throwsArgumentError,
      );
    });
  });
}

List<double> _legacyProjection(
  List<int> point,
  int extent,
  int zoom,
  int tileX,
  int tileY,
) {
  final tilesAtZoom = 1 << zoom;
  final worldX = tileX + point[0] / extent;
  final worldY = tileY + point[1] / extent;
  final longitude = (worldX / tilesAtZoom * 360) - 180;
  final mercatorY = math.pi * (1 - (2 * worldY / tilesAtZoom));
  final hyperbolicSine = (math.exp(mercatorY) - math.exp(-mercatorY)) / 2;
  final latitude = math.atan(hyperbolicSine) * 180 / math.pi;
  return <double>[longitude, latitude];
}
