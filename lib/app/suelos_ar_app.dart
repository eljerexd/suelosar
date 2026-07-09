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

class SuelosARApp extends StatelessWidget {
  const SuelosARApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'SuelosAR',
        theme: AppTheme.light(reduceAnimations: settings.reduceAnimations),
        builder: (context, child) {
          final mediaQuery = MediaQuery.of(context);
          return MediaQuery(
            data: mediaQuery.copyWith(
              disableAnimations: settings.reduceAnimations,
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: const HomeScreen(),
        routes: {
          AppRoutes.gisMap: (_) => const GisMapScreen(),
          AppRoutes.favorites: (_) => const FavoritesScreen(openPdfOnTap: true),
          AppRoutes.soilMaps: (_) => const SoilMapsScreen(),
          AppRoutes.personalMarkers: (_) => const PersonalMarkersScreen(),
          AppRoutes.measurements: (_) => const MeasurementsScreen(),
          AppRoutes.settings: (_) => const SettingsScreen(),
        },
      ),
    );
  }
}
