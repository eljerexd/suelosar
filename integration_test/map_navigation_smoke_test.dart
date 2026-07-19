import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:suelosar/app/suelos_ar_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens the GIS map from the home map button', (tester) async {
    await tester.pumpWidget(const SuelosARApp());
    await tester.pump();

    expect(find.byType(FlutterMap), findsNothing);
    final mapLauncher = find.byKey(const ValueKey('module-gis-map'));
    expect(mapLauncher, findsOneWidget);

    await tester.tap(mapLauncher);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Mapa de suelos'), findsOneWidget);
    expect(find.byType(FlutterMap), findsOneWidget);
  });
}
