import 'dart:async';

import 'package:flutter/material.dart';

import '../gis/gis_map_screen.dart';
import '../gis/gis_map_occlusion_observer.dart';
import '../screens/favorites_screen.dart';
import '../screens/home_screen.dart';
import '../screens/measurements_screen.dart';
import '../screens/personal_markers_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/soil_maps_screen.dart';
import '../screens/synchronization_screen.dart';
import '../services/desktop_window_service.dart';
import '../services/settings_service.dart';
import '../widgets/desktop_window_shortcut_scope.dart';
import 'app_routes.dart';
import 'app_theme.dart';
import 'instant_pop_material_page_route.dart';

class SuelosARApp extends StatefulWidget {
  const SuelosARApp({this.desktopWindowService, super.key});

  final DesktopWindowService? desktopWindowService;

  @override
  State<SuelosARApp> createState() => _SuelosARAppState();
}

class _SuelosARAppState extends State<SuelosARApp> {
  final SettingsService _settings = SettingsService.instance;
  late final DesktopWindowService _desktopWindowService;
  late bool _reduceAnimations;

  @override
  void initState() {
    super.initState();
    _desktopWindowService =
        widget.desktopWindowService ?? DesktopWindowService.instance;
    unawaited(_desktopWindowService.initialize());
    _reduceAnimations = _settings.reduceAnimations;
    _settings.addListener(_handleSettingsChanged);
  }

  @override
  void dispose() {
    _settings.removeListener(_handleSettingsChanged);
    super.dispose();
  }

  void _handleSettingsChanged() {
    final nextValue = _settings.reduceAnimations;
    if (nextValue == _reduceAnimations) return;
    setState(() => _reduceAnimations = nextValue);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SuelosAR',
      navigatorObservers: <NavigatorObserver>[GisMapOcclusionObserver.instance],
      theme: AppTheme.light(reduceAnimations: _reduceAnimations),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        final content = MediaQuery(
          data: mediaQuery.copyWith(disableAnimations: _reduceAnimations),
          child: child ?? const SizedBox.shrink(),
        );
        return DesktopWindowShortcutScope(
          service: _desktopWindowService,
          child: content,
        );
      },
      home: HomeScreen(desktopWindowService: _desktopWindowService),
      onGenerateRoute: (routeSettings) {
        final Widget? page = switch (routeSettings.name) {
          AppRoutes.gisMap => GisMapScreen(
            desktopWindowService: _desktopWindowService,
          ),
          AppRoutes.favorites => const FavoritesScreen(),
          AppRoutes.soilMaps => const SoilMapsScreen(),
          AppRoutes.personalMarkers => const PersonalMarkersScreen(),
          AppRoutes.measurements => const MeasurementsScreen(),
          AppRoutes.settings => const SettingsScreen(),
          AppRoutes.synchronization => const SynchronizationScreen(),
          _ => null,
        };
        if (page == null) return null;
        return InstantPopMaterialPageRoute<void>(
          settings: routeSettings,
          builder: (_) => page,
        );
      },
    );
  }
}
