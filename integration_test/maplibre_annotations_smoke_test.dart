import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/engine/maplibre_engine.dart';
import 'package:suelosar/gis/engine/soil_map_engine.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:latlong2/latlong.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows GIS installs native reference annotation layers', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final repository = PmTilesGisRepository.fromAsset(
      assetPath: AssetPaths.gisPmTiles,
      versionAssetPath: AssetPaths.gisPmTilesVersion,
      layerName: AssetPaths.gisLayerName,
    );
    final engine = MapLibreEngine();
    String? tappedMarkerId;
    addTearDown(repository.close);

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: repository, engine: engine),
      ),
    );

    await _waitUntil(
      tester,
      () => find.byType(ml.MapLibreMap).evaluate().isNotEmpty,
    );
    await _waitUntil(
      tester,
      () =>
          engine.debugNativeAnnotationLayersReady &&
          engine.debugCityAnnotationCount > 0 &&
          engine.debugNativeAnnotationLayerIds.containsAll({
            'suelosar-city-dots',
            'suelosar-city-secondary-dots',
            'suelosar-city-labels',
            'suelosar-city-secondary-labels',
            'suelosar-current-location-accuracy',
            'suelosar-current-location-marker',
            'suelosar-personal-marker-circles',
            'suelosar-personal-markers',
          }),
    );

    expect(find.byType(ml.MapLibreMap), findsOneWidget);
    expect(find.byType(ml.WidgetLayer), findsNothing);
    expect(engine.debugCityAnnotationCount, greaterThan(0));

    final panStart = engine.camera;
    final geographicAnchor = LatLng(
      panStart.center.latitude + 0.04,
      panStart.center.longitude + 0.04,
    );
    final anchorBeforePan = engine.latLngToScreenOffset(geographicAnchor);
    expect(anchorBeforePan, isNotNull);
    await tester.timedDrag(
      find.byType(ml.MapLibreMap),
      const Offset(110, 56),
      const Duration(milliseconds: 400),
    );
    await _waitUntil(
      tester,
      () =>
          (engine.camera.center.latitude - panStart.center.latitude).abs() >
          0.001,
    );
    final anchorAfterPan = engine.latLngToScreenOffset(geographicAnchor);
    expect(anchorAfterPan, isNotNull);
    expect((anchorAfterPan! - anchorBeforePan!).distance, greaterThan(30));

    final initialCamera = engine.camera;
    engine.move(
      LatLng(
        initialCamera.center.latitude + 0.04,
        initialCamera.center.longitude,
      ),
      (initialCamera.zoom + 0.35).clamp(1, 24),
    );
    engine.rotate(17);
    await _waitUntil(tester, () => (engine.camera.rotation - 17).abs() < 0.1);
    expect(
      engine.camera.center.latitude,
      closeTo(initialCamera.center.latitude + 0.04, 0.002),
    );
    expect(engine.camera.zoom, closeTo(initialCamera.zoom + 0.35, 0.02));

    engine.setPersonalMarkers([
      SoilMapMarkerPin(
        id: 'runtime-marker-first',
        point: engine.camera.center,
        icon: Icons.place,
        categoryId: 'soil-pit',
        properties: const {'label': 'Runtime marker'},
      ),
      SoilMapMarkerPin(
        id: 'runtime-marker-top',
        point: engine.camera.center,
        icon: Icons.science,
        categoryId: 'sampling',
        properties: const {'label': 'Top marker'},
      ),
    ], onMarkerTap: (id) => tappedMarkerId = id);
    engine.debugSetAnnotationGesturesEnabled(false);
    await engine.debugSyncNativeAnnotations();
    expect(engine.debugPersonalMarkerData, contains('runtime-marker-first'));
    expect(engine.debugPersonalMarkerData, contains('runtime-marker-top'));
    final viewportMarkerIds = await _waitForMarkerHits(tester, engine, null, {
      'runtime-marker-first',
      'runtime-marker-top',
    });
    expect(
      viewportMarkerIds,
      containsAll({'runtime-marker-first', 'runtime-marker-top'}),
      reason:
          'The native personal-marker layer must render its GeoJSON features.',
    );
    final markerAnchor = engine.latLngToScreenOffset(engine.camera.center);
    expect(markerAnchor, isNotNull);
    final markerCenter = markerAnchor! + const Offset(0, -22);
    final hitIds = await _waitForMarkerHits(tester, engine, markerCenter, {
      'runtime-marker-first',
      'runtime-marker-top',
    });
    expect(hitIds, containsAll({'runtime-marker-first', 'runtime-marker-top'}));
    expect(await engine.debugDispatchPersonalMarkerTap(markerCenter), isTrue);
    expect(tappedMarkerId, 'runtime-marker-top');
    expect(
      await engine.debugDispatchPersonalMarkerTap(
        markerCenter + const Offset(10, 0),
      ),
      isTrue,
      reason: 'Native rendered-symbol hit testing should include nearby taps.',
    );
    engine.debugSetAnnotationGesturesEnabled(true);
    expect(
      await engine.debugDispatchPersonalMarkerTap(markerCenter),
      isFalse,
      reason: 'Measurement input must keep priority over personal markers.',
    );
    engine.debugSetAnnotationGesturesEnabled(false);

    engine.setCurrentLocationMarker(
      point: engine.camera.center,
      accuracyMeters: 80,
      showAccuracyCircle: true,
    );
    await engine.debugSyncNativeAnnotations();
    expect(engine.debugCurrentLocationData, isNotNull);
    expect(engine.debugCurrentLocationData, contains('"hasAccuracy":true'));

    engine.setPersonalMarkers(const [], onMarkerTap: (_) {});
    engine.setCurrentLocationMarker(
      point: null,
      accuracyMeters: null,
      showAccuracyCircle: false,
    );
    await engine.debugSyncNativeAnnotations();
    expect(await engine.debugDispatchPersonalMarkerTap(markerCenter), isFalse);
    expect(tester.takeException(), isNull);

    final firstVertex = engine.camera.center;
    final rapidMoves = [
      LatLng(firstVertex.latitude + 0.005, firstVertex.longitude + 0.005),
      LatLng(firstVertex.latitude + 0.01, firstVertex.longitude - 0.006),
      LatLng(firstVertex.latitude - 0.008, firstVertex.longitude + 0.012),
    ];
    for (final movedVertex in rapidMoves) {
      engine.setMeasurementGeometry(
        distancePoints: [firstVertex, movedVertex],
        areaPoints: const [],
        color: Colors.red,
        markers: [
          SoilMapMeasurementMarker(
            point: firstVertex,
            size: const Size.square(38),
            label: '1',
            child: const SizedBox.shrink(),
          ),
          SoilMapMeasurementMarker(
            point: movedVertex,
            size: const Size.square(30),
            label: '2',
            child: const SizedBox.shrink(),
          ),
        ],
      );
    }
    await engine.debugSyncMeasurements();
    expect(
      engine.debugMeasurementLayerIds,
      containsAll({
        'suelosar-measure-active-vertices',
        'suelosar-measure-active-vertex-labels',
      }),
    );
    final activeFeatures =
        ((jsonDecode(engine.debugActiveMeasurementData!)
                    as Map<String, dynamic>)['features']
                as List)
            .cast<Map<String, dynamic>>();
    final activeLine = activeFeatures.singleWhere(
      (feature) => feature['properties']['kind'] == 'active-distance',
    );
    final activeVertex = activeFeatures.singleWhere(
      (feature) => feature['id'] == 'active-vertex-1',
    );
    expect(activeLine['geometry']['coordinates'].last, [
      rapidMoves.last.longitude,
      rapidMoves.last.latitude,
    ]);
    expect(activeVertex['geometry']['coordinates'], [
      rapidMoves.last.longitude,
      rapidMoves.last.latitude,
    ]);
    engine.setMeasurementGeometry(
      distancePoints: const [],
      areaPoints: const [],
      color: Colors.red,
    );
    await engine.debugSyncMeasurements();
    expect(
      (jsonDecode(engine.debugActiveMeasurementData!) as Map)['features'],
      isEmpty,
    );
  });
}

Future<void> _waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 160; attempt++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  fail('Timed out waiting for the native map annotations.');
}

Future<Set<String>> _waitForMarkerHits(
  WidgetTester tester,
  MapLibreEngine engine,
  Offset? point,
  Set<String> expected,
) async {
  Set<String> latest = const {};
  for (var attempt = 0; attempt < 40; attempt++) {
    latest = (await tester.runAsync(
      () => point == null
          ? engine.debugRenderedPersonalMarkerIdsInViewport()
          : engine.debugRenderedPersonalMarkerIdsAt(point),
    ))!;
    if (latest.containsAll(expected)) return latest;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  return latest;
}
