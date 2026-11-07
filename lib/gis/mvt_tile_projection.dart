import 'dart:math' as math;

/// Converts integer coordinates from one MVT tile into geographic coordinates.
///
/// Tile-wide constants are prepared once, avoiding repeated shifts and
/// divisions for every vertex in that tile.
class MvtTileProjection {
  factory MvtTileProjection({
    required int zoom,
    required int tileX,
    required int tileY,
    required int extent,
  }) {
    if (zoom < 0 || zoom > 30) {
      throw RangeError.range(zoom, 0, 30, 'zoom');
    }
    if (extent <= 0) {
      throw ArgumentError.value(extent, 'extent', 'Must be positive.');
    }

    final tilesAtZoom = 1 << zoom;
    final longitudePerTile = 360.0 / tilesAtZoom;
    final mercatorYPerTile = 2 * math.pi / tilesAtZoom;
    return MvtTileProjection._(
      longitudeOrigin: tileX * longitudePerTile - 180,
      longitudeStep: longitudePerTile / extent,
      mercatorYOrigin: math.pi * (1 - (2 * tileY / tilesAtZoom)),
      mercatorYStep: -mercatorYPerTile / extent,
    );
  }

  const MvtTileProjection._({
    required this.longitudeOrigin,
    required this.longitudeStep,
    required this.mercatorYOrigin,
    required this.mercatorYStep,
  });

  final double longitudeOrigin;
  final double longitudeStep;
  final double mercatorYOrigin;
  final double mercatorYStep;

  List<double> projectPoint(List<int> point) {
    final longitude = longitudeOrigin + point[0] * longitudeStep;
    final mercatorY = mercatorYOrigin + point[1] * mercatorYStep;
    final hyperbolicSine = (math.exp(mercatorY) - math.exp(-mercatorY)) / 2;
    final latitude = math.atan(hyperbolicSine) * 180 / math.pi;
    return <double>[longitude, latitude];
  }
}
