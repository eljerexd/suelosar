import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/gis_location_service.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_render_metrics.dart';
import 'package:suelosar/gis/gis_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profiles GPS and temporary GIS tool overlays', (tester) async {
    final metrics = GisRenderMetrics();
    final repository = PmTilesGisRepository.fromAsset(
      assetPath: AssetPaths.gisPmTiles,
      versionAssetPath: AssetPaths.gisPmTilesVersion,
      layerName: AssetPaths.gisLayerName,
    );
    addTearDown(metrics.dispose);
    addTearDown(repository.close);

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: repository,
          renderMetrics: metrics,
          locationService: const _ProfileLocationService(),
        ),
      ),
    );
    await _waitForTiles(tester, metrics);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.move(const LatLng(-35.85, -60.55), 9);
    await tester.pump();
    await _waitForTiles(tester, metrics);

    final baseline = await _measurePan(tester, metrics);

    await tester.tap(find.text('Mi ubicación').first);
    await tester.pump(const Duration(milliseconds: 220));
    final gps = await _measurePan(tester, metrics);

    await _tapDesktopAction(
      tester,
      const ValueKey('desktop-map-action-measure-distance'),
    );
    await tester.pump();
    await _tapMapPoints(tester, const <LatLng>[
      LatLng(-35.851, -60.552),
      LatLng(-35.849, -60.548),
      LatLng(-35.847, -60.545),
    ]);
    final distance = await _measurePan(tester, metrics);
    await _cancelMode(tester);

    await _tapDesktopAction(
      tester,
      const ValueKey('desktop-map-action-measure-area'),
    );
    await tester.pump();
    await _tapMapPoints(tester, const <LatLng>[
      LatLng(-35.852, -60.553),
      LatLng(-35.848, -60.553),
      LatLng(-35.848, -60.547),
      LatLng(-35.852, -60.547),
    ]);
    final area = await _measurePan(tester, metrics);
    await _cancelMode(tester);

    await _tapDesktopAction(
      tester,
      const ValueKey('desktop-map-action-add-marker'),
    );
    await tester.pump();
    final marker = await _measurePan(tester, metrics);
    await _cancelMode(tester);

    final report = <String, Object?>{
      'device': 'windows',
      'baseline': baseline,
      'gps_marker_visible': gps,
      'distance_measurement_and_label': distance,
      'area_measurement_and_label': area,
      'marker_mode': marker,
    };
    binding.reportData = report;
    debugPrint('GIS_TOOL_MODES_PROFILE ${jsonEncode(report)}');

    expect(tester.takeException(), isNull);
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

  final mapRect = tester.getRect(find.byType(FlutterMap));
  final start = Offset(mapRect.left + mapRect.width * 0.72, mapRect.top + 180);
  for (final delta in const <Offset>[Offset(-4, 0), Offset(4, 0)]) {
    final gesture = await tester.startGesture(start);
    for (var frame = 0; frame < 25; frame++) {
      await gesture.moveBy(delta);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 190));
  }

  wall.stop();
  SchedulerBinding.instance.removeTimingsCallback(collect);
  final snapshot = metrics.snapshot();
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
    'wall_us': wall.elapsedMicroseconds,
    'frames': timings.length,
    'average_frame_us': _average(total),
    'p95_frame_us': _percentile(total, 0.95),
    'worst_frame_us': total.isEmpty ? 0 : total.reduce(math.max),
    'average_ui_us': _average(ui),
    'average_raster_us': _average(raster),
    'frames_over_16_7_ms': total.where((value) => value > 16667).length,
    'map_builds': snapshot.mapBuildCount,
    'polygon_layer_builds': snapshot.polygonLayerBuildCount,
    'polygon_repaint_regions': snapshot.paintCount,
    'submitted_polygons': snapshot.submittedPolygonCount,
    'submitted_vertices': snapshot.submittedVertexCount,
  };
}

Future<void> _tapMapPoints(WidgetTester tester, List<LatLng> points) async {
  for (final point in points) {
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), point);
    await tester.pump();
  }
}

Future<void> _tapDesktopAction(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _cancelMode(WidgetTester tester) async {
  final closePanel = find.byTooltip('Cerrar panel');
  expect(closePanel, findsOneWidget);
  await tester.tap(closePanel);
  await tester.pump();
  final discard = find.text('Descartar');
  if (discard.evaluate().isNotEmpty) {
    await tester.tap(discard.last);
    await tester.pumpAndSettle();
  }
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

class _ProfileLocationService
    implements GisLocationService, GisLocationUpdates {
  const _ProfileLocationService();

  @override
  Future<GisLocation> getCurrentLocation() async =>
      const GisLocation(point: LatLng(-35.85, -60.55), accuracyMeters: 8);

  @override
  Stream<GisLocation> watchLocation() => const Stream<GisLocation>.empty();
}
