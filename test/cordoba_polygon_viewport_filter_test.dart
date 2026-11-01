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

  testWidgets('Córdoba prefilters off-screen parts before FlutterMap', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const center = LatLng(-32.296, -62.655);
    final features = <GisFeature>[
      _feature('inside', [_square(-32.296, -62.655, 0.002)]),
      _feature('outside', [_square(-32.296, -62.623, 0.001)]),
      _feature('boundary', [_square(-32.296, -62.628, 0.010)]),
      _feature('multipart', [
        _square(-32.296, -62.656, 0.002),
        _square(-32.296, -62.623, 0.001),
      ]),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _ViewportRepository(features),
          provinceConfig: ProvinceConfig.cordoba,
        ),
      ),
    );
    await _settleTiles(tester);

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.move(center, 13);
    await tester.pump(const Duration(milliseconds: 200));
    await _settleTiles(tester);
    final initialBounds = map.mapController!.camera.visibleBounds;
    expect(initialBounds.east, lessThan(-62.6235));
    expect(initialBounds.east, greaterThan(-62.633));
    expect(_submittedLongitudes(tester), hasLength(3));
    expect(
      _submittedLongitudes(tester).any((lon) => (lon + 62.623).abs() < 1e-6),
      isFalse,
    );

    // Moving east brings the previously off-screen polygon parts into the
    // submitted set; FlutterMap still performs its own culling afterward.
    map.mapController!.move(const LatLng(-32.296, -62.642), 13);
    await tester.pump(const Duration(milliseconds: 200));
    await _settleTiles(tester);
    expect(_submittedLongitudes(tester), hasLength(5));
    expect(
      _submittedLongitudes(tester).where(
        (lon) => (lon + 62.623).abs() < 1e-6,
      ),
      hasLength(2),
    );

    map.mapController!.move(center, 13);
    await tester.pump(const Duration(milliseconds: 200));
    await _settleTiles(tester);
    expect(_submittedLongitudes(tester), hasLength(3));
  });
}

List<double> _submittedLongitudes(WidgetTester tester) {
  return [
    for (final widget in tester.widgetList<PolygonLayer<GisFeature>>(
      find.byType(PolygonLayer<GisFeature>),
    ))
      for (final polygon in widget.polygons)
        (polygon.boundingBox.west + polygon.boundingBox.east) / 2,
  ];
}

Future<void> _settleTiles(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
  }
  fail('Timed out waiting for Córdoba tiles');
}

GisFeature _feature(String id, List<List<List<List<double>>>> parts) {
  return GisFeature(
    id: id,
    geometry: GisGeometry(type: 'MultiPolygon', coordinates: parts),
    properties: const <String, Object?>{},
    locality: '',
    soilMapId: 0,
  );
}

List<List<List<double>>> _square(
  double latitude,
  double longitude,
  double size,
) {
  final half = size / 2;
  return <List<List<double>>>[
    <List<double>>[
      <double>[longitude - half, latitude - half],
      <double>[longitude + half, latitude - half],
      <double>[longitude + half, latitude + half],
      <double>[longitude - half, latitude + half],
      <double>[longitude - half, latitude - half],
    ],
  ];
}

class _ViewportRepository implements GisRepository {
  const _ViewportRepository(this.features);

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
    const latitudeRadians = -32.296 * math.pi / 180;
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
