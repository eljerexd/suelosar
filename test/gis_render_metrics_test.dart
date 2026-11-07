import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/gis_render_metrics.dart';

void main() {
  group('GisRenderMetrics tile cache state', () {
    test('exposes the latest counts through its public snapshot', () {
      final metrics = GisRenderMetrics();
      addTearDown(metrics.dispose);

      metrics.recordTileCacheState(
        visibleTileCount: 4,
        prefetchedTileCount: 12,
        renderedTileCacheSize: 18,
      );

      final snapshot = metrics.snapshot();
      expect(snapshot.visibleTileCount, 4);
      expect(snapshot.prefetchedTileCount, 12);
      expect(snapshot.renderedTileCacheSize, 18);
    });

    test('disabled metrics remain zero-cost and retain zero counts', () {
      final metrics = GisRenderMetrics.disabled();
      addTearDown(metrics.dispose);

      metrics.recordTileCacheState(
        visibleTileCount: 4,
        prefetchedTileCount: 12,
        renderedTileCacheSize: 18,
      );

      final snapshot = metrics.snapshot();
      expect(snapshot.visibleTileCount, 0);
      expect(snapshot.prefetchedTileCount, 0);
      expect(snapshot.renderedTileCacheSize, 0);
    });
  });
}
