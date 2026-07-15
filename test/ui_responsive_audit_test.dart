import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/models/saved_measurement.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/screens/favorites_screen.dart';
import 'package:suelosar/screens/home_screen.dart';
import 'package:suelosar/screens/measurements_screen.dart';
import 'package:suelosar/screens/personal_markers_screen.dart';
import 'package:suelosar/screens/settings_screen.dart';
import 'package:suelosar/screens/soil_maps_screen.dart';
import 'package:suelosar/widgets/floating_app_bar_card.dart';
import 'package:suelosar/widgets/responsive_desktop_shell.dart';

void main() {
  for (final entry in <String, Widget>{
    'home': const HomeScreen(),
    'settings': const SettingsScreen(),
    'favorites': const FavoritesScreen(),
    'soil maps': const SoilMapsScreen(),
    'personal markers': const PersonalMarkersScreen(),
  }.entries) {
    testWidgets('${entry.key} fits a narrow phone with enlarged text', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _pumpNarrowScreen(tester, entry.value);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('measurements actions fit a narrow phone with enlarged text', (
    tester,
  ) async {
    final measurement = SavedMeasurement(
      id: 'responsive-area',
      type: SavedMeasurementType.area,
      name: 'Área extensa de prueba',
      geometry: const <LatLng>[
        LatLng(-36.5, -60),
        LatLng(-36.5, -59.9),
        LatLng(-36.4, -59.9),
      ],
      createdAt: DateTime.utc(2026, 7, 12),
      areaSquareMeters: 12000,
      perimeterMeters: 500,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedMeasurement.storageKey: <String>[jsonEncode(measurement.toJson())],
    });

    await _pumpNarrowScreen(tester, const MeasurementsScreen());
    expect(tester.takeException(), isNull);
    final overflow = find.byKey(
      const ValueKey('measurement-overflow-responsive-area'),
    );
    await tester.ensureVisible(overflow);
    await tester.pumpAndSettle();
    await tester.tap(overflow);
    await tester.pumpAndSettle();
    final exportItem = tester.getRect(find.text('Exportar GeoJSON'));
    expect(exportItem.left, greaterThanOrEqualTo(0));
    expect(exportItem.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('personal marker dialog fits above the mobile keyboard', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const GisMapScreen(repository: _EmptyGisRepository()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Herramientas'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Marcadores'));
    await tester.pumpAndSettle();

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -60),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump();

    expect(find.byKey(const ValueKey('personal-marker-name')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('area measurement panel fits a narrow phone', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: const GisMapScreen(repository: _EmptyGisRepository()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Herramientas'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Medir área'));
    await tester.pumpAndSettle();

    const points = <LatLng>[
      LatLng(-36.5, -60),
      LatLng(-36.5, -59.99),
      LatLng(-36.49, -59.99),
    ];
    for (final point in points) {
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), point);
      await tester.pump();
    }

    expect(find.byKey(const ValueKey('measurement-area')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared floating header stays below the top safe inset', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pump();

    final headerTop = tester
        .getTopLeft(find.byType(FloatingAppBarCard).first)
        .dy;
    expect(headerTop, greaterThanOrEqualTo(56));
    expect(tester.takeException(), isNull);
  });

  testWidgets('about problem report card fits a narrow phone', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _pumpNarrowScreen(tester, const AboutSuelosArScreen());

    final reportButton = find.text('Enviar reporte');
    await tester.scrollUntilVisible(
      reportButton,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Reportar un problema'), findsOneWidget);
    expect(reportButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('layers menu remains inside a narrow viewport', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: _EmptyGisRepository())),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Capas'));
    await tester.pumpAndSettle();

    final menuRect = tester.getRect(find.text('Polígonos de suelo'));
    expect(menuRect.left, greaterThanOrEqualTo(0));
    expect(menuRect.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact GIS header actions animate in sync with its title', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(350, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: _EmptyGisRepository())),
    );
    await tester.pump(const Duration(seconds: 1));
    final clearActionElement = tester.element(
      find.byKey(
        const ValueKey('compact-map-header-clear-button'),
        skipOffstage: false,
      ),
    );
    double actionCardWidth() =>
        tester.getSize(find.byType(FloatingAppBarCard).last).width;
    final initialActionWidth = actionCardWidth();

    Future<void> selectMapTool(String tooltip) async {
      tester
          .widget<InkWell>(
            find
                .descendant(
                  of: find.byTooltip('Herramientas'),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap!();
      await tester.pumpAndSettle();
      tester
          .widget<InkWell>(
            find
                .descendant(
                  of: find.byTooltip(tooltip),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap!();
      await tester.pump();
    }

    double transitionOpacity(String key) => tester
        .widget<Opacity>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;

    await selectMapTool('Medir distancia');
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -60),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    final enteringTitle = transitionOpacity('map-header-title-transition');
    final enteringAction = transitionOpacity('map-header-clear-transition');
    final enteringActionWidth = actionCardWidth();
    expect(enteringTitle, inExclusiveRange(0, 1));
    expect(enteringAction, inExclusiveRange(0, 1));
    expect(enteringTitle + enteringAction, closeTo(1, 0.04));
    expect(
      tester.element(
        find.byKey(
          const ValueKey('compact-map-header-clear-button'),
          skipOffstage: false,
        ),
      ),
      same(clearActionElement),
    );
    await tester.pumpAndSettle();
    final expandedActionWidth = actionCardWidth();
    expect(enteringActionWidth, greaterThan(initialActionWidth));
    expect(enteringActionWidth, lessThan(expandedActionWidth));

    tester
        .widget<IconButton>(
          find
              .descendant(
                of: find.byKey(const ValueKey('map-header-clear-transition')),
                matching: find.byType(IconButton),
              )
              .first,
        )
        .onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    final exitingTitle = transitionOpacity('map-header-title-transition');
    final exitingAction = transitionOpacity('map-header-clear-transition');
    final exitingActionWidth = actionCardWidth();
    expect(exitingTitle, inExclusiveRange(0, 1));
    expect(exitingAction, inExclusiveRange(0, 1));
    expect(exitingTitle + exitingAction, closeTo(1, 0.04));
    expect(enteringTitle + exitingTitle, closeTo(1, 0.04));
    expect(enteringAction + exitingAction, closeTo(1, 0.04));
    expect(exitingActionWidth, greaterThan(initialActionWidth));
    expect(exitingActionWidth, lessThan(expandedActionWidth));
    await tester.pumpAndSettle();
    expect(transitionOpacity('map-header-title-transition'), 1);
    expect(actionCardWidth(), closeTo(initialActionWidth, 0.01));
    expect(
      tester.element(
        find.byKey(
          const ValueKey('compact-map-header-clear-button'),
          skipOffstage: false,
        ),
      ),
      same(clearActionElement),
    );
  });

  testWidgets('GIS desktop shell keeps map controls in a floating side panel', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const GisMapScreen(repository: _EmptyGisRepository()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Navegación GIS'), findsOneWidget);
    expect(find.text('Mediciones'), findsOneWidget);
    expect(find.text('Buscar'), findsOneWidget);
    expect(find.text('Sin conexión'), findsNothing);
    expect(find.textContaining('Zoom '), findsWidgets);
    final expandedWidth = tester
        .getSize(find.byType(SuelosArFloatingSidePanel))
        .width;
    await tester.tap(find.byTooltip('Contraer herramientas'));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(SuelosArFloatingSidePanel)).width,
      lessThan(expandedWidth),
    );
    expect(find.byKey(const ValueKey('desktop-map-navigation-rail')), findsOne);
    expect(find.byKey(const ValueKey('desktop-map-rail-layers')), findsOne);
    expect(find.byKey(const ValueKey('desktop-map-rail-search')), findsOne);
    expect(
      find.byKey(const ValueKey('desktop-map-rail-measurements')),
      findsOne,
    );
    expect(find.byKey(const ValueKey('desktop-map-rail-markers')), findsOne);
    expect(find.byKey(const ValueKey('desktop-map-rail-favorites')), findsOne);
    expect(find.byKey(const ValueKey('desktop-map-rail-location')), findsOne);
    await tester.tap(find.byKey(const ValueKey('desktop-map-rail-layers')));
    await tester.pumpAndSettle();
    expect(find.text('Capas'), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-map-navigation-rail')), findsOne);
    await tester.tap(find.byTooltip('Expandir herramientas'));
    await tester.pumpAndSettle();
    expect(find.text('Navegación GIS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop search opens in the right contextual panel', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const GisMapScreen(repository: _EmptyGisRepository()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Contraer herramientas'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('desktop-map-rail-search')));
    await tester.pumpAndSettle();

    final searchField = find.byKey(const ValueKey('desktop-map-search-field'));
    expect(searchField, findsOneWidget);
    expect(tester.getCenter(searchField).dx, greaterThan(900));
    expect(
      find.text('Escribí una localidad, unidad cartográfica o serie de suelo.'),
      findsOneWidget,
    );
    expect(find.text('Búsquedas recientes'), findsOneWidget);
    expect(find.text('Todavía no hay búsquedas recientes.'), findsOneWidget);
    expect(find.byTooltip('Cerrar panel'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop temporary modes share active state and cancellation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const GisMapScreen(repository: _EmptyGisRepository()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(
      find.byKey(const ValueKey('desktop-map-action-measure-distance')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Medir distancia'), findsWidgets);
    expect(find.text('Modo activo'), findsOneWidget);
    expect(find.byTooltip('Cancelar modo activo'), findsNothing);
    expect(find.byTooltip('Cerrar panel'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Modo activo'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('desktop-map-action-measure-area')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Medir área'), findsWidgets);
    await tester.tap(find.byTooltip('Cerrar panel'));
    await tester.pumpAndSettle();
    expect(find.text('Modo activo'), findsNothing);

    final addMarkerAction = find.byKey(
      const ValueKey('desktop-map-action-add-marker'),
    );
    await tester.ensureVisible(addMarkerAction);
    await tester.pumpAndSettle();
    await tester.tap(addMarkerAction);
    await tester.pumpAndSettle();
    expect(find.text('Agregar marcador'), findsWidgets);
    await tester.tap(find.byTooltip('Cerrar panel'));
    await tester.pumpAndSettle();
    expect(find.text('Modo activo'), findsNothing);
    expect(find.byTooltip('Cancelar modo activo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop secondary mouse only opens the vertex menu', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const GisMapScreen(repository: _EmptyGisRepository()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(
      find.byKey(const ValueKey('desktop-map-action-measure-area')),
    );
    await tester.pumpAndSettle();

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.move(const LatLng(-36.5, -60), 14);
    await tester.pump();
    for (final point in const <LatLng>[
      LatLng(-36.505, -60.005),
      LatLng(-36.495, -59.995),
      LatLng(-36.505, -59.995),
    ]) {
      map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), point);
      await tester.pump();
    }
    expect(tester.takeException(), isNull, reason: 'measurement setup');

    final vertex = find.byKey(const ValueKey('area-vertex-gesture-0'));
    expect(vertex, findsOneWidget);

    final mapCenterBefore = map.mapController!.camera.center;
    final rightMapDrag = await tester.startGesture(
      const Offset(700, 520),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightMapDrag.moveBy(const Offset(90, -45));
    await rightMapDrag.up();
    await tester.pump();
    expect(map.mapController!.camera.center, mapCenterBefore);
    expect(tester.takeException(), isNull, reason: 'secondary map drag');

    dynamic state = tester.state(find.byType(GisMapScreen));
    final vertexBefore = state.areaMeasurementPoints.first as LatLng;
    final rightVertexDrag = await tester.startGesture(
      tester.getCenter(vertex),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightVertexDrag.moveBy(const Offset(45, 30));
    await rightVertexDrag.up();
    await tester.pump();
    state = tester.state(find.byType(GisMapScreen));
    expect(state.areaMeasurementPoints.first, vertexBefore);
    expect(find.byKey(const ValueKey('delete-area-vertex')), findsNothing);
    expect(tester.takeException(), isNull, reason: 'secondary vertex drag');

    await tester.tap(vertex);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('delete-area-vertex')), findsNothing);
    expect(tester.takeException(), isNull, reason: 'primary vertex click');

    final rightClick = await tester.startGesture(
      tester.getCenter(vertex),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('delete-area-vertex')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow Windows GIS keeps the desktop shell', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(760, 700);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const GisMapScreen(repository: _EmptyGisRepository()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Navegación GIS'), findsOneWidget);
    expect(find.byTooltip('Herramientas'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GIS phone layout does not mount the desktop side panel', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: _EmptyGisRepository())),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Herramientas del mapa'), findsNothing);
    expect(find.byTooltip('Herramientas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop map controls are laid out before mouse interaction', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const GisMapScreen(repository: _EmptyGisRepository()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    _expectRenderBoxesLaidOut(tester, find.byType(InkWell));
    _expectRenderBoxesLaidOut(tester, find.byType(IconButton));
    await tester.sendEventToBinding(
      const PointerHoverEvent(position: Offset(48, 136)),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Contraer herramientas'));
    await tester.pump(const Duration(milliseconds: 90));
    _expectRenderBoxesLaidOut(tester, find.byType(InkWell));
    _expectRenderBoxesLaidOut(tester, find.byType(IconButton));
    await tester.sendEventToBinding(
      const PointerHoverEvent(position: Offset(48, 136)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

void _expectRenderBoxesLaidOut(WidgetTester tester, Finder finder) {
  for (final element in finder.evaluate()) {
    final renderObject = element.renderObject;
    if (renderObject is RenderBox) {
      expect(renderObject.hasSize, isTrue);
    }
  }
}

Future<void> _pumpNarrowScreen(WidgetTester tester, Widget screen) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: screen,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

class _EmptyGisRepository implements GisRepository {
  const _EmptyGisRepository();

  @override
  Future<GisArchiveInfo> initialize() async => const GisArchiveInfo(
    minZoom: 7,
    maxZoom: 14,
    centerLatitude: -36.5,
    centerLongitude: -60,
  );

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async => GisLayer(
    id: '${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
    name: 'empty',
    features: const [],
  );

  @override
  Future<void> close() async {}
}
