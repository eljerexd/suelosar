import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/engine/maplibre_engine.dart';
import 'package:suelosar/gis/engine/soil_map_engine.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/models/saved_measurement.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('active native measurement geometry stays one atomic snapshot', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final repository = PmTilesGisRepository.fromAsset(
      assetPath: AssetPaths.gisPmTiles,
      versionAssetPath: AssetPaths.gisPmTilesVersion,
      layerName: AssetPaths.gisLayerName,
    );
    final engine = MapLibreEngine();
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
    await _waitUntil(tester, () => engine.debugNativeAnnotationLayersReady);

    final mapRect = tester.getRect(find.byType(ml.MapLibreMap));
    final zoomAnchor = mapRect.size.center(Offset.zero) + const Offset(72, -38);
    final pointBeforeZoom = engine.screenOffsetToLatLng(zoomAnchor)!;
    final zoomBefore = engine.camera.zoom;
    engine.zoomAtScreenPoint(zoomAnchor, -120);
    await _waitUntil(tester, () => engine.camera.zoom > zoomBefore + 0.1);
    final pointAfterZoom = engine.screenOffsetToLatLng(zoomAnchor)!;
    expect(engine.camera.zoom, closeTo(zoomBefore + 120 / 450, 1e-3));
    expect(pointAfterZoom.latitude, closeTo(pointBeforeZoom.latitude, 1e-5));
    expect(pointAfterZoom.longitude, closeTo(pointBeforeZoom.longitude, 1e-5));

    final start = engine.camera.center;
    final positions = [
      LatLng(start.latitude + 0.006, start.longitude + 0.004),
      LatLng(start.latitude - 0.008, start.longitude + 0.009),
      LatLng(start.latitude + 0.011, start.longitude - 0.012),
    ];
    for (final endpoint in positions) {
      engine.setMeasurementGeometry(
        distancePoints: [start, endpoint],
        areaPoints: const [],
        color: Colors.red,
        markers: [_marker(start, '1'), _marker(endpoint, '2')],
      );
    }
    await engine.debugSyncMeasurements();

    expect(
      engine.debugMeasurementLayerIds,
      containsAll({
        'suelosar-measure-active-distance-line',
        'suelosar-measure-active-vertices',
        'suelosar-measure-active-vertex-labels',
      }),
    );
    _expectMeasurementLayerHierarchy(engine.debugMeasurementLayerOrder);
    final active = _features(engine.debugActiveMeasurementData!);
    final line = active.singleWhere(
      (feature) => feature['properties']['kind'] == 'active-distance',
    );
    final secondVertex = active.singleWhere(
      (feature) => feature['id'] == 'active-vertex-1',
    );
    final finalCoordinate = [positions.last.longitude, positions.last.latitude];
    expect(line['geometry']['coordinates'].last, finalCoordinate);
    expect(secondVertex['geometry']['coordinates'], finalCoordinate);
    expect(
      (jsonDecode(engine.debugActiveMeasurementData!)
          as Map)['properties']['snapshotVersion'],
      engine.debugMeasurementSnapshotVersion,
    );
    expect(active, hasLength(3));

    engine.setProvinceBoundaryHighlight(
      coverageId: 'test-province',
      rings: const [
        [LatLng(-34.0, -58.0), LatLng(-35.0, -58.0), LatLng(-35.0, -59.0)],
      ],
      fillColor: const Color(0x1A62695C),
      borderColor: const Color(0x73765D83),
    );
    await engine.debugSyncProvinceHighlights();
    final provinceSnapshot = engine.debugProvinceHighlightData!;
    expect(
      engine.debugProvinceHighlightLayerIds,
      containsAll({
        'suelosar-province-highlight-fill',
        'suelosar-province-highlight-outline',
      }),
    );
    final provinceFeature =
        ((jsonDecode(provinceSnapshot) as Map)['features'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere((feature) => feature['id'] == 'test-province');
    expect(provinceFeature['geometry']['type'], 'MultiPolygon');
    expect(provinceFeature['geometry']['coordinates'][0][0], [
      [-58.0, -34.0],
      [-58.0, -35.0],
      [-59.0, -35.0],
      [-58.0, -34.0],
    ]);
    engine.move(engine.camera.center, engine.camera.zoom + 0.25);
    await tester.pump();
    expect(engine.debugProvinceHighlightData, provinceSnapshot);

    engine.setSavedMeasurementGeometry(
      measurements: [
        SavedMeasurement(
          id: 'saved-distance-runtime',
          type: SavedMeasurementType.distance,
          name: 'Prueba',
          geometry: [start, positions.last],
          createdAt: DateTime.utc(2026),
        ),
      ],
    );
    await engine.debugSyncMeasurements();
    _expectMeasurementLayerHierarchy(engine.debugMeasurementLayerOrder);
    final saved = _features(engine.debugSavedMeasurementData!);
    expect(saved.single['id'], 'saved-distance-runtime');
    expect(saved.single['geometry']['coordinates'].last, finalCoordinate);

    engine.setMeasurementGeometry(
      distancePoints: const [],
      areaPoints: const [],
      color: Colors.red,
    );
    engine.setSavedMeasurementGeometry(measurements: const []);
    engine.setProvinceBoundaryHighlight(
      coverageId: 'test-province',
      rings: null,
      fillColor: Colors.transparent,
      borderColor: Colors.transparent,
    );
    await engine.debugSyncProvinceHighlights();
    await engine.debugSyncMeasurements();
    expect(_features(engine.debugActiveMeasurementData!), isEmpty);
    expect(_features(engine.debugSavedMeasurementData!), isEmpty);
    expect(tester.takeException(), isNull);
  });
}

void _expectMeasurementLayerHierarchy(List<String> order) {
  int index(String id) {
    final result = order.indexOf(id);
    expect(result, isNonNegative, reason: '$id must be installed');
    return result;
  }

  expect(
    index('suelosar-measure-active-area-fill'),
    lessThan(index('suelosar-measure-active-area-outline')),
  );
  expect(
    index('suelosar-measure-saved-area-selected'),
    lessThan(index('suelosar-measure-saved-area-line-selected')),
  );
  expect(
    index('suelosar-measure-saved-distance-line-selected'),
    lessThan(index('suelosar-measure-active-vertices')),
    reason: order.join(' > '),
  );
  expect(
    index('suelosar-measure-active-vertices'),
    lessThan(index('suelosar-measure-active-vertex-labels')),
  );
}

SoilMapMeasurementMarker _marker(LatLng point, String label) =>
    SoilMapMeasurementMarker(
      point: point,
      size: const Size.square(30),
      label: label,
      fillColor: Colors.red,
      textColor: Colors.white,
      strokeColor: Colors.white,
      child: const SizedBox.shrink(),
    );

List<Map<String, dynamic>> _features(String encoded) =>
    ((jsonDecode(encoded) as Map<String, dynamic>)['features'] as List)
        .cast<Map<String, dynamic>>();

Future<void> _waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 160; attempt++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  fail('Timed out waiting for the MapLibre map view.');
}
