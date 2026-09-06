import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/models/personal_marker.dart';
import 'package:suelosar/screens/home_screen.dart';
import 'package:suelosar/screens/personal_markers_screen.dart';

void main() {
  testWidgets(
    'Tapping a saved marker from Home closes the picker and pushes GIS '
    'already targeting that marker, without opening its details panel',
    (tester) async {
      final marker = PersonalMarker(
        id: 'marker-1',
        latitude: -34.61,
        longitude: -58.38,
        name: 'Lote norte',
        description: 'Observación de prueba',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        PersonalMarker.storageKey: [jsonEncode(marker.toJson())],
      });

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('module-personal-markers')));
      await tester.pumpAndSettle();

      expect(find.byType(PersonalMarkersScreen), findsOneWidget);
      expect(find.text('Lote norte'), findsOneWidget);

      await tester.tap(find.text('Lote norte'));
      // Deliberately not pumpAndSettle: GisMapScreen kicks off real async
      // archive/tile initialization with no fake repository injected here
      // (this test only cares about how it was reached), and settling would
      // wait on that instead of just the (zero-duration) route transition.
      await tester.pump();
      await tester.pump();

      expect(find.byType(PersonalMarkersScreen), findsNothing);
      final gisScreen = tester.widget<GisMapScreen>(find.byType(GisMapScreen));
      expect(gisScreen.focusPersonalMarkerId, 'marker-1');
      // The fix this test guards: entering GIS this way must never
      // auto-open the marker's details bottom sheet — only center the
      // camera. The user opens details manually by tapping the pin.
      expect(find.byType(BottomSheet), findsNothing);
    },
  );
}
