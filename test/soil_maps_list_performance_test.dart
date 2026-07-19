import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/models/pdf_soil_sheet_favorite.dart';
import 'package:suelosar/screens/soil_maps_screen.dart';

void main() {
  testWidgets(
    'soil map lists build only visible rows',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: SoilMapsScreen()));
      await _waitForText(tester, 'Todas las cartas');

      final builtRows = find.byType(ListTile).evaluate().length;
      debugPrint('SOIL_MAP_ROWS_BUILT $builtRows');
      expect(builtRows, lessThan(40));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      final rawCatalog = (await tester.runAsync(
        () => File('assets/data/soil_maps.json').readAsString(),
      ))!;
      final records = jsonDecode(rawCatalog) as List<dynamic>;
      final favorites = [
        for (final raw in records)
          PdfSoilSheetFavorite(
            id: '${PdfSoilSheetFavorite.idPrefix}${(raw as Map)['pdf'] ?? ''}',
            title: raw['name']?.toString() ?? '',
            pdfIdentifier: raw['pdf']?.toString() ?? '',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
      ];
      SharedPreferences.setMockInitialValues(<String, Object>{
        PdfSoilSheetFavorite.storageKey: favorites
            .map((favorite) => jsonEncode(favorite.toJson()))
            .toList(growable: false),
      });

      await tester.pumpWidget(const MaterialApp(home: SoilMapsScreen()));
      await _waitForText(tester, 'Favoritos (${records.length})');

      expect(find.byType(ListTile).evaluate().length, lessThan(40));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.text(text).evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $text.');
}
