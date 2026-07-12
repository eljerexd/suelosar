import 'package:flutter/material.dart';

import '../gis/gis_map_screen.dart';
import '../screens/favorites_screen.dart';
import '../screens/home_screen.dart';
import '../screens/measurements_screen.dart';
import '../screens/personal_markers_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/soil_maps_screen.dart';
import '../services/settings_service.dart';
import 'app_routes.dart';
import 'app_theme.dart';
import 'instant_pop_material_page_route.dart';

class SuelosARApp extends StatefulWidget {
  const SuelosARApp({super.key});

  @override
  State<SuelosARApp> createState() => _SuelosARAppState();
}

class _SuelosARAppState extends State<SuelosARApp> {
  final SettingsService _settings = SettingsService.instance;
  late bool _reduceAnimations;

  @override
  void initState() {
    super.initState();
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
      theme: AppTheme.light(reduceAnimations: _reduceAnimations),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(disableAnimations: _reduceAnimations),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const HomeScreen(),
      onGenerateRoute: (routeSettings) {
        final Widget? page = switch (routeSettings.name) {
          AppRoutes.gisMap => const GisMapScreen(),
          AppRoutes.favorites => const FavoritesScreen(openPdfOnTap: true),
          AppRoutes.soilMaps => const SoilMapsScreen(),
          AppRoutes.personalMarkers => const PersonalMarkersScreen(),
          AppRoutes.measurements => const MeasurementsScreen(),
          AppRoutes.settings => const SettingsScreen(),
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
