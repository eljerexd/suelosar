import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/gis/buenos_aires_pmtiles_delivery.dart';
import 'package:suelosar/gis/engine/maplibre_engine.dart';
import 'package:suelosar/gis/gis_feature.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/native_map_source.dart';
import 'package:suelosar/gis/gis_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'GG12 selection highlights its original native PMTiles feature',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final archive = BuenosAiresPmtilesDelivery.instance
          .resolveWindowsArchiveFile();
      expect(archive.existsSync(), isTrue);
      final repository = PmTilesGisRepository.fromFile(
        archiveFile: archive,
        layerName: 'soil_polygons',
      );
      final engine = MapLibreEngine();
      addTearDown(repository.close);
      addTearDown(engine.dispose);

      final center = const LatLng(-36.67, -58.50);
      var selectedByTap = <GisFeature>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: engine.buildMapSurface(
              initialCenter: center,
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
                  selectedByTap = [...selectedByTap, feature];
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
        GisNativeMapSource(
          id: 'soil-buenos_aires',
          coverageId: 'buenos_aires',
          layerName: 'soil_polygons',
          archivePath: archive.path,
          defaultCoverage: true,
        ),
      ];
      await engine.loadSoilPolygonsLayer(
        archiveInfo: archiveInfo,
        layerName: 'soil_polygons',
        normalFillColor: const Color(0xFF527036),
        selectedFillColor: const Color(0xFF839C52),
        sources: sources,
      );
      await _waitUntil(tester, () => engine.debugSelectionLayerIds.isNotEmpty);

      final sourceTile = await repository.loadTile(
        const GisTileCoordinates(zoom: 10, x: 344, y: 623),
      );
      final gg12 = sourceTile.features.singleWhere(
        (feature) => feature.properties['SIMBC'] == 'GG12',
      );
      final gg12Point = _interiorPoint(gg12);
      engine.move(gg12Point, 11);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();

      final gg12Offset = engine.latLngToScreenOffset(gg12Point);
      expect(gg12Offset, isNotNull);
      await tester.tapAt(gg12Offset!);
      await _waitUntil(tester, () => selectedByTap.isNotEmpty);

      final selectedGg12 = selectedByTap.last;
      expect(selectedGg12.properties['SIMBC'], 'GG12');
      expect(selectedGg12.properties['OBJECTID'].toString(), '939');
      expect(selectedGg12.id, '406');
      final selectionLayer = engine.debugSelectionLayerIds.single;
      expect(engine.debugVisibleSelectionLayerIds, {selectionLayer});
      expect(engine.debugSelectionLayerBindings[selectionLayer], (
        sources.single.id,
        'soil_polygons',
      ));
      expect(engine.debugSelectionFilters[selectionLayer], [
        '==',
        'OBJECTID',
        939,
      ]);

      engine.setSelectedSoilFeature(
        'native-fragment-fallback',
        feature: GisFeature(
          id: 'native-fragment-fallback',
          geometry: selectedGg12.geometry,
          properties: selectedGg12.properties,
          locality: selectedGg12.locality,
          soilMapId: selectedGg12.soilMapId,
        ),
      );
      expect(engine.debugSelectionFilters[selectionLayer], [
        '==',
        'OBJECTID',
        '939',
      ]);

      final adjacent = sourceTile.features.firstWhere(
        (feature) =>
            feature.id != gg12.id && feature.geometry.type == 'Polygon',
      );
      final adjacentPoint = _interiorPoint(adjacent);
      engine.move(adjacentPoint, 11);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      final adjacentOffset = engine.latLngToScreenOffset(adjacentPoint);
      expect(adjacentOffset, isNotNull);
      await tester.tapAt(adjacentOffset!);
      await _waitUntil(tester, () => selectedByTap.length > 1);

      expect(selectedByTap.last.id, adjacent.id);
      expect(selectedByTap.last.properties['SIMBC'], isNot('GG12'));
      expect(engine.debugSelectionFilters[selectionLayer], [
        '==',
        'OBJECTID',
        adjacent.properties['OBJECTID'],
      ]);

      final highZoomTile = await repository.loadTile(
        const GisTileCoordinates(zoom: 12, x: 1382, y: 2494),
      );
      final gg12WithHole = highZoomTile.features.singleWhere(
        (feature) => feature.properties['SIMBC'] == 'GG12',
      );
      expect(gg12WithHole.geometry.type, anyOf('Polygon', 'MultiPolygon'));
      final highZoomCoordinates = gg12WithHole.geometry.coordinates as List;
      final highZoomPolygons = gg12WithHole.geometry.type == 'Polygon'
          ? [highZoomCoordinates]
          : highZoomCoordinates;
      expect(
        highZoomPolygons.any((polygon) => (polygon as List).length > 1),
        isTrue,
      );
      final holePolygonIndex = highZoomPolygons.indexWhere(
        (polygon) => (polygon as List).length > 1,
      );
      final holePolygon = highZoomPolygons[holePolygonIndex] as List;
      expect(holePolygon, hasLength(2));

      final holeSample = _interiorPoint(
        gg12WithHole,
        polygonIndex: holePolygonIndex,
      );
      engine.move(holeSample, 13);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      final holeOffset = engine.latLngToScreenOffset(holeSample);
      expect(holeOffset, isNotNull);
      await tester.tapAt(holeOffset!);
      await _waitUntil(tester, () => selectedByTap.length > 2);
      expect(selectedByTap.last.id, '406');
      expect(selectedByTap.last.properties['SIMBC'], 'GG12');
      expect(engine.debugSelectionFilters[selectionLayer], ['==', r'$id', 406]);

      engine.setSelectedSoilFeature(null);
      expect(engine.debugVisibleSelectionLayerIds, isEmpty);
      expect(engine.debugSelectionFilters[selectionLayer], ['==', r'$id', -1]);
      expect(tester.takeException(), isNull);
    },
    skip:
        !Platform.isWindows ||
        !BuenosAiresPmtilesDelivery.instance
            .resolveWindowsArchiveFile()
            .existsSync(),
  );
}

LatLng _interiorPoint(GisFeature feature, {int? polygonIndex}) {
  final raw = feature.geometry.coordinates;
  final polygons = feature.geometry.type == 'Polygon' ? [raw] : raw as List;
  final candidates = polygonIndex == null ? polygons : [polygons[polygonIndex]];
  for (final polygonValue in candidates) {
    final polygon = polygonValue as List;
    if (polygon.isEmpty) continue;
    final rings = [for (final ring in polygon) _points(ring as List)];
    final outer = rings.first;
    if (outer.length < 4) continue;
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
        if (_contains(outer, candidate) &&
            !rings.skip(1).any((ring) => _contains(ring, candidate))) {
          return candidate;
        }
      }
    }
  }
  throw StateError('Feature ${feature.id} has no sampleable polygon interior.');
}

List<LatLng> _points(List ring) => [
  for (final coordinate in ring)
    LatLng((coordinate as List)[1] as double, coordinate[0] as double),
];

bool _contains(List<LatLng> ring, LatLng point) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final current = ring[i];
    final previous = ring[j];
    final crosses =
        (current.latitude > point.latitude) !=
        (previous.latitude > point.latitude);
    if (!crosses) continue;
    final crossingLongitude =
        (previous.longitude - current.longitude) *
            (point.latitude - current.latitude) /
            (previous.latitude - current.latitude) +
        current.longitude;
    if (point.longitude < crossingLongitude) inside = !inside;
  }
  return inside;
}

double _min(double first, double second) => first < second ? first : second;
double _max(double first, double second) => first > second ? first : second;

Future<void> _waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  fail('Timed out while waiting for the MapLibre selection test.');
}
