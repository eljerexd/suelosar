import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/engine/maplibre_engine.dart';
import 'package:suelosar/gis/gis_feature.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/gis/native_map_source.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android taps select the rendered offline PMTiles feature', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final repository = PmTilesGisRepository.fromAsset(
      assetPath: AssetPaths.gisPmTiles,
      versionAssetPath: AssetPaths.gisPmTilesVersion,
      layerName: AssetPaths.gisLayerName,
    );
    final engine = MapLibreEngine();
    final selected = <GisFeature>[];
    addTearDown(repository.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: engine.buildMapSurface(
            initialCenter: const LatLng(-36.67, -58.50),
            initialZoom: 11,
            minZoom: 4,
            maxZoom: 14,
            backgroundColor: const Color(0xFFFAFAF8),
            gesturesEnabled: true,
            annotationGesturesEnabled: true,
            onReady: () {},
            onPositionChanged: (_, {required hasGesture}) {},
            onTap: (details) {
              unawaited(() async {
                final feature = await engine.hitTestSoilFeature(
                  details.screenOffset,
                );
                if (feature == null) return;
                engine.setSelectedSoilFeature(feature.id, feature: feature);
                selected.add(feature);
              }());
            },
            children: const <Widget>[],
          ),
        ),
      ),
    );
    await _waitUntil(
      tester,
      () => find.byType(ml.MapLibreMap).evaluate().isNotEmpty,
    );

    final archiveInfo = await repository.initialize();
    final sources = [
      for (final source in await repository.getNativeMapSources())
        GisNativeMapSource(
          id: source.id,
          coverageId: 'buenos_aires',
          layerName: source.layerName,
          archivePath: source.archivePath,
          defaultCoverage: true,
        ),
    ];
    await engine.loadSoilPolygonsLayer(
      archiveInfo: archiveInfo,
      layerName: AssetPaths.gisLayerName,
      normalFillColor: const Color(0xFF527036),
      selectedFillColor: const Color(0xFF839C52),
      sources: sources,
    );
    await _waitUntil(tester, () => engine.debugSelectionLayerIds.isNotEmpty);

    final tile = await repository.loadTile(
      const GisTileCoordinates(zoom: 10, x: 344, y: 623),
    );
    final expected = tile.features.singleWhere(
      (feature) => feature.properties['SIMBC'] == 'GG12',
    );
    final point = _interiorPoint(expected);
    engine.move(point, 11);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    final screenPoint = engine.latLngToScreenOffset(point);
    expect(screenPoint, isNotNull);
    await tester.tapAt(screenPoint!);
    await _waitUntil(tester, () => selected.isNotEmpty);

    expect(selected.single.properties['SIMBC'], 'GG12');
    expect(selected.single.id, expected.id);
    expect(engine.debugVisibleSelectionLayerIds, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}

LatLng _interiorPoint(GisFeature feature) {
  final polygonValue = feature.geometry.type == 'Polygon'
      ? feature.geometry.coordinates
      : (feature.geometry.coordinates as List).first;
  final outer = _points((polygonValue as List).first as List);
  final minLon = outer.map((point) => point.longitude).reduce(_min);
  final maxLon = outer.map((point) => point.longitude).reduce(_max);
  final minLat = outer.map((point) => point.latitude).reduce(_min);
  final maxLat = outer.map((point) => point.latitude).reduce(_max);

  for (var row = 1; row < 24; row++) {
    for (var column = 1; column < 24; column++) {
      final candidate = LatLng(
        minLat + (maxLat - minLat) * row / 24,
        minLon + (maxLon - minLon) * column / 24,
      );
      if (_contains(outer, candidate)) return candidate;
    }
  }
  throw StateError('Feature ${feature.id} has no sampleable polygon interior.');
}

List<LatLng> _points(List<dynamic> values) => [
  for (final value in values)
    LatLng((value[1] as num).toDouble(), (value[0] as num).toDouble()),
];

bool _contains(List<LatLng> ring, LatLng point) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i];
    final b = ring[j];
    final crosses =
        (a.latitude > point.latitude) != (b.latitude > point.latitude);
    if (crosses &&
        point.longitude <
            (b.longitude - a.longitude) *
                    (point.latitude - a.latitude) /
                    (b.latitude - a.latitude) +
                a.longitude) {
      inside = !inside;
    }
  }
  return inside;
}

double _min(double a, double b) => a < b ? a : b;
double _max(double a, double b) => a > b ? a : b;

Future<void> _waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 160; attempt++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  fail('Timed out waiting for native PMTiles feature selection.');
}
