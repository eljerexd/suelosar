import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/app/app_routes.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_render_metrics.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/models/saved_measurement.dart';
import 'package:suelosar/screens/home_screen.dart';
import 'package:suelosar/services/connectivity_service.dart';
import 'package:suelosar/services/synchronization_service.dart';
import 'package:suelosar/sync/persistent_sync_queue.dart';
import 'package:suelosar/sync/sync_engine.dart';
import 'package:suelosar/sync/sync_logger.dart';
import 'package:suelosar/sync/sync_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GIS renderer avoids unnecessary rebuilds', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final metrics = GisRenderMetrics();
    addTearDown(metrics.dispose);
    final repository = PmTilesGisRepository.fromFile(
      archiveFile: File('assets/maps/soil_polygons.pmtiles'),
      layerName: AssetPaths.gisLayerName,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: repository, renderMetrics: metrics),
      ),
    );
    await _waitForTiles(tester, metrics);

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final controller = map.mapController!;
    metrics.reset();
    final stopwatch = Stopwatch()..start();

    await _move(tester, metrics, controller, const LatLng(-36.5, -59), 7);
    await _move(tester, metrics, controller, const LatLng(-36.5, -59), 8);
    await _move(tester, metrics, controller, const LatLng(-36.5, -58.5), 8);
    await _move(tester, metrics, controller, const LatLng(-36.5, -58.5), 10);
    stopwatch.stop();

    final snapshot = metrics.snapshot();
    final benchmarkData = {
      'wall_us': stopwatch.elapsedMicroseconds,
      'map_builds': snapshot.mapBuildCount,
      'tile_collection_builds': snapshot.tileCollectionBuildCount,
      'polygon_layer_builds': snapshot.polygonLayerBuildCount,
      'polygon_objects_created': snapshot.polygonObjectCreationCount,
      'polygon_objects_reused': snapshot.polygonObjectReuseCount,
      'projection_cache_hits': snapshot.projectedGeometryCacheHitCount,
      'projected_polygons': snapshot.projectedPolygonCount,
      'projected_vertices': snapshot.projectedVertexCount,
      'paint_count': snapshot.paintCount,
      'submitted_polygons': snapshot.submittedPolygonCount,
      'paint_us': snapshot.totalPaintDuration.inMicroseconds,
    };
    debugPrint('GIS_RENDER_BENCHMARK ${jsonEncode(benchmarkData)}');

    expect(snapshot.paintCount, greaterThan(0));
    expect(snapshot.submittedPolygonCount, greaterThan(0));
    expect(snapshot.projectedGeometryCacheHitCount, greaterThan(0));

    metrics.reset();
    await _move(tester, metrics, controller, const LatLng(-36.5, -59), 8);
    await _move(tester, metrics, controller, const LatLng(-36.5, -58.5), 8);
    final reuseSnapshot = metrics.snapshot();
    final reuseData = {
      'polygon_objects_created': reuseSnapshot.polygonObjectCreationCount,
      'polygon_objects_reused': reuseSnapshot.polygonObjectReuseCount,
      'polygon_layer_builds': reuseSnapshot.polygonLayerBuildCount,
    };
    debugPrint('GIS_RENDER_REUSE ${jsonEncode(reuseData)}');

    expect(reuseSnapshot.polygonObjectReuseCount, greaterThan(0));

    metrics.reset();
    controller.move(const LatLng(-36.5, -58.49), 8);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    final unchangedSnapshot = metrics.snapshot();

    expect(unchangedSnapshot.mapBuildCount, 0);
    expect(unchangedSnapshot.tileCollectionBuildCount, 0);
    expect(unchangedSnapshot.polygonLayerBuildCount, greaterThan(0));
    expect(unchangedSnapshot.polygonObjectCreationCount, 0);
    expect(unchangedSnapshot.projectedPolygonCount, 0);
    expect(unchangedSnapshot.projectedGeometryCacheHitCount, greaterThan(0));
  });

  testWidgets('synchronization status invalidates only its Home widget', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final metrics = GisRenderMetrics();
    final repository = PmTilesGisRepository.fromFile(
      archiveFile: File('assets/maps/soil_polygons.pmtiles'),
      layerName: AssetPaths.gisLayerName,
    );
    final connectivity = ConnectivityService(
      initialStatus: ConnectivityStatus.online,
    );
    final queue = PersistentSyncQueue(storageKey: 'test.sync.repaint.queue');
    final engine = SyncEngine(
      queue: queue,
      connectivity: connectivity,
      logger: SyncLogger(sink: (_) {}),
    );
    final synchronizationService = SynchronizationService(
      engine: engine,
      connectivity: connectivity,
      queue: queue,
      backendConfigured: () => true,
      backendConnected: () => true,
      deviceDetailsLoader: () async =>
          const SynchronizationDeviceDetails.empty(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: HomeScreen(
          deviceLinkedStatusLoader: () async => true,
          synchronizationService: synchronizationService,
        ),
        onGenerateRoute: (settings) {
          if (settings.name != AppRoutes.gisMap) return null;
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) =>
                GisMapScreen(repository: repository, renderMetrics: metrics),
          );
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('module-gis-map')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _waitForTiles(tester, metrics);

    metrics.reset();

    engine.status.value = SyncStatus.uploading;
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    final snapshot = metrics.snapshot();
    expect(snapshot.mapBuildCount, 0);
    expect(snapshot.tileCollectionBuildCount, 0);
    expect(snapshot.polygonLayerBuildCount, 0);
    expect(snapshot.paintCount, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    synchronizationService.dispose();
    await engine.dispose();
    metrics.dispose();
  });

  testWidgets('opening desktop Layers does not invalidate the map renderer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final metrics = GisRenderMetrics();
    addTearDown(metrics.dispose);
    final repository = PmTilesGisRepository.fromFile(
      archiveFile: File('assets/maps/soil_polygons.pmtiles'),
      layerName: AssetPaths.gisLayerName,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: GisMapScreen(repository: repository, renderMetrics: metrics),
      ),
    );
    await _waitForTiles(tester, metrics);
    metrics.reset();

    await tester.tap(find.byTooltip('Capas'));
    await tester.pump();

    final snapshot = metrics.snapshot();
    expect(find.text('2 capas disponibles'), findsOneWidget);
    final panelFade = find.ancestor(
      of: find.text('2 capas disponibles'),
      matching: find.byType(FadeTransition),
    );
    expect(panelFade, findsNothing);
    expect(snapshot.mapBuildCount, 0);
    expect(snapshot.tileCollectionBuildCount, 0);
    expect(snapshot.polygonLayerBuildCount, 0);
    expect(snapshot.polygonGenerationCount, 0);
    expect(snapshot.paintCount, 0);
  });

  testWidgets('desktop panel search does not invalidate the map renderer', (
    tester,
  ) async {
    final measurement = SavedMeasurement(
      id: 'search-isolation',
      type: SavedMeasurementType.area,
      name: 'Campo Norte',
      geometry: const [
        LatLng(-36.5, -60),
        LatLng(-36.5, -59.99),
        LatLng(-36.49, -59.99),
      ],
      createdAt: DateTime.utc(2026, 7, 16),
      areaSquareMeters: 12000,
      perimeterMeters: 450,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedMeasurement.storageKey: [jsonEncode(measurement.toJson())],
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final metrics = GisRenderMetrics();
    addTearDown(metrics.dispose);
    final repository = PmTilesGisRepository.fromFile(
      archiveFile: File('assets/maps/soil_polygons.pmtiles'),
      layerName: AssetPaths.gisLayerName,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: GisMapScreen(repository: repository, renderMetrics: metrics),
      ),
    );
    await _waitForTiles(tester, metrics);
    await tester.tap(find.byTooltip('Mediciones'));
    await tester.pumpAndSettle();
    final searchField = find.byKey(
      const ValueKey('desktop-measurements-search-field'),
    );
    expect(searchField, findsOneWidget);
    await _waitForRenderIdle(tester, metrics);
    metrics.reset();

    await tester.enterText(searchField, 'campo');
    await tester.pump();

    final snapshot = metrics.snapshot();
    expect(find.text('Campo Norte'), findsOneWidget);
    expect(snapshot.mapBuildCount, 0);
    expect(snapshot.tileCollectionBuildCount, 0);
    expect(snapshot.polygonLayerBuildCount, 0);
    expect(snapshot.polygonGenerationCount, 0);
  });
}

Future<void> _move(
  WidgetTester tester,
  GisRenderMetrics metrics,
  MapController controller,
  LatLng center,
  double zoom,
) async {
  controller.move(center, zoom);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await _waitForTiles(tester, metrics);
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

Future<void> _waitForRenderIdle(
  WidgetTester tester,
  GisRenderMetrics metrics,
) async {
  var stableSamples = 0;
  var previousBuildCount = metrics.polygonLayerBuildCount;
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    final buildCount = metrics.polygonLayerBuildCount;
    if (buildCount == previousBuildCount) {
      stableSamples++;
      if (stableSamples >= 5) return;
    } else {
      stableSamples = 0;
      previousBuildCount = buildCount;
    }
  }
  fail('Timed out waiting for the GIS renderer to become idle.');
}
