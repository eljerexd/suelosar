import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/gis_feature.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/gis/province_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  testWidgets(
    'main keeps Córdoba symbols in feature data without painting map labels',
    (tester) async {
      final feature = _unitFeature(
        id: 'cordoba-unit',
        objectId: 491,
        symbol: 'ALd9',
        polygons: <List<List<List<double>>>>[
          _square(latitude: -32.296, longitude: -62.655, size: 0.030),
        ],
      );

      await _pumpCordobaMap(tester, <GisFeature>[feature]);

      final dynamic state = tester.state(find.byType(GisMapScreen));
      expect(state.acceptedUnitSymbolLabels, isEmpty);
      expect(feature.properties['SIMBC'], 'ALd9');
    },
  );
}

Future<void> _pumpCordobaMap(
  WidgetTester tester,
  List<GisFeature> features, {
  Size viewport = const Size(1000, 700),
  LatLng center = const LatLng(-32.296, -62.655),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    MaterialApp(
      home: GisMapScreen(
        repository: _CordobaLabelRepository(features),
        provinceConfig: ProvinceConfig.cordoba,
      ),
    ),
  );
  await _pumpUntilTilesLoad(tester);

  final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
  map.mapController!.move(center, 13);
  await tester.pump(const Duration(milliseconds: 200));
  await _pumpUntilTilesLoad(tester);
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _pumpUntilTilesLoad(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
  }
  fail('Timed out waiting for Córdoba GIS tiles.');
}

GisFeature _unitFeature({
  required String id,
  required int objectId,
  required String symbol,
  required List<List<List<List<double>>>> polygons,
}) {
  return GisFeature(
    id: id,
    geometry: GisGeometry(type: 'MultiPolygon', coordinates: polygons),
    properties: <String, Object?>{
      'OBJECTID': objectId,
      'SIMBC': symbol,
      'Nombre_UC': symbol,
    },
    locality: '',
    soilMapId: 0,
  );
}

List<List<List<double>>> _square({
  required double latitude,
  required double longitude,
  required double size,
}) {
  return _rectangle(
    latitude: latitude,
    longitude: longitude,
    width: size,
    height: size,
  );
}

List<List<List<double>>> _rectangle({
  required double latitude,
  required double longitude,
  required double width,
  required double height,
}) {
  final halfWidth = width / 2;
  final halfHeight = height / 2;
  return <List<List<double>>>[
    <List<double>>[
      <double>[longitude - halfWidth, latitude - halfHeight],
      <double>[longitude + halfWidth, latitude - halfHeight],
      <double>[longitude + halfWidth, latitude + halfHeight],
      <double>[longitude - halfWidth, latitude + halfHeight],
      <double>[longitude - halfWidth, latitude - halfHeight],
    ],
  ];
}

class _CordobaLabelRepository implements GisRepository {
  const _CordobaLabelRepository(this.features);

  final List<GisFeature> features;

  @override
  Future<GisArchiveInfo> initialize() async => const GisArchiveInfo(
    minZoom: 4,
    maxZoom: 14,
    centerLatitude: -32.296,
    centerLongitude: -62.655,
  );

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async {
    final scale = 1 << coordinates.zoom;
    final centerX = (((-62.655 + 180) / 360) * scale).floor();
    final latitudeRadians = -32.296 * math.pi / 180;
    final centerY =
        ((1 -
                    math.log(
                          math.tan(latitudeRadians) +
                              1 / math.cos(latitudeRadians),
                        ) /
                        math.pi) /
                2 *
                scale)
            .floor();
    return GisLayer(
      id: 'cordoba-${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
      name: AssetPaths.gisLayerName,
      features: coordinates.x == centerX && coordinates.y == centerY
          ? features
          : const <GisFeature>[],
    );
  }

  @override
  Future<void> close() async {}
}
