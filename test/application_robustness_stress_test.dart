import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/models/favorite_soil_feature.dart';
import 'package:suelosar/models/pdf_soil_sheet_favorite.dart';
import 'package:suelosar/models/personal_marker.dart';
import 'package:suelosar/models/saved_measurement.dart';
import 'package:suelosar/screens/favorites_screen.dart';
import 'package:suelosar/screens/gis_favorites_screen.dart';
import 'package:suelosar/screens/measurements_screen.dart';
import 'package:suelosar/screens/personal_markers_screen.dart';

void main() {
  testWidgets(
    'ten thousand markers remain virtualized and searchable',
    (tester) async {
      final markers = List<PersonalMarker>.generate(
        10000,
        _marker,
        growable: false,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        PersonalMarker.storageKey: markers
            .map((marker) => jsonEncode(marker.toJson()))
            .toList(growable: false),
      });
      await _setViewport(tester, const Size(360, 640));

      await tester.pumpWidget(const MaterialApp(home: PersonalMarkersScreen()));
      await _waitForText(tester, 'Marcador 0');

      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await _stressScroll(tester, find.byType(ListView));
      await tester.enterText(find.byType(SearchBar), 'Marcador 9999');
      await tester.pump();
      expect(_listText('Marcador 9999'), findsOneWidget);
      expect(_listText('Marcador 9998'), findsNothing);

      for (final size in const <Size>[
        Size(320, 568),
        Size(800, 600),
        Size(1600, 900),
        Size(360, 640),
      ]) {
        tester.view.physicalSize = size;
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'five thousand measurements remain virtualized and searchable',
    (tester) async {
      final measurements = List<SavedMeasurement>.generate(
        5000,
        _measurement,
        growable: false,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        SavedMeasurement.storageKey: measurements
            .map((measurement) => jsonEncode(measurement.toJson()))
            .toList(growable: false),
      });
      await _setViewport(tester, const Size(360, 640));

      await tester.pumpWidget(const MaterialApp(home: MeasurementsScreen()));
      await _waitForText(tester, 'Medición 0');

      expect(find.byType(Card).evaluate().length, lessThan(30));
      await _stressScroll(tester, find.byType(ListView));
      await tester.enterText(find.byType(SearchBar), 'Medición 4999');
      await tester.pump();
      expect(_listText('Medición 4999'), findsOneWidget);
      expect(_listText('Medición 4998'), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'large favorite collections remain independently searchable',
    (tester) async {
      final pdfFavorites = List<PdfSoilSheetFavorite>.generate(
        5000,
        _pdfFavorite,
        growable: false,
      );
      final gisFavorites = List<FavoriteSoilFeature>.generate(
        1000,
        _gisFavorite,
        growable: false,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        PdfSoilSheetFavorite.storageKey: pdfFavorites
            .map((favorite) => jsonEncode(favorite.toJson()))
            .toList(growable: false),
        FavoriteSoilFeature.storageKey: gisFavorites
            .map((favorite) => jsonEncode(favorite.toJson()))
            .toList(growable: false),
      });
      await _setViewport(tester, const Size(800, 600));

      await tester.pumpWidget(const MaterialApp(home: FavoritesScreen()));
      await _waitForText(tester, 'Carta 0');
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await tester.enterText(find.byType(SearchBar), 'Carta 4999');
      await tester.pump();
      expect(_listText('Carta 4999'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: GisFavoritesScreen()));
      await _waitForText(tester, 'Unidad 0');
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await tester.enterText(find.byType(SearchBar), 'Unidad 999');
      await tester.pump();
      expect(_listText('Unidad 999'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets('screen disposal during asynchronous loads is lifecycle safe', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _setViewport(tester, const Size(360, 640));

    for (var iteration = 0; iteration < 25; iteration++) {
      await tester.pumpWidget(
        MaterialApp(
          home: switch (iteration % 4) {
            0 => const PersonalMarkersScreen(),
            1 => const MeasurementsScreen(),
            2 => const FavoritesScreen(),
            _ => const GisFavoritesScreen(),
          },
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (find.text(text).evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $text.');
}

Finder _listText(String text) =>
    find.descendant(of: find.byType(ListView), matching: find.text(text));

Future<void> _stressScroll(WidgetTester tester, Finder listFinder) async {
  for (var iteration = 0; iteration < 30; iteration++) {
    await tester.fling(
      listFinder.last,
      const Offset(0, -1200),
      12000,
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
  }
  await tester.pumpAndSettle();
}

PersonalMarker _marker(int index) => PersonalMarker(
  id: 'marker-$index',
  uuid: '10000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  latitude: -34.0 - index / 100000,
  longitude: -58.0 - index / 100000,
  name: 'Marcador $index',
  description: 'Descripción del marcador $index',
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
);

SavedMeasurement _measurement(int index) => SavedMeasurement(
  id: 'measurement-$index',
  uuid: '20000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  type: index.isEven
      ? SavedMeasurementType.area
      : SavedMeasurementType.distance,
  name: 'Medición $index',
  geometry: const <LatLng>[LatLng(-34, -58), LatLng(-34.01, -58.01)],
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
  distanceMeters: index.isOdd ? 1000 + index.toDouble() : null,
  areaSquareMeters: index.isEven ? 10000 + index.toDouble() : null,
  perimeterMeters: index.isEven ? 500 + index.toDouble() : null,
);

PdfSoilSheetFavorite _pdfFavorite(int index) => PdfSoilSheetFavorite(
  id: '${PdfSoilSheetFavorite.idPrefix}$index',
  title: 'Carta $index',
  pdfIdentifier: 'carta_$index.pdf',
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
);

FavoriteSoilFeature _gisFavorite(int index) => FavoriteSoilFeature(
  id: 'feature-$index',
  uuid: '30000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  unitName: 'Unidad $index',
  unitSymbol: 'U$index',
  soilSeries: <String>['Serie $index'],
  pdfIdentifier: 'serie_$index.pdf',
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
);
