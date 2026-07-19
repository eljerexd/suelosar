import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_render_metrics.dart';
import 'package:suelosar/gis/gis_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profiles initial load and isolates GIS layer paint cost', (
    tester,
  ) async {
    final metrics = GisRenderMetrics();
    final repository = PmTilesGisRepository.fromAsset(
      assetPath: AssetPaths.gisPmTiles,
      versionAssetPath: AssetPaths.gisPmTilesVersion,
      layerName: AssetPaths.gisLayerName,
    );
    addTearDown(metrics.dispose);
    addTearDown(repository.close);

    final initialTimings = <FrameTiming>[];
    void collectInitial(List<FrameTiming> batch) =>
        initialTimings.addAll(batch);
    SchedulerBinding.instance.addTimingsCallback(collectInitial);
    final initialLoad = Stopwatch()..start();
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: repository, renderMetrics: metrics),
      ),
    );
    await _waitForTiles(tester, metrics);
    initialLoad.stop();
    SchedulerBinding.instance.removeTimingsCallback(collectInitial);
    final initialCache = repository.cacheMetrics;

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.move(const LatLng(-35.85, -60.55), 9);
    await tester.pump();
    await _waitForTiles(tester, metrics);

    final allLayers = await _measurePan(tester, metrics);

    await _openLayersPanel(tester);
    await _setLayer(tester, 'Referencia', false);
    final polygonsOnly = await _measurePan(tester, metrics);

    await _setLayer(tester, 'Suelos', false);
    await _setLayer(tester, 'Referencia', true);
    final referenceOnly = await _measurePan(tester, metrics);

    map.mapController!.move(const LatLng(-35.85, -60.55), 14);
    await tester.pump(const Duration(milliseconds: 220));
    final labelsOnly = await _measurePan(tester, metrics);

    await _setLayer(tester, 'Referencia', false);
    final noOverlay = await _measurePan(tester, metrics);

    await _setLayer(tester, 'Suelos', true);
    await _setLayer(tester, 'Referencia', true);

    final report = <String, Object?>{
      'device': 'windows',
      'initial_load': {
        'wall_us': initialLoad.elapsedMicroseconds,
        ..._frameSummary(initialTimings),
        'decoded_tiles': initialCache.decodedTileCount,
      },
      'all_layers': allLayers,
      'polygons_only': polygonsOnly,
      'reference_and_labels_only': referenceOnly,
      'labels_only': labelsOnly,
      'no_gis_overlays': noOverlay,
    };
    binding.reportData = report;
    debugPrint('GIS_LAYER_ISOLATION_PROFILE ${jsonEncode(report)}');

    expect(allLayers['frames'], greaterThan(20));
    expect(polygonsOnly['frames'], greaterThan(20));
    expect(referenceOnly['frames'], greaterThan(20));
    expect(noOverlay['frames'], greaterThan(20));
  });
}

Future<Map<String, Object?>> _measurePan(
  WidgetTester tester,
  GisRenderMetrics metrics,
) async {
  metrics.reset();
  final timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  final wall = Stopwatch()..start();

  final center = tester.getCenter(find.byType(FlutterMap));
  for (final delta in const <Offset>[
    Offset(-5, 0),
    Offset(0, -5),
    Offset(5, 0),
    Offset(0, 5),
  ]) {
    final gesture = await tester.startGesture(center);
    for (var frame = 0; frame < 30; frame++) {
      await gesture.moveBy(delta);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 190));
  }

  wall.stop();
  SchedulerBinding.instance.removeTimingsCallback(collect);
  final snapshot = metrics.snapshot();
  return <String, Object?>{
    'wall_us': wall.elapsedMicroseconds,
    ..._frameSummary(timings),
    'map_builds': snapshot.mapBuildCount,
    'polygon_layer_builds': snapshot.polygonLayerBuildCount,
    'polygon_repaint_regions': snapshot.paintCount,
    'submitted_polygons': snapshot.submittedPolygonCount,
    'submitted_vertices': snapshot.submittedVertexCount,
  };
}

Map<String, Object?> _frameSummary(List<FrameTiming> timings) {
  final total = timings
      .map((timing) => timing.totalSpan.inMicroseconds)
      .toList(growable: false);
  final ui = timings
      .map((timing) => timing.buildDuration.inMicroseconds)
      .toList(growable: false);
  final raster = timings
      .map((timing) => timing.rasterDuration.inMicroseconds)
      .toList(growable: false);
  return <String, Object?>{
    'frames': timings.length,
    'average_frame_us': _average(total),
    'p95_frame_us': _percentile(total, 0.95),
    'worst_frame_us': total.isEmpty ? 0 : total.reduce(math.max),
    'average_ui_us': _average(ui),
    'average_raster_us': _average(raster),
    'frames_over_16_7_ms': total.where((value) => value > 16667).length,
  };
}

Future<void> _openLayersPanel(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Capas').first);
  await tester.pump();
  expect(find.widgetWithText(SwitchListTile, 'Suelos'), findsOneWidget);
}

Future<void> _setLayer(WidgetTester tester, String title, bool visible) async {
  final finder = find.widgetWithText(SwitchListTile, title);
  final tile = tester.widget<SwitchListTile>(finder);
  if (tile.value == visible) return;
  tile.onChanged!(visible);
  await tester.pump();
}

Future<void> _waitForTiles(
  WidgetTester tester,
  GisRenderMetrics metrics,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (metrics.polygonLayerBuildCount > 0 &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      return;
    }
  }
  fail('Timed out waiting for GIS tiles.');
}

double _average(List<int> values) {
  if (values.isEmpty) return 0;
  return values.fold<int>(0, (sum, value) => sum + value) / values.length;
}

int _percentile(List<int> values, double percentile) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  return sorted[((sorted.length - 1) * percentile).round()];
}
