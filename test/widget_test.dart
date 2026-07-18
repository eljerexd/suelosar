import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:suelosar/app/suelos_ar_app.dart';
import 'package:suelosar/constants/app_icons.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/gis_feature.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_location_service.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/gis/gis_soil_series.dart';
import 'package:suelosar/models/soil_map.dart';
import 'package:suelosar/models/favorite_soil_feature.dart';
import 'package:suelosar/models/measurement_color_option.dart';
import 'package:suelosar/models/personal_marker.dart';
import 'package:suelosar/models/saved_measurement.dart';
import 'package:suelosar/repositories/pdf_series_repository.dart';
import 'package:suelosar/repositories/soil_map_repository.dart';
import 'package:suelosar/screens/favorites_screen.dart';
import 'package:suelosar/screens/gis_favorites_screen.dart';
import 'package:suelosar/screens/measurements_screen.dart';
import 'package:suelosar/screens/pdf_viewer_screen.dart';
import 'package:suelosar/screens/personal_markers_screen.dart';
import 'package:suelosar/services/settings_service.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reduce animations setting persists and restores', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings.reduce_animations': true,
      'settings.follow_location_automatically': true,
      'settings.confirm_before_deleting': true,
      'settings.show_gps_accuracy_circle': false,
      'settings.show_zoom_level': false,
      'settings.default_measurement_color': 'orange',
    });
    final settings = SettingsService.instance;
    await settings.initialize();
    expect(settings.reduceAnimations, isTrue);
    expect(settings.followLocationAutomatically, isTrue);
    expect(settings.confirmBeforeDeleting, isTrue);
    expect(settings.showGpsAccuracyCircle, isFalse);
    expect(settings.showZoomLevel, isFalse);
    expect(settings.defaultMeasurementColor, MeasurementColorOption.orange);

    await settings.setReduceAnimations(false);
    await settings.setFollowLocationAutomatically(false);
    await settings.setConfirmBeforeDeleting(false);
    await settings.setShowGpsAccuracyCircle(true);
    await settings.setShowZoomLevel(true);
    await settings.setDefaultMeasurementColor(MeasurementColorOption.blue);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('settings.reduce_animations'), isFalse);
    expect(
      preferences.getBool('settings.follow_location_automatically'),
      isFalse,
    );
    expect(preferences.getBool('settings.confirm_before_deleting'), isFalse);
    expect(preferences.getBool('settings.show_gps_accuracy_circle'), isTrue);
    expect(preferences.getBool('settings.show_zoom_level'), isTrue);
    expect(preferences.getString('settings.default_measurement_color'), 'blue');
    await settings.setConfirmBeforeDeleting(true);
  });

  testWidgets('personal markers screen searches and deletes in memory', (
    tester,
  ) async {
    final markers = [
      PersonalMarker(
        id: 'marker-1',
        latitude: -34.6,
        longitude: -58.4,
        name: 'Cañada norte',
        description: 'Primera linea\nSegunda linea',
        createdAt: DateTime(2026, 6, 30, 10, 15),
        category: PersonalMarkerCategory.observation,
      ),
      PersonalMarker(
        id: 'marker-2',
        latitude: -35.1,
        longitude: -59.2,
        name: 'Lote sur',
        description: 'Control',
        createdAt: DateTime(2026, 6, 29, 9),
      ),
    ];
    SharedPreferences.setMockInitialValues(<String, Object>{
      PersonalMarker.storageKey: markers
          .map((marker) => jsonEncode(marker.toJson()))
          .toList(),
    });

    await tester.pumpWidget(const MaterialApp(home: PersonalMarkersScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Primera linea'), findsOneWidget);
    expect(find.text('Segunda linea'), findsNothing);
    await tester.enterText(find.byType(SearchBar), 'canada');
    await tester.pump();
    expect(find.text('Cañada norte'), findsOneWidget);
    expect(find.text('Lote sur'), findsNothing);

    await tester.enterText(find.byType(SearchBar), 'observacion');
    await tester.pump();
    expect(find.text('Cañada norte'), findsOneWidget);
    expect(find.text('Lote sur'), findsNothing);

    await tester.enterText(find.byType(SearchBar), '');
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('delete-personal-marker-marker-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Eliminar'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cañada norte'), findsNothing);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList(PersonalMarker.storageKey), hasLength(1));
  });

  testWidgets('GIS portrait layout keeps one anchored personal marker', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final marker = PersonalMarker(
      id: 'portrait-marker',
      latitude: -36.5,
      longitude: -60,
      name: 'Punto móvil',
      description: '',
      createdAt: DateTime.utc(2026, 7, 3),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      PersonalMarker.storageKey: <String>[jsonEncode(marker.toJson())],
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'portrait-feature',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('marker-hit-target-portrait-marker')),
      findsOneWidget,
    );
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.move(const LatLng(-36.6, -59.9), 8);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('marker-hit-target-portrait-marker')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorites screen lists, returns, and removes favorites', (
    tester,
  ) async {
    final favorite = FavoriteSoilFeature(
      id: 'unit-1',
      unitName: 'Complejo Alem',
      unitSymbol: 'Al1',
      soilSeries: const ['Alem', 'Junín'],
      pdfIdentifier: 'Alem.pdf',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      FavoriteSoilFeature.storageKey: <String>[jsonEncode(favorite.toJson())],
    });

    String? selectedId;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selectedId = await Navigator.of(context).push<String>(
                MaterialPageRoute(builder: (_) => const GisFavoritesScreen()),
              );
            },
            child: const Text('Abrir'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Complejo Alem'), findsOneWidget);
    expect(find.textContaining('Símbolo: Al1'), findsOneWidget);
    expect(find.textContaining('Serie principal: Alem'), findsOneWidget);

    await tester.tap(find.text('Complejo Alem'));
    await tester.pumpAndSettle();
    expect(selectedId, 'unit-1');

    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Quitar de favoritos'));
    await tester.pumpAndSettle();
    expect(find.text('Todavía no hay favoritos'), findsOneWidget);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList(FavoriteSoilFeature.storageKey), isEmpty);
  });

  testWidgets('favorites search normalizes text and ranks matches', (
    tester,
  ) async {
    final favorites = <FavoriteSoilFeature>[
      FavoriteSoilFeature(
        id: 'contains',
        unitName: 'Complejo Alem',
        unitSymbol: 'CA1',
        soilSeries: ['Rojas'],
        pdfIdentifier: null,
      ),
      FavoriteSoilFeature(
        id: 'prefix',
        unitName: 'Alem Grande',
        unitSymbol: 'AG1',
        soilSeries: ['Pergamino'],
        pdfIdentifier: null,
      ),
      FavoriteSoilFeature(
        id: 'exact',
        unitName: 'Alem',
        unitSymbol: 'AL1',
        soilSeries: ['Junín'],
        pdfIdentifier: null,
      ),
    ];
    SharedPreferences.setMockInitialValues(<String, Object>{
      FavoriteSoilFeature.storageKey: favorites
          .map((favorite) => jsonEncode(favorite.toJson()))
          .toList(),
    });

    await tester.pumpWidget(const MaterialApp(home: GisFavoritesScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'alem');
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('Alem')).dy,
      lessThan(tester.getTopLeft(find.text('Alem Grande')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Alem Grande')).dy,
      lessThan(tester.getTopLeft(find.text('Complejo Alem')).dy),
    );

    await tester.enterText(find.byType(SearchBar), 'junin');
    await tester.pump();
    expect(find.text('Alem'), findsOneWidget);
    expect(find.text('Alem Grande'), findsNothing);

    await tester.enterText(find.byType(SearchBar), 'inexistente');
    await tester.pump();
    expect(find.text('No se encontraron favoritos.'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), '');
    await tester.pump();
    expect(find.byType(ListTile), findsNWidgets(3));
  });

  testWidgets('main menu favorites open the saved PDF directly', (
    tester,
  ) async {
    final favorite = FavoriteSoilFeature(
      id: 'soil-map:Junín.pdf',
      unitName: 'Junín',
      unitSymbol: 'Ju1',
      soilSeries: const ['Junín'],
      pdfIdentifier: 'Junín.pdf',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      FavoriteSoilFeature.storageKey: <String>[jsonEncode(favorite.toJson())],
    });

    await tester.pumpWidget(const MaterialApp(home: FavoritesScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Junín'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(find.byType(GisMapScreen), findsNothing);
  });

  test('soil maps catalog uses the complete domain schema', () async {
    final rawJson = await rootBundle.loadString(AssetPaths.soilMapsCatalog);
    final records = jsonDecode(rawJson) as List<dynamic>;

    expect(records, isNotEmpty);

    Map<String, dynamic> findRecord(String name) {
      return records
          .map((record) => Map<String, dynamic>.from(record as Map))
          .firstWhere((record) => record['name'] == name);
    }

    expect(findRecord('Junín')['pdf'], 'Junín.pdf');
    expect(findRecord('Tres Arroyos')['pdf'], 'Tres_Arroyos.pdf');
    expect(findRecord('Villa Cañás')['pdf'], 'Villa_Cañás.pdf');

    for (var index = 0; index < records.length; index++) {
      final record = Map<String, dynamic>.from(records[index] as Map);

      expect(record.keys.toList(), [
        'id',
        'name',
        'province',
        'department',
        'scale',
        'pdf',
        'memory',
        'map',
        'notes',
      ]);
      expect(record['id'], index);
      expect(record['name'], isA<String>());
      expect(record['province'], isA<String>());
      expect(record['department'], isA<String>());
      expect(record['scale'], isA<String>());
      expect(record['pdf'], isA<String>());
      expect(record['memory'], isNull);
      expect(record['map'], isNull);
      expect(record['notes'], isA<String>());
    }
  });

  test('SoilMap keeps backward compatibility with older catalog records', () {
    final soilMap = SoilMap.fromJson({'name': 'Junín', 'pdf': 'Junín.pdf'});

    expect(soilMap.id, 0);
    expect(soilMap.name, 'Junín');
    expect(soilMap.province, '');
    expect(soilMap.department, '');
    expect(soilMap.scale, '');
    expect(soilMap.pdf, 'Junín.pdf');
    expect(soilMap.memory, isNull);
    expect(soilMap.map, isNull);
    expect(soilMap.notes, '');
  });

  test('SoilMapRepository decodes catalog records', () async {
    final rawJson = await rootBundle.loadString(AssetPaths.soilMapsCatalog);
    final soilMaps = const SoilMapRepository().decodeSoilMaps(rawJson);

    expect(soilMaps, isNotEmpty);
    expect(soilMaps.first.id, 0);
    expect(soilMaps.first.name, isNotEmpty);
    expect(soilMaps.first.pdf.endsWith('.pdf'), isTrue);
  });

  test('GIS repository reads polygons and attributes from PMTiles', () async {
    final repository = PmTilesGisRepository.fromFile(
      archiveFile: File('assets/maps/soil_polygons.pmtiles'),
      layerName: AssetPaths.gisLayerName,
    );
    addTearDown(repository.close);

    final archiveInfo = await repository.initialize();
    final layer = await repository.loadTile(
      const GisTileCoordinates(zoom: 6, x: 21, y: 39),
    );

    expect(archiveInfo.minZoom, 4);
    expect(archiveInfo.maxZoom, 14);
    expect(layer.features, isNotEmpty);
    expect(
      layer.features.every(
        (feature) =>
            const {'Polygon', 'MultiPolygon'}.contains(feature.geometry.type),
      ),
      isTrue,
    );
    expect(
      layer.features.every((feature) => feature.properties.isNotEmpty),
      isTrue,
    );
    expect(layer.features.first.properties, contains('SIMBC'));
    expect(layer.features.first.properties, contains('Nombre_UC'));
    expect(layer.features.first.properties, contains('SERIE1'));
  });

  test('GIS repository decodes each PMTiles tile only once', () async {
    final repository = PmTilesGisRepository.fromFile(
      archiveFile: File('assets/maps/soil_polygons.pmtiles'),
      layerName: AssetPaths.gisLayerName,
    );
    addTearDown(repository.close);
    const coordinates = GisTileCoordinates(zoom: 6, x: 21, y: 39);

    final concurrentLayers = await Future.wait(
      List<Future<GisLayer>>.generate(
        8,
        (_) => repository.loadTile(coordinates),
      ),
    );
    final cachedLayer = await repository.loadTile(coordinates);
    final metrics = repository.cacheMetrics;

    expect(
      concurrentLayers.every((layer) => identical(layer, concurrentLayers[0])),
      isTrue,
    );
    expect(identical(cachedLayer, concurrentLayers[0]), isTrue);
    expect(metrics.decodedTileCount, 1);
    expect(metrics.cachedTileCount, 1);
    expect(metrics.coalescedRequestCount, 7);
    expect(metrics.cacheHitCount, 1);
    expect(metrics.totalDecodeDuration, greaterThan(Duration.zero));
  });

  test('GIS repository bounds decoded tiles with LRU eviction', () async {
    final repository = PmTilesGisRepository.fromFile(
      archiveFile: File('assets/maps/soil_polygons.pmtiles'),
      layerName: AssetPaths.gisLayerName,
      maxCacheEntries: 3,
    );
    addTearDown(repository.close);
    const first = GisTileCoordinates(zoom: 6, x: 21, y: 39);
    const second = GisTileCoordinates(zoom: 6, x: 21, y: 38);
    const third = GisTileCoordinates(zoom: 6, x: 22, y: 39);
    const fourth = GisTileCoordinates(zoom: 6, x: 22, y: 38);

    final firstLayer = await repository.loadTile(first);
    final secondLayer = await repository.loadTile(second);
    await repository.loadTile(third);
    expect(identical(await repository.loadTile(first), firstLayer), isTrue);

    await repository.loadTile(fourth);
    final metricsAfterEviction = repository.cacheMetrics;
    expect(metricsAfterEviction.cachedTileCount, 3);
    expect(metricsAfterEviction.maximumCachedTileCount, 3);

    final reloadedSecondLayer = await repository.loadTile(second);
    expect(identical(reloadedSecondLayer, secondLayer), isFalse);
    expect(repository.cacheMetrics.cachedTileCount, 3);
    expect(identical(await repository.loadTile(first), firstLayer), isTrue);
  });

  test('GIS soil series reads percentages and ignores empty values', () {
    final series = GisSoilSeries.fromProperties({
      'SERIE1': 'Arroyo Dulce',
      'PORC1': 70,
      'SERIE2': '',
      'PORC2': 0,
      'SERIE3': null,
      'PORC3': null,
      'SERIE4': 'Harding  Green',
      'PORC4': 30.0,
      'SERIE5': '   ',
      'PORC5': 0,
      'SERIE6': 'Pergamino',
      'PORC6': '15%',
    });

    expect(series, hasLength(3));
    expect(series.first.displayLabel, 'Arroyo Dulce (70%)');
    expect(series[1].displayLabel, 'Harding  Green (30%)');
    expect(series.last.displayLabel, 'Pergamino (15%)');
  });

  test('PDF series repository indexes and normalizes bundled PDFs', () async {
    final repository = PdfSeriesRepository();
    final index = await repository.loadIndex();
    final indexedAssets = index.values.expand((paths) => paths).toList();

    expect(indexedAssets.length, greaterThan(300));
    expect(indexedAssets.toSet(), hasLength(indexedAssets.length));
    expect(
      indexedAssets.every((path) => path.startsWith('assets/pdfs/')),
      isTrue,
    );
    expect(
      await repository.findPdfForSeries('ARROYO   DULCE'),
      'assets/pdfs/Arroyo_Dulce.pdf',
    );
    expect(
      await repository.findPdfForSeries('Aaron Castellanos'),
      'assets/pdfs/Aarón_Castellanos.pdf',
    );
    expect(
      await repository.findPdfForSeries('Harding    Green'),
      'assets/pdfs/Harding__Green.pdf',
    );
    expect(await repository.findPdfForSeries('Unknown series'), isNull);
  });

  testWidgets('GIS map is created before PMTiles initialization completes', (
    WidgetTester tester,
  ) async {
    final repository = _DeferredGisRepository();

    await tester.pumpWidget(
      MaterialApp(home: GisMapScreen(repository: repository)),
    );
    await tester.pump();

    expect(find.byType(FlutterMap), findsOneWidget);
    expect(repository.initializeCalls, 1);

    repository.completeInitialization();
    await tester.pump();
  });

  testWidgets('GPS centers without selecting the visible polygon', (
    WidgetTester tester,
  ) async {
    const feature = GisFeature(
      id: 'gps-feature',
      geometry: GisGeometry(
        type: 'Polygon',
        coordinates: [
          [
            [-60.2, -36.7],
            [-59.8, -36.7],
            [-59.8, -36.3],
            [-60.2, -36.3],
            [-60.2, -36.7],
          ],
        ],
      ),
      properties: <String, Object?>{
        'Nombre_UC': 'GPS unit',
        'SERIE1': 'Arroyo Dulce',
        'PORC1': '70%',
      },
      locality: '',
      soilMapId: 0,
    );
    final repository = _SingleFeatureGisRepository(feature);
    const locationService = _FakeGisLocationService(
      LatLng(-36.5, -60),
      accuracyMeters: 25,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: repository,
          locationService: locationService,
        ),
      ),
    );
    await _waitForMapTiles(tester);

    await tester.tap(find.byIcon(AppIcons.myLocation));
    await tester.pumpAndSettle();

    final state = tester.state(find.byType(GisMapScreen)) as dynamic;
    expect(state.currentLocationFeature?.id, feature.id);
    expect(find.byType(CircleLayer), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('GPS unit'), findsNothing);
  });

  testWidgets('follow location setting centers the map when it opens', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings.follow_location_automatically': true,
    });
    final settings = SettingsService.instance;
    await settings.initialize();
    const target = LatLng(-36.5, -60);

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'automatic-location-feature',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
          locationService: const _FakeGisLocationService(target),
        ),
      ),
    );
    await _waitForMapTiles(tester);
    await tester.pumpAndSettle();

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(
      map.mapController!.camera.center.latitude,
      closeTo(target.latitude, 0.001),
    );
    expect(
      map.mapController!.camera.center.longitude,
      closeTo(target.longitude, 0.001),
    );

    await settings.setFollowLocationAutomatically(false);
  });

  testWidgets('GPS accuracy remains meter-based and visible across zooms', (
    WidgetTester tester,
  ) async {
    const feature = GisFeature(
      id: 'gps-low-accuracy',
      geometry: GisGeometry(type: 'Polygon', coordinates: []),
      properties: <String, Object?>{},
      locality: '',
      soilMapId: 0,
    );
    const locationService = _FakeGisLocationService(
      LatLng(-36.5, -60),
      accuracyMeters: 1000000,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(feature),
          locationService: locationService,
        ),
      ),
    );
    await _waitForMapTiles(tester);

    await tester.tap(find.byIcon(AppIcons.myLocation));
    await tester.pumpAndSettle();

    expect(find.byType(MarkerLayer), findsOneWidget);
    expect(find.byType(CircleLayer), findsOneWidget);
    var circleLayer = tester.widget<CircleLayer>(find.byType(CircleLayer));
    expect(circleLayer.circles.single.radius, 1000000);
    expect(circleLayer.circles.single.useRadiusInMeter, isTrue);

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.move(map.mapController!.camera.center, 12);
    await tester.pump();

    expect(find.byType(CircleLayer), findsOneWidget);
    circleLayer = tester.widget<CircleLayer>(find.byType(CircleLayer));
    expect(circleLayer.circles.single.radius, 1000000);
    expect(circleLayer.circles.single.useRadiusInMeter, isTrue);

    await SettingsService.instance.setShowGpsAccuracyCircle(false);
    await tester.pump();
    expect(find.byType(CircleLayer), findsNothing);
    expect(find.byType(MarkerLayer), findsOneWidget);
    await SettingsService.instance.setShowGpsAccuracyCircle(true);
  });

  testWidgets('GIS compass appears on rotation and resets north', (
    WidgetTester tester,
  ) async {
    const feature = GisFeature(
      id: 'compass-feature',
      geometry: GisGeometry(type: 'Polygon', coordinates: []),
      properties: <String, Object?>{},
      locality: '',
      soilMapId: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: _SingleFeatureGisRepository(feature)),
      ),
    );
    await _waitForMapTiles(tester);

    expect(find.byTooltip('Restablecer norte'), findsNothing);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.rotate(35);
    await tester.pump();

    expect(find.byTooltip('Restablecer norte'), findsOneWidget);
    await tester.tap(find.byTooltip('Restablecer norte'));
    await tester.pumpAndSettle();

    expect(map.mapController!.camera.rotation, closeTo(0, 0.01));
    expect(find.byTooltip('Restablecer norte'), findsNothing);
  });

  testWidgets(
    'GIS zoom indicator uses friendly text and persisted visibility',
    (WidgetTester tester) async {
      const feature = GisFeature(
        id: 'zoom-indicator-feature',
        geometry: GisGeometry(type: 'Polygon', coordinates: []),
        properties: <String, Object?>{},
        locality: '',
        soilMapId: 0,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.show_zoom_level': true,
      });
      await SettingsService.instance.initialize();
      await tester.pumpWidget(
        const MaterialApp(
          home: GisMapScreen(repository: _SingleFeatureGisRepository(feature)),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(find.textContaining(RegExp(r'^Zoom \d+$')), findsOneWidget);
      expect(find.textContaining(RegExp(r'^Z\d')), findsNothing);

      await SettingsService.instance.setShowZoomLevel(false);
      await tester.pump();
      expect(find.textContaining('Zoom '), findsNothing);

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('settings.show_zoom_level'), isFalse);
      await SettingsService.instance.setShowZoomLevel(true);
    },
  );

  testWidgets('GIS map search returns the selected feature internally', (
    WidgetTester tester,
  ) async {
    const feature = GisFeature(
      id: 'search-feature',
      geometry: GisGeometry(
        type: 'Polygon',
        coordinates: [
          [
            [-60.2, -36.7],
            [-59.8, -36.7],
            [-59.8, -36.3],
            [-60.2, -36.3],
            [-60.2, -36.7],
          ],
        ],
      ),
      properties: <String, Object?>{'SERIE1': 'Arroyo Dulce', 'PORC1': '70%'},
      locality: '',
      soilMapId: 0,
    );
    final repository = _SingleFeatureGisRepository(feature);

    await tester.pumpWidget(
      MaterialApp(home: GisMapScreen(repository: repository)),
    );
    await _waitForMapTiles(tester);

    await tester.tap(find.byTooltip('Buscar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'dul');
    await tester.pumpAndSettle();

    expect(find.text('Arroyo Dulce'), findsOneWidget);

    await tester.tap(find.text('Arroyo Dulce'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(ListTile),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state(find.byType(GisMapScreen)) as dynamic;
    expect(state.searchSelectedFeature?.id, feature.id);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(map.mapController!.camera.zoom, 12);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Arroyo Dulce'), findsOneWidget);
    expect(find.text('70%'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Abrir PDF'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Abrir PDF'), findsOneWidget);
  });

  testWidgets('GIS map measures and clears a two-point distance', (
    WidgetTester tester,
  ) async {
    const feature = GisFeature(
      id: 'measurement-feature',
      geometry: GisGeometry(
        type: 'Polygon',
        coordinates: [
          [
            [-61, -37],
            [-59, -37],
            [-59, -36],
            [-61, -36],
            [-61, -37],
          ],
        ],
      ),
      properties: <String, Object?>{'Nombre_UC': 'Unidad medida'},
      locality: '',
      soilMapId: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: _SingleFeatureGisRepository(feature)),
      ),
    );
    await _waitForMapTiles(tester);

    await _selectMapTool(tester, 'Measure Distance');
    var map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -60),
    );
    await tester.pump();
    map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -59.999),
    );
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.byType(PolylineLayer), findsOneWidget);
    final firstDistance = tester
        .widget<Text>(find.byKey(const ValueKey('measurement-distance')))
        .data;
    expect(firstDistance, endsWith(' m'));

    map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -59.98),
    );
    await tester.pump();
    final updatedDistance = tester
        .widget<Text>(find.byKey(const ValueKey('measurement-distance')))
        .data;
    expect(updatedDistance, isNot(firstDistance));
    expect(updatedDistance, endsWith(' km'));
    expect(find.text('3'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('distance-vertex-gesture-1')),
      findsOneWidget,
    );
    final distanceBeforeDrag = tester
        .widget<Text>(find.byKey(const ValueKey('measurement-distance')))
        .data;
    final distanceVertexGesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('distance-vertex-gesture-1'))),
    );
    await distanceVertexGesture.moveBy(const Offset(35, -24));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('measurement-distance')))
          .data,
      isNot(distanceBeforeDrag),
    );
    await distanceVertexGesture.up();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.byTooltip('Limpiar medición'));
    await tester.pump();
    expect(find.byType(PolylineLayer), findsNothing);
    expect(find.byKey(const ValueKey('distance-vertex-0')), findsNothing);

    await _selectMapTool(tester, 'Exit Measurement');
    map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -60),
    );
    await tester.pump();
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      find.byKey(const ValueKey('selection-preview-measurement-feature')),
      findsOneWidget,
    );
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -60),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('selection-preview-measurement-feature')),
      findsNothing,
    );
    expect(find.text('Unidad medida'), findsOneWidget);
  });

  testWidgets('GIS measurement color updates and persists', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'measurement-color-feature',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);

    await _selectMapTool(tester, 'Measure Distance');

    var map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -60),
    );
    await tester.pump();
    map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -59.99),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Naranja'));
    await tester.pumpAndSettle();

    var lineLayer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
    expect(lineLayer.polylines.single.color, Colors.orange);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('settings.default_measurement_color'),
      'orange',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'measurement-color-feature-restored',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);
    await _selectMapTool(tester, 'Measure Distance');

    map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -60),
    );
    await tester.pump();
    map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -59.99),
    );
    await tester.pump();

    lineLayer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
    expect(lineLayer.polylines.single.color, Colors.orange);
  });

  testWidgets(
    'GIS measurement remains visible and resumes editing after exit',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        MaterialApp(
          home: GisMapScreen(
            repository: _SingleFeatureGisRepository(
              const GisFeature(
                id: 'measurement-exit-feature',
                geometry: GisGeometry(type: 'Polygon', coordinates: []),
                properties: <String, Object?>{},
                locality: '',
                soilMapId: 0,
              ),
            ),
          ),
        ),
      );
      await _waitForMapTiles(tester);

      Future<void> selectMode(String label) async {
        final toolLabel = switch (label) {
          'Distancia' => 'Measure Distance',
          'Área' => 'Measure Area',
          'Salir de medición' => 'Exit Measurement',
          _ => label,
        };
        await _selectMapTool(tester, toolLabel);
      }

      Future<void> tapMap(LatLng point) async {
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), point);
        await tester.pump();
      }

      await selectMode('Distancia');
      await tapMap(const LatLng(-36.5, -60));
      await tapMap(const LatLng(-36.5, -59.99));
      expect(
        find.byKey(const ValueKey('measurement-distance')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Salir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('measurement-distance')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Salir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Descartar'));
      await tester.pumpAndSettle();
      await selectMode('Área');
      await tapMap(const LatLng(-36.5, -60));
      await tapMap(const LatLng(-36.5, -59.99));
      await tapMap(const LatLng(-36.49, -59.99));
      expect(find.byKey(const ValueKey('measurement-area')), findsOneWidget);

      await tester.tap(find.byTooltip('Salir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('measurement-area')), findsOneWidget);
      expect(find.byKey(const ValueKey('area-vertex-0')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Limpiar'));
      await tester.pump();
      expect(find.byKey(const ValueKey('measurement-area')), findsNothing);
    },
  );

  testWidgets('completed distance and area measurements can be persisted', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'saved-measurement-feature',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);

    Future<void> tapMap(LatLng point) async {
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), point);
      await tester.pump();
    }

    await _selectMapTool(tester, 'Measure Distance');
    await tapMap(const LatLng(-36.5, -60));
    await tapMap(const LatLng(-36.5, -59.99));
    await tester.tap(find.byTooltip('Naranja'));
    await tester.pump();
    expect(find.byKey(const ValueKey('save-measurement')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-measurement')));
    await tester.pump();
    expect(find.text('Medición guardada.'), findsOneWidget);
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    expect(
      find.text('¿Querés guardar esta medición antes de salir?'),
      findsNothing,
    );

    await _selectMapTool(tester, 'Measure Area');
    await tapMap(const LatLng(-36.5, -60));
    await tapMap(const LatLng(-36.5, -59.99));
    await tapMap(const LatLng(-36.49, -59.99));
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Guardar'),
      ),
    );
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    final encoded =
        preferences.getStringList(SavedMeasurement.storageKey) ?? const [];
    final measurements = encoded
        .map(
          (value) => SavedMeasurement.fromJson(
            jsonDecode(value) as Map<String, Object?>,
          ),
        )
        .toList();

    expect(measurements, hasLength(2));
    expect(measurements.first.type, SavedMeasurementType.distance);
    expect(measurements.first.name, 'Distancia 1');
    expect(measurements.first.geometry, hasLength(2));
    expect(measurements.first.distanceMeters, greaterThan(0));
    expect(measurements.first.areaSquareMeters, isNull);
    expect(measurements.first.colorId, 'orange');
    expect(measurements.last.type, SavedMeasurementType.area);
    expect(measurements.last.name, 'Área 1');
    expect(measurements.last.geometry, hasLength(3));
    expect(measurements.last.areaSquareMeters, greaterThan(0));
    expect(measurements.last.perimeterMeters, greaterThan(0));
    expect(measurements.every((item) => item.id.isNotEmpty), isTrue);
  });

  testWidgets('discarding a new measurement removes all temporary geometry', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'discard-measurement-feature',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);
    await _selectMapTool(tester, 'Measure Distance');
    var map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -60),
    );
    map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -59.99),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('measurement-distance')), findsNothing);
    expect(find.byKey(const ValueKey('distance-vertex-0')), findsNothing);
    await _selectMapTool(tester, 'Measure Distance');
    expect(find.byKey(const ValueKey('distance-vertex-0')), findsNothing);
  });

  testWidgets('saved area geometry opens the existing editor', (
    WidgetTester tester,
  ) async {
    final measurement = SavedMeasurement(
      id: 'border-only-area',
      type: SavedMeasurementType.area,
      name: 'Área 1',
      geometry: const [
        LatLng(-37, -61),
        LatLng(-37, -59),
        LatLng(-36, -59),
        LatLng(-36, -61),
      ],
      createdAt: DateTime.utc(2026, 7, 2),
      areaSquareMeters: 10000,
      perimeterMeters: 500,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedMeasurement.storageKey: [jsonEncode(measurement.toJson())],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'soil-under-measurement',
              geometry: GisGeometry(
                type: 'Polygon',
                coordinates: [
                  [
                    [-61, -37],
                    [-59, -37],
                    [-59, -36],
                    [-61, -36],
                    [-61, -37],
                  ],
                ],
              ),
              properties: <String, Object?>{'Nombre_UC': 'Suelo interior'},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);
    await tester.pumpAndSettle();

    var map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final interior = const LatLng(-36.5, -60);
    final interiorOffset = map.mapController!.camera.latLngToScreenOffset(
      interior,
    );
    map.options.onTap!(TapPosition(interiorOffset, interiorOffset), interior);
    await tester.pump();
    expect(find.byKey(const ValueKey('area-vertex-0')), findsNothing);
    expect(
      find.byKey(const ValueKey('selection-preview-soil-under-measurement')),
      findsOneWidget,
    );

    map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final border = const LatLng(-36.5, -61);
    final borderOffset = map.mapController!.camera.latLngToScreenOffset(border);
    map.options.onTap!(TapPosition(borderOffset, borderOffset), border);
    await tester.pump();
    expect(find.byKey(const ValueKey('area-vertex-0')), findsOneWidget);
  });

  testWidgets('saved measurements load as non-editable map overlays', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final createdAt = DateTime.utc(2026, 7, 2);
    final saved = [
      SavedMeasurement(
        id: 'saved-distance',
        type: SavedMeasurementType.distance,
        name: 'Distancia 1',
        geometry: const [
          LatLng(-36.5, -60),
          LatLng(-36.5, -59.99),
          LatLng(-36.49, -59.98),
        ],
        createdAt: createdAt,
        distanceMeters: 2150,
      ),
      SavedMeasurement(
        id: 'saved-area',
        type: SavedMeasurementType.area,
        name: 'Área 1',
        geometry: const [
          LatLng(-36.5, -60),
          LatLng(-36.5, -59.99),
          LatLng(-36.49, -59.99),
        ],
        createdAt: createdAt,
        areaSquareMeters: 12500,
        perimeterMeters: 480,
      ),
      SavedMeasurement(
        id: 'hidden-distance',
        type: SavedMeasurementType.distance,
        name: 'Distancia oculta',
        geometry: const [LatLng(-36.4, -60), LatLng(-36.4, -59.99)],
        createdAt: createdAt,
        distanceMeters: 900,
        isVisible: false,
      ),
    ];
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedMeasurement.storageKey: [
        for (final measurement in saved) jsonEncode(measurement.toJson()),
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'saved-measurement-overlay-feature',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('saved-measurement-saved-distance')),
      findsNothing,
    );
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.move(const LatLng(-36.5, -60), 12);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('saved-measurement-saved-distance')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('saved-measurement-saved-area')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('saved-measurement-hidden-distance')),
      findsNothing,
    );
    final distanceLabelRect = tester.getRect(
      find.byKey(const ValueKey('saved-measurement-saved-distance')),
    );
    final areaLabelRect = tester.getRect(
      find.byKey(const ValueKey('saved-measurement-saved-area')),
    );
    expect(distanceLabelRect.overlaps(areaLabelRect), isFalse);
    expect(find.textContaining('2.1 km'), findsOneWidget);
    expect(find.textContaining('1.3 ha'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hide-saved-measurement-saved-distance')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('hide-saved-measurement-saved-area')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('distance-vertex-0')), findsNothing);
    expect(find.byKey(const ValueKey('area-vertex-0')), findsNothing);

    await tester.sendEventToBinding(
      PointerHoverEvent(position: areaLabelRect.center),
    );
    await tester.pump();
    final hoveredArea = tester
        .widgetList<PolygonLayer>(find.byType(PolygonLayer))
        .expand((layer) => layer.polygons)
        .firstWhere((polygon) => polygon.points.length == 3);
    expect(hoveredArea.borderStrokeWidth, 4.5);
    await tester.tap(
      find.byKey(const ValueKey('select-saved-measurement-saved-area')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('area-vertex-0')), findsNothing);
    expect(
      find.byKey(const ValueKey('analyze-selected-measurement')),
      findsOneWidget,
    );
    await _tapSavedMeasurementEditAction(tester);
    expect(find.byKey(const ValueKey('area-vertex-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-measurement')), findsOneWidget);
    final selectedLabel = tester.widget<Container>(
      find.byKey(const ValueKey('saved-measurement-saved-area')),
    );
    final selectedDecoration = selectedLabel.decoration! as BoxDecoration;
    expect(selectedDecoration.border, isNotNull);
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('select-saved-measurement-saved-distance')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('analyze-selected-measurement')),
      findsNothing,
    );
    await _tapSavedMeasurementEditAction(tester);
    expect(find.byKey(const ValueKey('distance-vertex-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-measurement')), findsOneWidget);
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('hide-saved-measurement-saved-distance')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('distance-vertex-0')), findsNothing);
    expect(find.byKey(const ValueKey('save-measurement')), findsNothing);
    expect(
      find.byKey(const ValueKey('saved-measurement-saved-distance')),
      findsNothing,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('measurements manager renames and deletes saved measurements', (
    WidgetTester tester,
  ) async {
    final measurements = [
      SavedMeasurement(
        id: 'managed-area',
        type: SavedMeasurementType.area,
        name: 'Área 1',
        geometry: const [
          LatLng(-36.5, -60),
          LatLng(-36.5, -59.99),
          LatLng(-36.49, -59.99),
        ],
        createdAt: DateTime.utc(2026, 7, 2, 14, 30),
        areaSquareMeters: 12500,
        perimeterMeters: 480,
      ),
      SavedMeasurement(
        id: 'managed-distance',
        type: SavedMeasurementType.distance,
        name: 'Distancia 1',
        geometry: const [LatLng(-36.5, -60), LatLng(-36.5, -59.99)],
        createdAt: DateTime.utc(2026, 7, 1, 9),
        distanceMeters: 2150,
      ),
    ];
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedMeasurement.storageKey: [
        for (final measurement in measurements)
          jsonEncode(measurement.toJson()),
      ],
    });

    await tester.pumpWidget(const MaterialApp(home: MeasurementsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Área 1'), findsOneWidget);
    expect(find.textContaining('1.3 ha'), findsOneWidget);
    expect(find.textContaining('02/07/2026'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('rename-measurement-managed-area')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Lote norte',
    );
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Lote norte'), findsOneWidget);

    await tester.tap(find.text('Distancias'));
    await tester.pumpAndSettle();
    expect(find.text('Distancia 1'), findsOneWidget);
    expect(find.text('2.1 km'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('measurement-overflow-managed-distance')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar').last);
    await tester.pumpAndSettle();
    expect(find.text('¿Eliminar medición?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Eliminar'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Todavía no hay distancias'), findsOneWidget);

    final preferences = await SharedPreferences.getInstance();
    final encoded =
        preferences.getStringList(SavedMeasurement.storageKey) ?? const [];
    expect(encoded, hasLength(1));
    final remaining = SavedMeasurement.fromJson(
      jsonDecode(encoded.single) as Map<String, Object?>,
    );
    expect(remaining.name, 'Lote norte');
  });

  testWidgets(
    'measurements manager persists individual and global visibility',
    (WidgetTester tester) async {
      final measurements = [
        SavedMeasurement(
          id: 'visibility-area',
          type: SavedMeasurementType.area,
          name: 'Área visible',
          geometry: const [
            LatLng(-36.5, -60),
            LatLng(-36.5, -59.99),
            LatLng(-36.49, -59.99),
          ],
          createdAt: DateTime.utc(2026, 7, 2),
          areaSquareMeters: 12000,
          perimeterMeters: 450,
        ),
        SavedMeasurement(
          id: 'visibility-distance',
          type: SavedMeasurementType.distance,
          name: 'Distancia visible',
          geometry: const [LatLng(-36.5, -60), LatLng(-36.5, -59.99)],
          createdAt: DateTime.utc(2026, 7, 2),
          distanceMeters: 850,
        ),
      ];
      SharedPreferences.setMockInitialValues(<String, Object>{
        SavedMeasurement.storageKey: [
          for (final measurement in measurements)
            jsonEncode(measurement.toJson()),
        ],
      });
      await tester.pumpWidget(const MaterialApp(home: MeasurementsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('visibility-measurement-visibility-area')),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Mostrar'), findsOneWidget);

      var preferences = await SharedPreferences.getInstance();
      var stored = preferences
          .getStringList(SavedMeasurement.storageKey)!
          .map(
            (value) => SavedMeasurement.fromJson(
              jsonDecode(value) as Map<String, Object?>,
            ),
          )
          .toList();
      expect(stored.first.isVisible, isFalse);
      expect(stored.last.isVisible, isTrue);

      await tester.tap(find.byTooltip('Visibilidad de mediciones'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ocultar todas'));
      await tester.pumpAndSettle();
      preferences = await SharedPreferences.getInstance();
      stored = preferences
          .getStringList(SavedMeasurement.storageKey)!
          .map(
            (value) => SavedMeasurement.fromJson(
              jsonDecode(value) as Map<String, Object?>,
            ),
          )
          .toList();
      expect(stored.every((measurement) => !measurement.isVisible), isTrue);

      await tester.tap(find.byTooltip('Visibilidad de mediciones'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mostrar todas'));
      await tester.pumpAndSettle();
      preferences = await SharedPreferences.getInstance();
      stored = preferences
          .getStringList(SavedMeasurement.storageKey)!
          .map(
            (value) => SavedMeasurement.fromJson(
              jsonDecode(value) as Map<String, Object?>,
            ),
          )
          .toList();
      expect(stored.every((measurement) => measurement.isVisible), isTrue);
    },
  );

  testWidgets('GIS measurements action centers and highlights a saved area', (
    WidgetTester tester,
  ) async {
    final measurement = SavedMeasurement(
      id: 'gis-managed-area',
      type: SavedMeasurementType.area,
      name: 'Lote sur',
      geometry: const [
        LatLng(-34.62, -58.48),
        LatLng(-34.62, -58.46),
        LatLng(-34.60, -58.46),
      ],
      createdAt: DateTime.utc(2026, 7, 2),
      areaSquareMeters: 18000,
      perimeterMeters: 620,
      colorId: 'orange',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedMeasurement.storageKey: [jsonEncode(measurement.toJson())],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'measurements-action-feature',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Abrir marcadores personales'), findsOneWidget);
    expect(find.byTooltip('Abrir mediciones'), findsOneWidget);
    expect(find.byTooltip('Buscar'), findsOneWidget);
    await tester.tap(find.byTooltip('Abrir mediciones'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(MeasurementsScreen),
        matching: find.text('Lote sur'),
      ),
    );
    await tester.pumpAndSettle();

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(map.mapController!.camera.center.latitude, closeTo(-34.61, 0.02));
    expect(map.mapController!.camera.center.longitude, closeTo(-58.47, 0.02));
    expect(find.byKey(const ValueKey('area-vertex-0')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('select-saved-measurement-gis-managed-area')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('area-vertex-0')), findsNothing);
    await _tapSavedMeasurementEditAction(tester);
    expect(find.byKey(const ValueKey('area-vertex-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-measurement')), findsOneWidget);
    expect(find.byTooltip('Ocultar'), findsOneWidget);
    expect(find.byTooltip('Eliminar medición'), findsOneWidget);
    final selectedAreas = tester
        .widgetList<PolygonLayer>(find.byType(PolygonLayer))
        .expand((layer) => layer.polygons)
        .where((polygon) => polygon.points.length == 3)
        .toList();
    expect(
      selectedAreas.any(
        (polygon) =>
            polygon.color == Colors.orange.withValues(alpha: 0.42) &&
            polygon.borderStrokeWidth == 6,
      ),
      isTrue,
    );
    expect(
      selectedAreas.any(
        (polygon) => polygon.color == Colors.orange.withValues(alpha: 0.25),
      ),
      isTrue,
    );

    await tester.tap(find.byTooltip('Ocultar'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('saved-measurement-gis-managed-area')),
      findsNothing,
    );
    await tester.pumpAndSettle();
    final preferences = await SharedPreferences.getInstance();
    final stored = SavedMeasurement.fromJson(
      jsonDecode(preferences.getStringList(SavedMeasurement.storageKey)!.single)
          as Map<String, Object?>,
    );
    expect(stored.isVisible, isFalse);
  });

  testWidgets('GIS creates, persists, and opens a personal marker', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'personal-marker-feature',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);

    await _selectMapTool(tester, 'Markers');
    expect(find.text('Toque el mapa para marcar.'), findsOneWidget);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-34.6037, -58.3816),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nuevo marcador'), findsOneWidget);
    expect(find.text('Modo de marcador activo.'), findsOneWidget);
    await tester.tap(find.text('Guardar'));
    await tester.pump();
    expect(find.text('Requerido'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('personal-marker-name')),
      'Lote norte',
    );
    await tester.enterText(
      find.byKey(const ValueKey('personal-marker-description')),
      'Muestra de referencia',
    );
    await tester.tap(find.byKey(const ValueKey('personal-marker-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Muestreo').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    expect(find.text('Modo de marcador activo.'), findsNothing);

    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getStringList('gis.personal_markers');
    expect(stored, hasLength(1));
    expect(stored!.single, contains('"name":"Lote norte"'));
    expect(stored.single, contains('"category":"sampling"'));

    final markerFinder = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'personal-marker-',
          ),
    );
    expect(markerFinder, findsOneWidget);
    await tester.tap(markerFinder);
    await tester.pumpAndSettle();

    expect(find.text('Lote norte'), findsOneWidget);
    expect(find.text('Muestra de referencia'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('personal-marker-coordinates')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('personal-marker-created-at')),
      findsOneWidget,
    );
    expect(find.text('Muestreo'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit-personal-marker')));
    await tester.pumpAndSettle();
    expect(find.text('Editar marcador'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('personal-marker-name')),
      'Lote editado',
    );
    await tester.enterText(
      find.byKey(const ValueKey('personal-marker-description')),
      'Descripcion actualizada',
    );
    await tester.tap(find.byKey(const ValueKey('personal-marker-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calicata').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    final editedStored = preferences.getStringList('gis.personal_markers');
    expect(editedStored, hasLength(1));
    expect(editedStored!.single, contains('"name":"Lote editado"'));
    expect(
      editedStored.single,
      contains('"description":"Descripcion actualizada"'),
    );
    expect(editedStored.single, contains('"category":"soil_pit"'));

    await tester.tap(find.byTooltip('Abrir marcadores personales'));
    await tester.pumpAndSettle();
    expect(find.byType(PersonalMarkersScreen), findsOneWidget);
    await tester.tap(find.text('Lote editado'));
    await tester.pumpAndSettle();

    final returnedMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(
      returnedMap.mapController!.camera.center.latitude,
      closeTo(-34.6037, 0.000001),
    );
    expect(
      returnedMap.mapController!.camera.center.longitude,
      closeTo(-58.3816, 0.000001),
    );
    expect(find.text('Lote editado'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-personal-marker')));
    await tester.pumpAndSettle();
    expect(find.text('¿Eliminar marcador?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Eliminar'),
      ),
    );
    await tester.pumpAndSettle();

    expect(markerFinder, findsNothing);
    expect(preferences.getStringList('gis.personal_markers'), isEmpty);
  });

  testWidgets('GIS map measures area with undo and clear actions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'area-feature',
              geometry: GisGeometry(
                type: 'Polygon',
                coordinates: [
                  [
                    [-60.01, -36.51],
                    [-59.98, -36.51],
                    [-59.98, -36.48],
                    [-60.01, -36.48],
                    [-60.01, -36.51],
                  ],
                ],
              ),
              properties: <String, Object?>{
                'SIMBC': 'An1',
                'SERIE1': 'Analisis',
                'CAP_USO': 'II',
              },
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);

    await _selectMapTool(tester, 'Measure Area');

    for (final point in const [
      LatLng(-36.5, -60),
      LatLng(-36.5, -59.99),
      LatLng(-36.49, -59.99),
    ]) {
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), point);
      await tester.pump();
    }

    expect(find.byType(PolygonLayer), findsOneWidget);
    expect(find.byKey(const ValueKey('measurement-area')), findsOneWidget);
    expect(find.textContaining('ha'), findsOneWidget);
    expect(find.byKey(const ValueKey('measurement-perimeter')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('measurement-perimeter')))
          .data,
      endsWith('km'),
    );
    expect(find.byType(BottomSheet), findsNothing);

    expect(find.byKey(const ValueKey('analyze-parcel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('analyze-parcel')));
    await tester.pump();
    expect(find.text('Análisis del lote'), findsOneWidget);
    expect(find.text('Superficie'), findsOneWidget);
    expect(find.text('Perímetro'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('parcel-analysis-loading')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parcel-analysis-ready')), findsOneWidget);
    final dynamic mapState = tester.state(find.byType(GisMapScreen));
    final analysis = mapState.latestParcelAnalysis;
    expect(analysis.intersections, isNotEmpty);
    expect(analysis.intersections.first.featureId, 'area-feature');
    expect(analysis.intersections.first.unitSymbol, 'An1');
    expect(analysis.intersections.first.dominantSoilSeries, 'Analisis');
    expect(analysis.intersections.first.capabilityClass, 'II');
    expect(analysis.intersections.first.areaSquareMeters, greaterThan(0));
    expect(analysis.soilComposition, hasLength(1));
    expect(analysis.soilComposition.first.unitSymbol, 'An1');
    expect(analysis.soilComposition.first.areaHectares, greaterThan(0));
    expect(analysis.soilComposition.first.percentage, closeTo(100, 0.2));
    expect(analysis.dominantSoilUnit, 'An1');
    expect(analysis.dominantSoilSeries, 'Analisis');
    expect(analysis.dominantCapabilityClass, 'II');
    expect(find.text('Composición del lote'), findsOneWidget);
    expect(find.text('Serie dominante'), findsWidgets);
    expect(find.text('Capacidad de uso dominante'), findsOneWidget);

    Navigator.of(tester.element(find.text('Análisis del lote'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Deshacer último punto'));
    await tester.pump();
    expect(find.byType(PolygonLayer), findsNothing);
    expect(find.byKey(const ValueKey('measurement-area')), findsNothing);

    await tester.tap(find.byTooltip('Limpiar medición'));
    await tester.pump();
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);

    await _selectMapTool(tester, 'Exit Measurement');
    expect(find.byTooltip('Deshacer último punto'), findsNothing);
  });

  testWidgets('GIS area measurement validates and edits vertices', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'editable-area',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);
    await _selectMapTool(tester, 'Measure Area');
    tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .move(const LatLng(-36.495, -59.995), 14);
    await tester.pump();

    Future<void> addPoint(LatLng point, {Offset? relative}) async {
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.options.onTap!(TapPosition(relative ?? Offset.zero, relative), point);
      await tester.pump();
    }

    await addPoint(const LatLng(-36.5, -60));
    await addPoint(const LatLng(-36.49, -59.99));
    await addPoint(const LatLng(-36.49, -60));
    await addPoint(const LatLng(-36.5, -59.99));

    dynamic state = tester.state(find.byType(GisMapScreen));
    expect(state.areaMeasurementPoints, hasLength(3));
    expect(find.text('El polígono no puede cruzarse.'), findsOneWidget);

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    const edgePoint = LatLng(-36.495, -59.995);
    final edgeOffset = map.mapController!.camera.latLngToScreenOffset(
      edgePoint,
    );
    await addPoint(edgePoint, relative: edgeOffset);
    state = tester.state(find.byType(GisMapScreen));
    expect(state.areaMeasurementPoints, hasLength(4));

    final initialVertex = state.areaMeasurementPoints[1] as LatLng;
    final initialArea = tester
        .widget<Text>(find.byKey(const ValueKey('measurement-area')))
        .data;
    final initialMapCenter = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera
        .center;
    final vertexGesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('area-vertex-gesture-1'))),
    );
    await tester.pump();
    var mapDuringDrag = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(
      InteractiveFlag.hasDrag(mapDuringDrag.options.interactionOptions.flags),
      isFalse,
    );

    await vertexGesture.moveBy(const Offset(45, -30));
    await tester.pump();
    state = tester.state(find.byType(GisMapScreen));
    expect(state.areaMeasurementPoints[1], isNot(initialVertex));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('measurement-area'))).data,
      isNot(initialArea),
    );
    expect(mapDuringDrag.mapController!.camera.center, initialMapCenter);

    await vertexGesture.up();
    await tester.pump();
    mapDuringDrag = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(
      InteractiveFlag.hasDrag(mapDuringDrag.options.interactionOptions.flags),
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('area-vertex-gesture-1')));
    await tester.pumpAndSettle();
    final deleteVertexItem = tester.widget<PopupMenuItem<dynamic>>(
      find.byKey(const ValueKey('delete-area-vertex')),
    );
    expect(deleteVertexItem.enabled, isTrue);
    await tester.tapAt(tester.getCenter(find.text('Eliminar vértice')));
    await tester.pumpAndSettle();
    await tester.pump();
    state = tester.state(find.byType(GisMapScreen));
    expect(state.areaMeasurementPoints, hasLength(3));

    await tester.tap(find.byKey(const ValueKey('area-vertex-gesture-1')));
    await tester.pumpAndSettle();
    final deleteItem = tester.widget<PopupMenuItem<dynamic>>(
      find.ancestor(
        of: find.text('Eliminar vértice'),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      ),
    );
    expect(deleteItem.enabled, isFalse);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Deshacer'), findsOneWidget);
    expect(find.byTooltip('Limpiar'), findsOneWidget);
    expect(find.byTooltip('Salir'), findsOneWidget);
  });

  testWidgets('GIS invalidates parcel analysis when its polygon changes', (
    WidgetTester tester,
  ) async {
    final repository = _DeferredParcelAnalysisRepository();
    await tester.pumpWidget(
      MaterialApp(home: GisMapScreen(repository: repository)),
    );
    await _waitForMapTiles(tester);

    await _selectMapTool(tester, 'Measure Area');

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    for (final point in const [
      LatLng(-36.5, -60),
      LatLng(-36.5, -59.99),
      LatLng(-36.49, -59.99),
    ]) {
      map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), point);
      await tester.pump();
    }

    await tester.tap(find.byKey(const ValueKey('analyze-parcel')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('parcel-analysis-loading')),
      findsOneWidget,
    );
    expect(repository.analysisLoadCalls, greaterThan(0));

    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.49, -60),
    );
    repository.completeAnalysisLoads();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('parcel-analysis-invalidated')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('parcel-analysis-ready')), findsNothing);
    final dynamic mapState = tester.state(find.byType(GisMapScreen));
    expect(mapState.latestParcelAnalysis, isNull);
  });

  testWidgets('GIS map search includes and ranks unit symbols', (
    WidgetTester tester,
  ) async {
    const features = <GisFeature>[
      GisFeature(
        id: 'contains-symbol',
        geometry: GisGeometry(
          type: 'Polygon',
          coordinates: [
            [
              [-61.2, -36.7],
              [-60.8, -36.7],
              [-60.8, -36.3],
              [-61.2, -36.3],
              [-61.2, -36.7],
            ],
          ],
        ),
        properties: <String, Object?>{
          'SIMBC': 'XJu18',
          'Nombre_UC': 'Complejo contenido',
          'SERIE1': 'Rojas',
        },
        locality: '',
        soilMapId: 0,
      ),
      GisFeature(
        id: 'prefix-symbol',
        geometry: GisGeometry(
          type: 'Polygon',
          coordinates: [
            [
              [-60.7, -36.7],
              [-60.3, -36.7],
              [-60.3, -36.3],
              [-60.7, -36.3],
              [-60.7, -36.7],
            ],
          ],
        ),
        properties: <String, Object?>{
          'SIMBC': 'Ju180',
          'Nombre_UC': 'Complejo prefijo',
          'SERIE1': 'Pergamino',
        },
        locality: '',
        soilMapId: 0,
      ),
      GisFeature(
        id: 'exact-symbol',
        geometry: GisGeometry(
          type: 'Polygon',
          coordinates: [
            [
              [-60.2, -36.7],
              [-59.8, -36.7],
              [-59.8, -36.3],
              [-60.2, -36.3],
              [-60.2, -36.7],
            ],
          ],
        ),
        properties: <String, Object?>{
          'SIMBC': 'Ju18',
          'Nombre_UC': 'Complejo Junín 18',
          'SERIE1': 'Junín',
        },
        locality: '',
        soilMapId: 0,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: _MultiFeatureGisRepository(features)),
      ),
    );
    await _waitForMapTiles(tester);

    await tester.tap(find.byTooltip('Buscar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'ju18');
    await tester.pumpAndSettle();

    expect(find.text('Complejo Junín 18'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Ju18')).dy,
      lessThan(tester.getTopLeft(find.text('Ju180')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Ju180')).dy,
      lessThan(tester.getTopLeft(find.text('XJu18')).dy),
    );

    await tester.tap(find.text('Ju18'));
    await tester.pumpAndSettle();

    final state = tester.state(find.byType(GisMapScreen)) as dynamic;
    expect(state.searchSelectedFeature?.id, 'exact-symbol');
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Complejo Junín 18'), findsOneWidget);
  });

  testWidgets('GIS search groups results and orders series units', (
    WidgetTester tester,
  ) async {
    const features = <GisFeature>[
      GisFeature(
        id: 'unit-b',
        geometry: GisGeometry(
          type: 'Polygon',
          coordinates: [
            [
              [-61.2, -36.7],
              [-60.8, -36.7],
              [-60.8, -36.3],
              [-61.2, -36.3],
              [-61.2, -36.7],
            ],
          ],
        ),
        properties: <String, Object?>{
          'SIMBC': 'B2',
          'Nombre_UC': 'Unidad B',
          'SERIE1': 'Junín',
          'PORC1': '50',
        },
        locality: 'Pergamino',
        soilMapId: 0,
      ),
      GisFeature(
        id: 'unit-a',
        geometry: GisGeometry(
          type: 'Polygon',
          coordinates: [
            [
              [-60.7, -36.7],
              [-60.3, -36.7],
              [-60.3, -36.3],
              [-60.7, -36.3],
              [-60.7, -36.7],
            ],
          ],
        ),
        properties: <String, Object?>{
          'SIMBC': 'A1',
          'Nombre_UC': 'Unidad A',
          'SERIE1': 'Junín',
          'PORC1': '50',
        },
        locality: 'Junín',
        soilMapId: 0,
      ),
      GisFeature(
        id: 'unit-c',
        geometry: GisGeometry(
          type: 'Polygon',
          coordinates: [
            [
              [-60.2, -36.7],
              [-59.8, -36.7],
              [-59.8, -36.3],
              [-60.2, -36.3],
              [-60.2, -36.7],
            ],
          ],
        ),
        properties: <String, Object?>{
          'SIMBC': 'C3',
          'Nombre_UC': 'Unidad C',
          'SERIE1': 'Junín',
          'PORC1': '70',
        },
        locality: 'Chacabuco',
        soilMapId: 0,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: _MultiFeatureGisRepository(features)),
      ),
    );
    await _waitForMapTiles(tester);

    await tester.tap(find.byTooltip('Buscar'));
    await tester.pumpAndSettle();
    expect(find.text('Localidades'), findsOneWidget);
    expect(find.text('Unidades cartográficas'), findsOneWidget);
    expect(find.text('Series de suelo'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'junin');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Junín').last);
    await tester.pumpAndSettle();

    expect(find.text('Serie: Junín'), findsOneWidget);
    expect(find.text('3 unidades cartográficas'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('C3')).dy,
      lessThan(tester.getTopLeft(find.text('A1')).dy),
    );
    expect(
      tester.getTopLeft(find.text('A1')).dy,
      lessThan(tester.getTopLeft(find.text('B2')).dy),
    );
    expect(find.text('70%'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('70%'), matching: find.byType(Chip)),
      findsOneWidget,
    );

    await tester.tap(find.text('C3'));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(GisMapScreen)) as dynamic;
    expect(state.searchSelectedFeature?.id, 'unit-c');
    expect(find.text('Unidad C'), findsOneWidget);
  });

  testWidgets('GIS bottom sheet toggles and persists a favorite feature', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const feature = GisFeature(
      id: 'favorite-feature',
      geometry: GisGeometry(
        type: 'Polygon',
        coordinates: [
          [
            [-60.2, -36.7],
            [-59.8, -36.7],
            [-59.8, -36.3],
            [-60.2, -36.3],
            [-60.2, -36.7],
          ],
        ],
      ),
      properties: <String, Object?>{
        'Nombre_UC': 'Favorite unit',
        'SERIE1': 'Arroyo Dulce',
        'PDF': 'favorite.pdf',
      },
      locality: '',
      soilMapId: 0,
    );
    final repository = _SingleFeatureGisRepository(feature);

    await tester.pumpWidget(
      MaterialApp(home: GisMapScreen(repository: repository)),
    );
    await _waitForMapTiles(tester);

    await _selectMapSearchResult(tester, 'arroyo', 'Arroyo Dulce');
    await tester.tap(find.byTooltip('Agregar a favoritos'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    final favorites = preferences.getStringList('gis.favorite_soil_features');

    expect(find.byTooltip('Quitar de favoritos'), findsOneWidget);
    expect(favorites, isNotNull);
    expect(favorites!.single, contains('favorite-feature'));
    expect(favorites.single, contains('Favorite unit'));
    expect(favorites.single, contains('Arroyo Dulce'));
    expect(favorites.single, contains('favorite.pdf'));
  });

  testWidgets('GIS favorite reuses search centering and selection workflow', (
    WidgetTester tester,
  ) async {
    const feature = GisFeature(
      id: 'favorite-feature',
      geometry: GisGeometry(
        type: 'Polygon',
        coordinates: [
          [
            [-60.2, -36.7],
            [-59.8, -36.7],
            [-59.8, -36.3],
            [-60.2, -36.3],
            [-60.2, -36.7],
          ],
        ],
      ),
      properties: <String, Object?>{
        'Nombre_UC': 'Unidad favorita',
        'SERIE1': 'Arroyo Dulce',
        'PORC1': '70%',
      },
      locality: '',
      soilMapId: 0,
    );
    final favorite = FavoriteSoilFeature(
      id: feature.id,
      unitName: 'Unidad favorita',
      unitSymbol: 'UF1',
      soilSeries: const ['Arroyo Dulce'],
      pdfIdentifier: null,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      FavoriteSoilFeature.storageKey: <String>[jsonEncode(favorite.toJson())],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(repository: _SingleFeatureGisRepository(feature)),
      ),
    );
    await _waitForMapTiles(tester);

    await _selectMapTool(tester, 'Favorites');
    await tester.tap(find.text('Unidad favorita'));
    await tester.pumpAndSettle();

    final state = tester.state(find.byType(GisMapScreen)) as dynamic;
    expect(state.searchSelectedFeature?.id, feature.id);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Unidad favorita'), findsOneWidget);
  });

  testWidgets('GIS reports a favorite whose feature is unavailable', (
    WidgetTester tester,
  ) async {
    final favorite = FavoriteSoilFeature(
      id: 'missing-feature',
      unitName: 'Unidad eliminada',
      unitSymbol: 'UE1',
      soilSeries: const ['Serie eliminada'],
      pdfIdentifier: null,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      FavoriteSoilFeature.storageKey: <String>[jsonEncode(favorite.toJson())],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: GisMapScreen(
          repository: _SingleFeatureGisRepository(
            const GisFeature(
              id: 'available-feature',
              geometry: GisGeometry(type: 'Polygon', coordinates: []),
              properties: <String, Object?>{},
              locality: '',
              soilMapId: 0,
            ),
          ),
        ),
      ),
    );
    await _waitForMapTiles(tester);

    await _selectMapTool(tester, 'Favorites');
    await tester.tap(find.text('Unidad eliminada'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Este favorito ya no está disponible.'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('GIS map search recenters on consecutive selections', (
    WidgetTester tester,
  ) async {
    const features = <GisFeature>[
      GisFeature(
        id: 'search-feature-1',
        geometry: GisGeometry(
          type: 'Polygon',
          coordinates: [
            [
              [-60.2, -36.7],
              [-59.8, -36.7],
              [-59.8, -36.3],
              [-60.2, -36.3],
              [-60.2, -36.7],
            ],
          ],
        ),
        properties: <String, Object?>{'SERIE1': 'Arroyo Dulce'},
        locality: '',
        soilMapId: 0,
      ),
      GisFeature(
        id: 'search-feature-2',
        geometry: GisGeometry(
          type: 'Polygon',
          coordinates: [
            [
              [-59.2, -35.7],
              [-58.8, -35.7],
              [-58.8, -35.3],
              [-59.2, -35.3],
              [-59.2, -35.7],
            ],
          ],
        ),
        properties: <String, Object?>{'SERIE1': 'Pergamino'},
        locality: '',
        soilMapId: 0,
      ),
      GisFeature(
        id: 'search-feature-3',
        geometry: GisGeometry(
          type: 'Polygon',
          coordinates: [
            [
              [-61.2, -37.7],
              [-60.8, -37.7],
              [-60.8, -37.3],
              [-61.2, -37.3],
              [-61.2, -37.7],
            ],
          ],
        ),
        properties: <String, Object?>{'SERIE1': 'Azul'},
        locality: '',
        soilMapId: 0,
      ),
    ];
    final repository = _MultiFeatureGisRepository(features);

    await tester.pumpWidget(
      MaterialApp(home: GisMapScreen(repository: repository)),
    );
    await _waitForMapTiles(tester);

    await _selectMapSearchResult(tester, 'arroyo', 'Arroyo Dulce');
    await _expectMapCenter(tester, const LatLng(-36.5, -60));

    await _selectMapSearchResult(tester, 'per', 'Pergamino');
    await _expectMapCenter(tester, const LatLng(-35.5, -59));

    await _selectMapSearchResult(tester, 'az', 'Azul');
    await _expectMapCenter(tester, const LatLng(-37.5, -61));

    await _selectMapSearchResult(tester, 'arroyo', 'Arroyo Dulce');
    await _expectMapCenter(tester, const LatLng(-36.5, -60));

    await _selectMapSearchResult(tester, 'per', 'Pergamino');
    await _expectMapCenter(tester, const LatLng(-35.5, -59));
  });

  testWidgets('GIS rendered tile cache evicts LRU tiles and reloads them', (
    WidgetTester tester,
  ) async {
    final repository = _CountingTileGisRepository();
    await tester.pumpWidget(
      MaterialApp(home: GisMapScreen(repository: repository)),
    );
    await _waitForMapTiles(tester);

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final initialCoordinates = repository.loadCounts.keys.toSet();
    for (var index = 0; index < 18; index++) {
      map.mapController!.move(LatLng(-36, -170 + index * 20), 8);
      await tester.pump(const Duration(milliseconds: 200));
      await _waitForMapTiles(tester);
    }

    final dynamic state = tester.state(find.byType(GisMapScreen));
    expect(
      state.renderedTileCacheSize,
      lessThanOrEqualTo(state.maxRenderedTileCacheEntries),
    );
    expect(state.searchIndexSize, greaterThan(state.renderedTileCacheSize * 3));

    final initialSearchCoordinates = initialCoordinates.first;
    final initialLocality =
        'Localidad ${initialSearchCoordinates.zoom}-'
        '${initialSearchCoordinates.x}-${initialSearchCoordinates.y}';
    final initialLoadCountBeforeReturn = initialCoordinates.fold<int>(
      0,
      (count, coordinates) => count + (repository.loadCounts[coordinates] ?? 0),
    );
    await tester.tap(find.byTooltip('Buscar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, initialLocality);
    await tester.pumpAndSettle();
    await tester.tap(find.text(initialLocality).last);
    await tester.pumpAndSettle();
    await _expectMapCenter(tester, const LatLng(-36.5, -60));
    if (find.byType(BottomSheet).evaluate().isNotEmpty) {
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
    }
    map.mapController!.move(const LatLng(-36.5, -60), 7);
    await tester.pump(const Duration(milliseconds: 200));
    await _waitForMapTiles(tester);
    final initialLoadCountAfterReturn = initialCoordinates.fold<int>(
      0,
      (count, coordinates) => count + (repository.loadCounts[coordinates] ?? 0),
    );
    expect(
      initialLoadCountAfterReturn,
      greaterThan(initialLoadCountBeforeReturn),
    );
  });

  testWidgets('Home launcher opens and filters soil memories', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const SuelosARApp());
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/logoapp.png',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Cartografía de Suelos de la Provincia de Buenos Aires'),
      findsOneWidget,
    );
    expect(find.text('Mapa de Suelos'), findsOneWidget);
    expect(find.text('Cartas de Suelo'), findsOneWidget);
    expect(find.byKey(const ValueKey('module-favorites')), findsNothing);
    expect(find.text('Marcadores'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('module-settings')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Configuración'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('module-soil-maps')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('module-soil-maps')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(find.text('Memorias descriptivas'), findsWidgets);
    expect(find.byIcon(AppIcons.search), findsOneWidget);
    expect(find.text('Buscar carta de suelo...'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), 'Jun');
    await tester.pump(const Duration(milliseconds: 100));

    final juninTile = find.ancestor(
      of: find.text('Junín'),
      matching: find.byType(ListTile),
    );
    expect(juninTile, findsOneWidget);
    expect(
      find.descendant(
        of: juninTile,
        matching: find.text('Disponible sin conexión'),
      ),
      findsNothing,
    );
    await tester.tap(
      find.descendant(of: juninTile, matching: find.byIcon(AppIcons.star)),
    );
    await tester.pump();
    expect(find.text('Favoritos (1)'), findsOneWidget);
    expect(
      find.descendant(
        of: juninTile,
        matching: find.byIcon(Icons.picture_as_pdf),
      ),
      findsNothing,
    );

    await tester.enterText(find.byType(SearchBar), 'Villa Ca');
    await tester.pump(const Duration(milliseconds: 100));

    final villaCanasTile = find.ancestor(
      of: find.text('Villa Cañás'),
      matching: find.byType(ListTile),
    );
    expect(villaCanasTile, findsOneWidget);
    expect(
      find.descendant(
        of: villaCanasTile,
        matching: find.byIcon(Icons.picture_as_pdf),
      ),
      findsNothing,
    );

    await tester.enterText(find.byType(SearchBar), 'sin resultados posibles');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('No se encontraron cartas de suelo'), findsOneWidget);
  });

  testWidgets('Home layout stays balanced across responsive sizes', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const viewports = <Size>[
      Size(360, 640),
      Size(768, 900),
      Size(1280, 800),
      Size(1920, 1080),
    ];

    for (final viewport in viewports) {
      tester.view.physicalSize = viewport;
      await tester.pumpWidget(const SuelosARApp());
      await tester.pump();

      expect(tester.takeException(), isNull, reason: '$viewport overflowed');

      final mainCard = find.byKey(const ValueKey('module-gis-map'));
      final mainContent = find.byKey(const ValueKey('primary-card-content'));
      final soilMapsCard = find.byKey(const ValueKey('module-soil-maps'));
      final markersCard = find.byKey(const ValueKey('module-personal-markers'));
      final mainRect = tester.getRect(mainCard);

      expect(mainRect.width, lessThanOrEqualTo(640.1));
      expect(mainRect.width, lessThanOrEqualTo(viewport.width - 40 + 0.1));
      expect(
        (tester.getCenter(mainContent).dx - mainRect.center.dx).abs(),
        lessThan(1),
      );
      expect(
        find.descendant(
          of: mainCard,
          matching: find.byIcon(AppIcons.chevronRight),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: soilMapsCard,
          matching: find.byIcon(AppIcons.chevronRight),
        ),
        findsOneWidget,
      );

      final soilMapsRect = tester.getRect(soilMapsCard);
      final markersRect = tester.getRect(markersCard);
      if (viewport.width < 660) {
        expect(soilMapsRect.width, closeTo(mainRect.width, 0.1));
        expect(markersRect.top, greaterThan(soilMapsRect.bottom));
      } else {
        expect(soilMapsRect.width, closeTo(markersRect.width, 0.1));
        expect(soilMapsRect.top, closeTo(markersRect.top, 0.1));
      }
    }
  });
}

class _DeferredGisRepository implements GisRepository {
  final Completer<GisArchiveInfo> _initialization = Completer<GisArchiveInfo>();
  int initializeCalls = 0;

  void completeInitialization() {
    if (_initialization.isCompleted) {
      return;
    }

    _initialization.complete(
      const GisArchiveInfo(
        minZoom: 4,
        maxZoom: 14,
        centerLatitude: -36.5,
        centerLongitude: -60,
      ),
    );
  }

  @override
  Future<GisArchiveInfo> initialize() {
    initializeCalls++;
    return _initialization.future;
  }

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async {
    await _initialization.future;
    return GisLayer(
      id: 'empty-${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
      name: AssetPaths.gisLayerName,
      features: const <Never>[],
    );
  }

  @override
  Future<void> close() async {}
}

class _SingleFeatureGisRepository implements GisRepository {
  const _SingleFeatureGisRepository(this.feature);

  final GisFeature feature;

  @override
  Future<GisArchiveInfo> initialize() async {
    return const GisArchiveInfo(
      minZoom: 4,
      maxZoom: 14,
      centerLatitude: -36.5,
      centerLongitude: -60,
    );
  }

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async {
    return GisLayer(
      id: 'single-${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
      name: AssetPaths.gisLayerName,
      features: <GisFeature>[feature],
    );
  }

  @override
  Future<void> close() async {}
}

class _MultiFeatureGisRepository implements GisRepository {
  const _MultiFeatureGisRepository(this.features);

  final List<GisFeature> features;

  @override
  Future<GisArchiveInfo> initialize() async {
    return const GisArchiveInfo(
      minZoom: 4,
      maxZoom: 14,
      centerLatitude: -36.5,
      centerLongitude: -60,
    );
  }

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async {
    return GisLayer(
      id: 'multi-${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
      name: AssetPaths.gisLayerName,
      features: features,
    );
  }

  @override
  Future<void> close() async {}
}

class _DeferredParcelAnalysisRepository implements GisRepository {
  final Completer<void> _analysisLoads = Completer<void>();
  int analysisLoadCalls = 0;

  void completeAnalysisLoads() {
    if (!_analysisLoads.isCompleted) {
      _analysisLoads.complete();
    }
  }

  @override
  Future<GisArchiveInfo> initialize() async {
    return const GisArchiveInfo(
      minZoom: 4,
      maxZoom: 14,
      centerLatitude: -36.5,
      centerLongitude: -60,
    );
  }

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async {
    if (coordinates.zoom == 14) {
      analysisLoadCalls++;
      await _analysisLoads.future;
    }
    return GisLayer(
      id: 'parcel-${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
      name: AssetPaths.gisLayerName,
      features: const <GisFeature>[],
    );
  }

  @override
  Future<void> close() async {}
}

class _CountingTileGisRepository implements GisRepository {
  final Map<GisTileCoordinates, int> loadCounts = <GisTileCoordinates, int>{};

  @override
  Future<GisArchiveInfo> initialize() async {
    return const GisArchiveInfo(
      minZoom: 4,
      maxZoom: 14,
      centerLatitude: -36.5,
      centerLongitude: -60,
    );
  }

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async {
    loadCounts.update(coordinates, (count) => count + 1, ifAbsent: () => 1);
    final suffix = '${coordinates.zoom}-${coordinates.x}-${coordinates.y}';
    return GisLayer(
      id: 'counting-$suffix',
      name: AssetPaths.gisLayerName,
      features: <GisFeature>[
        GisFeature(
          id: 'feature-$suffix',
          geometry: const GisGeometry(
            type: 'Polygon',
            coordinates: [
              [
                [-60.01, -36.51],
                [-59.99, -36.51],
                [-59.99, -36.49],
                [-60.01, -36.49],
                [-60.01, -36.51],
              ],
            ],
          ),
          properties: <String, Object?>{
            'SIMBC': 'U-$suffix',
            'SERIE1': 'Serie $suffix',
          },
          locality: 'Localidad $suffix',
          soilMapId: 0,
        ),
      ],
    );
  }

  @override
  Future<void> close() async {}
}

class _FakeGisLocationService implements GisLocationService {
  const _FakeGisLocationService(this.point, {this.accuracyMeters});

  final LatLng point;
  final double? accuracyMeters;

  @override
  Future<GisLocation> getCurrentLocation() async {
    return GisLocation(point: point, accuracyMeters: accuracyMeters);
  }
}

Future<void> _selectMapSearchResult(
  WidgetTester tester,
  String query,
  String result,
) async {
  if (find.byType(BottomSheet).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
  }

  await tester.tap(find.byTooltip('Buscar'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, query);
  await tester.pumpAndSettle();
  await tester.tap(find.text(result).last);
  await tester.pumpAndSettle();
  final seriesUnitRows = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.byType(ListTile),
  );
  if (seriesUnitRows.evaluate().isNotEmpty) {
    await tester.tap(seriesUnitRows.first);
    await tester.pumpAndSettle();
  }
}

Future<void> _expectMapCenter(WidgetTester tester, LatLng expected) async {
  final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
  final center = map.mapController!.camera.center;
  expect(center.latitude, closeTo(expected.latitude, 0.0001));
  expect(center.longitude, closeTo(expected.longitude, 0.0001));
}

Future<void> _waitForMapTiles(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      return;
    }
  }
  fail('Timed out waiting for GIS tiles.');
}

Future<void> _tapSavedMeasurementEditAction(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Más acciones'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Editar').last);
  await tester.pumpAndSettle();
}

Future<void> _selectMapTool(WidgetTester tester, String label) async {
  final toolLabel = switch (label) {
    'Measure Distance' => 'Medir distancia',
    'Measure Area' => 'Medir área',
    'Exit Measurement' => 'Salir de medición',
    'Markers' => 'Marcadores',
    'Favorites' => 'Favoritos',
    _ => throw ArgumentError.value(label, 'label', 'Unsupported map tool'),
  };
  await tester.tap(find.byTooltip('Herramientas'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip(toolLabel));
  await tester.pumpAndSettle();
  if (label == 'Exit Measurement' &&
      find
          .text('¿Querés guardar esta medición antes de salir?')
          .evaluate()
          .isNotEmpty) {
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
  }
}
