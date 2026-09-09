import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/gis/gis_feature.dart';
import 'package:suelosar/models/saved_measurement.dart';
import 'package:suelosar/models/soil_card.dart';
import 'package:suelosar/models/soil_map.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_render_metrics.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/models/favorite_soil_feature.dart';
import 'package:suelosar/models/personal_marker.dart';
import 'package:suelosar/screens/favorites_screen.dart';
import 'package:suelosar/screens/home_screen.dart';
import 'package:suelosar/screens/measurements_screen.dart';
import 'package:suelosar/screens/personal_markers_screen.dart';
import 'package:suelosar/screens/settings_screen.dart';
import 'package:suelosar/screens/soil_maps_screen.dart';
import 'package:suelosar/services/desktop_window_service.dart';
import 'package:suelosar/widgets/floating_app_bar_card.dart';
import 'package:suelosar/widgets/desktop_window_shortcut_scope.dart';
import 'package:suelosar/widgets/responsive_desktop_shell.dart';

void main() {
  for (final entry in <String, Widget>{
    'home': const HomeScreen(),
    'settings': const SettingsScreen(),
    'favorites': const FavoritesScreen(),
    // Stubbed loaders: this smoke test only checks that the layout doesn't
    // throw/overflow, never actual catalog content, so it doesn't need
    // real `rootBundle` reads — and leaving those real reads in flight when
    // the widget is torn down without waiting for them (this loop doesn't)
    // has been observed to wedge a later test's own real asset load in the
    // same process.
    'soil maps': SoilMapsScreen(
      soilMapsLoader: () async => const <SoilMap>[],
      santaFeCardsLoader: () async => const <SoilCard>[],
    ),
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

  testWidgets(
    'soil maps keeps a stable viewport while the Android keyboard animates',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      final navigatorObserver = _RecordingNavigatorObserver();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          navigatorObservers: [navigatorObserver],
          home: SoilMapsScreen(
            soilMapsLoader: () async => const <SoilMap>[
              SoilMap(name: 'Azul', pdf: 'Azul.pdf'),
            ],
            // Stubbed like soilMapsLoader above: this test is about keyboard
            // inset layout, not catalog content, and doesn't need a real
            // `rootBundle` read.
            santaFeCardsLoader: () async => const <SoilCard>[],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Todas las cartas'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final scrollable = find.byType(CustomScrollView);
      final initialHeight = tester.getSize(scrollable).height;
      await tester.tap(find.byType(SearchBar));
      await tester.enterText(find.byType(SearchBar), 'Azul');

      for (final inset in <double>[80, 180, 300, 440]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull);
      }

      expect(tester.getSize(scrollable).height, initialHeight);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('soil-maps-keyboard-clearance')))
            .height,
        464,
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Azul',
      );

      await tester.tap(find.widgetWithText(ListTile, 'Azul').first);
      expect(tester.testTextInput.isVisible, isFalse);
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (navigatorObserver.pushCount == 2) break;
      }
      expect(navigatorObserver.pushCount, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'soil maps fits the Android landscape keyboard without overflow',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(568, 320);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: SoilMapsScreen(
            soilMapsLoader: () async => const <SoilMap>[
              SoilMap(name: 'Azul', pdf: 'Azul.pdf'),
            ],
            santaFeCardsLoader: () async => const <SoilCard>[],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byType(SearchBar));

      for (final inset in <double>[80, 140, 180]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(SearchBar), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(
        tester.getSize(find.byType(CustomScrollView)).height,
        greaterThan(0),
      );

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(find.text('Cartas de suelo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'Android phone landscape moves only the upper GIS controls to the left',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(568, 320);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const GisMapScreen(repository: _EmptyGisRepository()),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.mapController!.rotate(15);
      await tester.pump();

      final landscapeLayers = tester.getRect(find.byTooltip('Capas'));
      final landscapeCompass = tester.getRect(
        find.byTooltip('Restablecer norte'),
      );
      final landscapeTools = tester.getRect(find.byTooltip('Herramientas'));
      final landscapeGps = tester.getRect(find.byTooltip('Mi ubicación'));
      expect(landscapeLayers.center.dx, lessThan(100));
      expect(landscapeCompass.center.dx, lessThan(100));
      expect(landscapeTools.center.dx, greaterThan(468));
      expect(landscapeGps.center.dx, greaterThan(468));

      await tester.tap(find.byTooltip('Herramientas'));
      await tester.pumpAndSettle();
      final topSearchAction = tester.getRect(find.byTooltip('Buscar'));
      for (final tooltip in const <String>[
        'Medir distancia',
        'Medir área',
        'Marcadores',
        'Favoritos',
      ]) {
        final toolRect = tester.getRect(find.byTooltip(tooltip));
        expect(
          topSearchAction.overlaps(toolRect),
          isFalse,
          reason: '$tooltip overlaps: $topSearchAction / $toolRect',
        );
      }
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(720, 360);
      await tester.pump();
      final wideLandscapeLayers = tester.getRect(find.byTooltip('Capas'));
      final wideLandscapeCompass = tester.getRect(
        find.byTooltip('Restablecer norte'),
      );
      final wideLandscapeSearch = tester.getRect(find.byTooltip('Buscar'));
      expect(wideLandscapeLayers.center.dx, lessThan(100));
      expect(wideLandscapeCompass.center.dx, lessThan(100));
      for (final tooltip in const <String>[
        'Medir distancia',
        'Medir área',
        'Marcadores',
        'Favoritos',
      ]) {
        expect(
          wideLandscapeSearch.overlaps(tester.getRect(find.byTooltip(tooltip))),
          isFalse,
        );
      }
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(360, 720);
      await tester.pump();
      final portraitLayers = tester.getRect(find.byTooltip('Capas'));
      final portraitCompass = tester.getRect(
        find.byTooltip('Restablecer norte'),
      );
      expect(portraitLayers.center.dx, greaterThan(260));
      expect(portraitCompass.center.dx, greaterThan(260));
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(960, 640);
      await tester.pump();
      final tabletLayers = tester.getRect(find.byTooltip('Capas'));
      final tabletCompass = tester.getRect(find.byTooltip('Restablecer norte'));
      expect(tabletLayers.center.dx, greaterThan(860));
      expect(tabletCompass.center.dx, greaterThan(860));
      expect(tester.takeException(), isNull);
    },
  );

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
    // "Mi ubicación" is deliberately NOT a rail entry any more: on the
    // desktop shell it moved out of the side panel into its own floating
    // bottom-right control, so it is asserted by tooltip rather than by a
    // `desktop-map-rail-location` key, which no longer exists.
    expect(find.byTooltip('Mi ubicación'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('desktop-map-rail-layers')));
    await tester.pumpAndSettle();
    expect(find.text('Capas'), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-map-navigation-rail')), findsOne);
    await tester.tap(find.byTooltip('Expandir herramientas'));
    await tester.pumpAndSettle();
    expect(find.text('Navegación GIS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop GIS fullscreen button and F11 share one service', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    final windowService = _FakeDesktopWindowService();
    final metrics = GisRenderMetrics();
    addTearDown(windowService.dispose);
    addTearDown(metrics.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: GisMapScreen(
          repository: const _EmptyGisRepository(),
          renderMetrics: metrics,
          desktopWindowService: windowService,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final mapElement = tester.element(find.byType(FlutterMap));
    final mapController = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController;
    metrics.reset();

    expect(find.byTooltip('Pantalla completa'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    await tester.tap(find.byTooltip('Pantalla completa'));
    await tester.pumpAndSettle();
    expect(windowService.toggleCount, 1);
    expect(find.byTooltip('Salir de pantalla completa'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(windowService.toggleCount, 2);
    expect(find.byTooltip('Pantalla completa'), findsOneWidget);

    windowService.updateNativeFullScreen(true);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Salir de pantalla completa'), findsOneWidget);
    windowService.updateNativeFullScreen(false);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Pantalla completa'), findsOneWidget);
    expect(windowService.toggleCount, 2);
    expect(tester.element(find.byType(FlutterMap)), same(mapElement));
    expect(
      tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController,
      same(mapController),
    );
    expect(metrics.mapBuildCount, 0);
    expect(metrics.tileCollectionBuildCount, 0);
    expect(metrics.polygonLayerBuildCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone GIS does not expose desktop fullscreen controls', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final windowService = _FakeDesktopWindowService();
    addTearDown(windowService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: GisMapScreen(
          repository: const _EmptyGisRepository(),
          desktopWindowService: windowService,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.byTooltip('Pantalla completa'), findsNothing);
    expect(find.byTooltip('Salir de pantalla completa'), findsNothing);
    expect(find.byIcon(Icons.fullscreen), findsNothing);
    expect(windowService.initializeCount, 0);
  });

  testWidgets('desktop Home exposes global window controls', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    final windowService = _FakeDesktopWindowService();
    addTearDown(windowService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: HomeScreen(
          deviceLinkedStatusLoader: () async => false,
          desktopWindowService: windowService,
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Pantalla completa (F11)'), findsOneWidget);
    expect(find.byTooltip('Cerrar SuelosAR'), findsOneWidget);
    await tester.tap(find.byTooltip('Pantalla completa (F11)'));
    await tester.pumpAndSettle();
    expect(windowService.toggleCount, 1);
    expect(find.byTooltip('Salir de pantalla completa (F11)'), findsOneWidget);

    await tester.tap(find.byTooltip('Cerrar SuelosAR'));
    await tester.pumpAndSettle();
    expect(find.text('Salir de SuelosAR'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(windowService.closeCount, 0);

    await tester.tap(find.byTooltip('Cerrar SuelosAR'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salir'));
    await tester.pumpAndSettle();
    expect(windowService.closeCount, 1);
  });

  testWidgets('global desktop shortcut toggles the shared window service', (
    tester,
  ) async {
    final windowService = _FakeDesktopWindowService();
    addTearDown(windowService.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopWindowShortcutScope(
          service: windowService,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(windowService.toggleCount, 1);
  });

  testWidgets('mobile Home does not build desktop window controls', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final windowService = _FakeDesktopWindowService();
    addTearDown(windowService.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: HomeScreen(
          deviceLinkedStatusLoader: () async => false,
          desktopWindowService: windowService,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('home-desktop-fullscreen')), findsNothing);
    expect(find.byKey(const ValueKey('home-desktop-exit')), findsNothing);
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

  testWidgets('desktop GIS collection panels filter their local lists', (
    tester,
  ) async {
    final measurements = <SavedMeasurement>[
      SavedMeasurement(
        id: 'campo-norte',
        type: SavedMeasurementType.area,
        name: 'Campo Norte',
        geometry: const [
          LatLng(-36.5, -60),
          LatLng(-36.5, -59.99),
          LatLng(-36.49, -59.99),
        ],
        createdAt: DateTime.utc(2026, 7, 1),
        areaSquareMeters: 12000,
        perimeterMeters: 450,
      ),
      SavedMeasurement(
        id: 'campo-sur',
        type: SavedMeasurementType.distance,
        name: 'Campo Sur',
        geometry: const [LatLng(-36.5, -60), LatLng(-36.49, -59.99)],
        createdAt: DateTime.utc(2026, 7, 2),
        distanceMeters: 850,
      ),
      SavedMeasurement(
        id: 'lote-este',
        type: SavedMeasurementType.area,
        name: 'Lote Este',
        geometry: const [
          LatLng(-36.5, -60),
          LatLng(-36.5, -59.98),
          LatLng(-36.48, -59.98),
        ],
        createdAt: DateTime.utc(2026, 7, 3),
        areaSquareMeters: 18000,
        perimeterMeters: 520,
      ),
    ];
    final markers = <PersonalMarker>[
      PersonalMarker(
        id: 'marker-north',
        latitude: -36.5,
        longitude: -60,
        name: 'Muestreo norte',
        description: 'Entrada principal',
        createdAt: DateTime.utc(2026, 7, 1),
      ),
      PersonalMarker(
        id: 'marker-lowland',
        latitude: -36.49,
        longitude: -59.99,
        name: 'Bajo sur',
        description: 'Sector anegado',
        createdAt: DateTime.utc(2026, 7, 2),
      ),
    ];
    final favorites = <FavoriteSoilFeature>[
      FavoriteSoilFeature(
        id: 'favorite-junin',
        unitName: 'Unidad JN',
        unitSymbol: 'JN',
        soilSeries: const ['Junín'],
        pdfIdentifier: 'junin',
      ),
      FavoriteSoilFeature(
        id: 'favorite-pergamino',
        unitName: 'Unidad PG',
        unitSymbol: 'PG',
        soilSeries: const ['Pergamino'],
        pdfIdentifier: 'pergamino',
      ),
    ];
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedMeasurement.storageKey: [
        for (final item in measurements) jsonEncode(item.toJson()),
      ],
      PersonalMarker.storageKey: [
        for (final item in markers) jsonEncode(item.toJson()),
      ],
      FavoriteSoilFeature.storageKey: [
        for (final item in favorites) jsonEncode(item.toJson()),
      ],
    });
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

    await tester.tap(
      find.byKey(const ValueKey('desktop-map-rail-measurements')),
    );
    await tester.pumpAndSettle();
    final measurementSearch = find.byKey(
      const ValueKey('desktop-measurements-search-field'),
    );
    await tester.enterText(measurementSearch, 'campo');
    await tester.pump();
    expect(find.text('Campo Norte'), findsOneWidget);
    expect(find.text('Campo Sur'), findsOneWidget);
    expect(find.text('Lote Este'), findsNothing);
    await tester.enterText(measurementSearch, 'sin coincidencias');
    await tester.pump();
    expect(find.text('No hay coincidencias.'), findsOneWidget);
    await tester.tap(find.byTooltip('Limpiar búsqueda'));
    await tester.pump();
    expect(find.text('Campo Norte'), findsOneWidget);
    expect(find.text('Campo Sur'), findsOneWidget);
    expect(find.text('Lote Este'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('desktop-map-rail-markers')));
    await tester.pumpAndSettle();
    final markerSearch = find.byKey(
      const ValueKey('desktop-markers-search-field'),
    );
    await tester.enterText(markerSearch, 'anegado');
    await tester.pump();
    expect(find.text('Bajo sur'), findsOneWidget);
    expect(find.text('Muestreo norte'), findsNothing);
    await tester.tap(find.byTooltip('Limpiar búsqueda'));
    await tester.pump();
    expect(find.text('Bajo sur'), findsOneWidget);
    expect(find.text('Muestreo norte'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('desktop-map-rail-favorites')));
    await tester.pumpAndSettle();
    final favoriteSearch = find.byKey(
      const ValueKey('desktop-favorites-search-field'),
    );
    await tester.enterText(favoriteSearch, 'junin');
    await tester.pump();
    expect(find.text('Junín'), findsOneWidget);
    expect(find.text('Pergamino'), findsNothing);
    await tester.tap(find.byTooltip('Limpiar búsqueda'));
    await tester.pump();
    expect(find.text('Junín'), findsOneWidget);
    expect(find.text('Pergamino'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('desktop-remove-favorite-favorite-junin')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('desktop-remove-favorite-favorite-junin')),
      findsNothing,
    );
    expect(find.text('Pergamino'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop selected soil unit shows its cartographic symbol', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);

    const feature = GisFeature(
      id: 'unit-with-symbol',
      geometry: GisGeometry(
        type: 'Polygon',
        coordinates: [
          [
            [-60.1, -36.6],
            [-59.9, -36.6],
            [-59.9, -36.4],
            [-60.1, -36.4],
            [-60.1, -36.6],
          ],
        ],
      ),
      properties: <String, Object?>{
        'Nombre_UC': 'Unidad cartográfica AC6',
        'CAP_USO': 'IIIes',
        'SIMBC': ' AC6 ',
      },
      locality: '',
      soilMapId: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const GisMapScreen(
          repository: _EmptyGisRepository(features: [feature]),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    const point = LatLng(-36.5, -60);
    final offset = map.mapController!.camera.latLngToScreenOffset(point);
    map.options.onTap!(TapPosition(offset, offset), point);
    await tester.pumpAndSettle();

    expect(find.text('Símbolo'), findsOneWidget);
    expect(find.text('AC6'), findsOneWidget);
    expect(find.text('Carta de suelo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop selected soil unit hides a missing symbol', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);

    const feature = GisFeature(
      id: 'unit-without-symbol',
      geometry: GisGeometry(
        type: 'Polygon',
        coordinates: [
          [
            [-60.1, -36.6],
            [-59.9, -36.6],
            [-59.9, -36.4],
            [-60.1, -36.4],
            [-60.1, -36.6],
          ],
        ],
      ),
      properties: <String, Object?>{
        'Nombre_UC': 'Unidad sin símbolo',
        'CAP_USO': 'IVs',
        'SIMBC': '   ',
      },
      locality: '',
      soilMapId: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const GisMapScreen(
          repository: _EmptyGisRepository(features: [feature]),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    const point = LatLng(-36.5, -60);
    final offset = map.mapController!.camera.latLngToScreenOffset(point);
    map.options.onTap!(TapPosition(offset, offset), point);
    await tester.pumpAndSettle();

    expect(find.text('Símbolo'), findsNothing);
    expect(find.text('Carta de suelo'), findsNothing);
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
    dynamic state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureDistance');
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      const LatLng(-36.5, -60),
    );
    await tester.pump();

    final addMarkerAction = find.byKey(
      const ValueKey('desktop-map-action-add-marker'),
    );
    await tester.ensureVisible(addMarkerAction);
    await tester.tap(addMarkerAction);
    await tester.pumpAndSettle();
    expect(
      find.text('¿Querés guardar los cambios antes de agregar un marcador?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'addMarker');
    expect(find.text('Agregar marcador'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey('desktop-map-action-measure-area')),
    );
    await tester.pumpAndSettle();
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureArea');

    await tester.tap(
      find.byKey(const ValueKey('desktop-map-action-measure-distance')),
    );
    await tester.pumpAndSettle();
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureDistance');

    await tester.tap(
      find.byKey(const ValueKey('desktop-map-action-measure-area')),
    );
    await tester.pumpAndSettle();
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureArea');

    await tester.ensureVisible(addMarkerAction);
    await tester.tap(addMarkerAction);
    await tester.pumpAndSettle();
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'addMarker');

    await tester.tap(
      find.byKey(const ValueKey('desktop-map-action-measure-distance')),
    );
    await tester.pumpAndSettle();
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureDistance');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Modo activo'), findsNothing);
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'none');

    await tester.tap(
      find.byKey(const ValueKey('desktop-map-action-measure-area')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Medir área'), findsWidgets);
    await tester.tap(find.byTooltip('Cerrar panel'));
    await tester.pumpAndSettle();
    expect(find.text('Modo activo'), findsNothing);

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

  testWidgets('phone temporary map tools are mutually exclusive', (
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

    Future<void> selectTool(String tooltip) async {
      await tester.tap(find.byTooltip('Herramientas'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
    }

    await selectTool('Medir distancia');
    dynamic state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureDistance');

    await selectTool('Marcadores');
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'addMarker');

    await selectTool('Medir área');
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureArea');

    await selectTool('Medir distancia');
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureDistance');

    await selectTool('Medir área');
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureArea');

    await selectTool('Marcadores');
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'addMarker');

    await selectTool('Medir distancia');
    state = tester.state(find.byType(GisMapScreen));
    expect(state.activeInteractionMode, 'measureDistance');
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
    final measureAreaAction = find.byKey(
      const ValueKey('desktop-map-action-measure-area'),
    );
    tester
        .widget<InkWell>(
          find.descendant(
            of: measureAreaAction,
            matching: find.byType(InkWell),
          ),
        )
        .onTap!();
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

class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount++;
    super.didPush(route, previousRoute);
  }
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
  const _EmptyGisRepository({this.features = const <GisFeature>[]});

  final List<GisFeature> features;

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
    features: features,
  );

  @override
  Future<void> close() async {}
}

class _FakeDesktopWindowService extends DesktopWindowService {
  bool _nativeFullScreen = false;
  int initializeCount = 0;
  int toggleCount = 0;
  int closeCount = 0;

  @override
  bool get isSupported => true;

  @override
  Future<bool> isFullScreen() async => _nativeFullScreen;

  @override
  bool get isTransitioning => false;

  @override
  Future<void> initialize() async {
    initializeCount++;
  }

  @override
  Future<void> enterFullScreen() async {
    if (_nativeFullScreen) return;
    _nativeFullScreen = true;
    notifyListeners();
  }

  @override
  Future<void> exitFullScreen() async {
    if (!_nativeFullScreen) return;
    _nativeFullScreen = false;
    notifyListeners();
  }

  @override
  Future<void> toggleFullScreen() async {
    toggleCount++;
    _nativeFullScreen = !_nativeFullScreen;
    notifyListeners();
  }

  void updateNativeFullScreen(bool value) {
    _nativeFullScreen = value;
    notifyListeners();
  }

  @override
  Future<void> closeWindow() async {
    closeCount++;
  }
}
