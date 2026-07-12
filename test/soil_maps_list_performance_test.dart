import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/screens/soil_maps_screen.dart';

void main() {
  testWidgets('soil maps list builds only visible rows', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SoilMapsScreen()));
    for (var attempt = 0; attempt < 50; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.text('Todas las cartas').evaluate().isNotEmpty) break;
    }
    expect(find.text('Todas las cartas'), findsOneWidget);

    final builtRows = find.byType(ListTile).evaluate().length;
    debugPrint('SOIL_MAP_ROWS_BUILT $builtRows');
    expect(builtRows, lessThan(40));
  });
}
