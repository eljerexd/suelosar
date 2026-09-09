import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/constants/app_icons.dart';
import 'package:suelosar/models/pdf_soil_sheet_favorite.dart';
import 'package:suelosar/models/soil_card.dart';
import 'package:suelosar/models/soil_map.dart';
import 'package:suelosar/repositories/santa_fe_series_repository.dart';
import 'package:suelosar/screens/favorites_screen.dart';
import 'package:suelosar/screens/pdf_viewer_screen.dart';
import 'package:suelosar/screens/soil_maps_screen.dart';

const _santaFePdfAsset = 'assets/pdfs_santa_fe/mapa_suelos_santa_fe.pdf';

List<SoilMap> _buenosAiresFixture() => const [
  SoilMap(name: 'Lincoln', pdf: 'Lincoln.pdf'),
  SoilMap(name: 'Aarón Castellanos', pdf: 'Aaron_Castellanos.pdf'),
];

List<SoilCard> _santaFeFixture() => [
  SoilCard.santaFe(
    const SantaFeSeriesEntry(
      code: 'RSA',
      name: 'Río Salado',
      startPage: 517,
      endPage: 519,
    ),
    pdfAsset: _santaFePdfAsset,
  ),
  SoilCard.santaFe(
    const SantaFeSeriesEntry(
      code: 'AC',
      name: 'Aarón Castellanos',
      startPage: 14,
      endPage: 16,
    ),
    pdfAsset: _santaFePdfAsset,
  ),
];

Future<void> _pumpCatalog(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // Tall enough that every fixture card (4 total) is actually built by the
  // sliver list without scrolling — the default 800x600 test window only
  // builds the first few rows, which would otherwise cut off "Río Salado".
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SoilMapsScreen(
        soilMapsLoader: () async => _buenosAiresFixture(),
        santaFeCardsLoader: () async => _santaFeFixture(),
      ),
    ),
  );
  await _waitForText(tester, 'Todas las cartas');
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.text(text).evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $text.');
}

void main() {
  testWidgets(
    'Santa Fe series show their real name, never the raw code, and default '
    'filter (Todas) shows both provinces',
    (tester) async {
      await _pumpCatalog(tester);

      expect(find.text('Río Salado'), findsOneWidget);
      expect(find.text('RSA'), findsNothing);
      expect(find.text('Lincoln'), findsOneWidget);
      // The Buenos Aires / Santa Fe name collision is real (both catalogs
      // have an "Aarón Castellanos") — Todas must show both as separate
      // cards, distinguished by their province subtitle.
      expect(find.text('Aarón Castellanos'), findsNWidgets(2));
      expect(find.text('Buenos Aires'), findsWidgets);
      expect(find.text('Santa Fe'), findsWidgets);
    },
  );

  testWidgets('Santa Fe filter shows only Santa Fe series', (tester) async {
    await _pumpCatalog(tester);

    await tester.tap(find.text('Santa Fe').first);
    await tester.pumpAndSettle();

    expect(find.text('Río Salado'), findsOneWidget);
    expect(find.text('Lincoln'), findsNothing);
  });

  testWidgets(
    'province filter renders as a horizontally scrollable chip row, "Todas" '
    'selected by default',
    (tester) async {
      await _pumpCatalog(tester);

      final chipRow = tester.widget<ListView>(
        find.byKey(const ValueKey('province-filter-chips')),
      );
      expect(chipRow.scrollDirection, Axis.horizontal);

      // "Todas" is the default selection: its chip shows the check icon,
      // the province chips don't.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('province-chip-todas')),
          matching: find.byIcon(AppIcons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('province-chip-buenosAires')),
          matching: find.byIcon(AppIcons.check),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('province-chip-santaFe')),
          matching: find.byIcon(AppIcons.check),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'selecting a province chip moves the check icon to it and off the '
    'others',
    (tester) async {
      await _pumpCatalog(tester);

      await tester.tap(find.text('Santa Fe').first);
      await tester.pumpAndSettle();

      expect(find.byIcon(AppIcons.check), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('province-chip-santaFe')),
          matching: find.byIcon(AppIcons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('province-chip-todas')),
          matching: find.byIcon(AppIcons.check),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'province filter chips fit a narrow phone without layout overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.reset);

      await _pumpCatalog(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Todas'), findsOneWidget);
      expect(find.text('Buenos Aires'), findsWidgets);
      expect(find.text('Santa Fe'), findsWidgets);
    },
  );

  testWidgets('Buenos Aires filter shows only Buenos Aires cartas', (
    tester,
  ) async {
    await _pumpCatalog(tester);

    await tester.tap(find.text('Buenos Aires').first);
    await tester.pumpAndSettle();

    expect(find.text('Lincoln'), findsOneWidget);
    expect(find.text('Río Salado'), findsNothing);
  });

  testWidgets('search combines with the active province filter', (
    tester,
  ) async {
    await _pumpCatalog(tester);

    await tester.tap(find.text('Santa Fe').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(SearchBar), 'Río');
    await tester.pumpAndSettle();

    expect(find.text('Río Salado'), findsOneWidget);
    expect(find.text('Lincoln'), findsNothing);

    await tester.tap(find.text('Todas').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(SearchBar), 'Lincoln');
    await tester.pumpAndSettle();

    // find.text('Lincoln') would also match the SearchBar's own EditableText
    // (its typed value is now literally "Lincoln"), so scope to the card.
    expect(find.widgetWithText(ListTile, 'Lincoln'), findsOneWidget);
    expect(find.text('Río Salado'), findsNothing);
  });

  testWidgets(
    'opening a Santa Fe carta passes startPage/endPage into PdfViewerScreen',
    (tester) async {
      await _pumpCatalog(tester);

      await tester.tap(find.text('Río Salado'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final viewer = tester.widget<PdfViewerScreen>(
        find.byType(PdfViewerScreen),
      );
      expect(viewer.assetPath, _santaFePdfAsset);
      expect(viewer.initialPage, 517);
      expect(viewer.lastPage, 519);
    },
  );

  testWidgets(
    'opening a Buenos Aires carta keeps initialPage/lastPage null',
    (tester) async {
      await _pumpCatalog(tester);

      await tester.tap(find.text('Lincoln'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final viewer = tester.widget<PdfViewerScreen>(
        find.byType(PdfViewerScreen),
      );
      expect(viewer.assetPath, 'assets/pdfs/Lincoln.pdf');
      expect(viewer.initialPage, isNull);
      expect(viewer.lastPage, isNull);
    },
  );

  testWidgets(
    'toggling favorites keeps Buenos Aires and Santa Fe identifiers '
    'distinct even for same-named series',
    (tester) async {
      await _pumpCatalog(tester);

      final lincolnTile = find.ancestor(
        of: find.text('Lincoln'),
        matching: find.byType(ListTile),
      );
      final lincolnFavorite = find.descendant(
        of: lincolnTile,
        matching: find.byTooltip('Agregar a favoritos'),
      );
      expect(lincolnFavorite, findsOneWidget);
      await tester.tap(lincolnFavorite);
      await tester.pumpAndSettle();

      final favorites = await SharedPreferences.getInstance();
      final stored = favorites.getStringList(PdfSoilSheetFavorite.storageKey);
      expect(stored, isNotNull);
      final decoded = stored!
          .map((raw) => PdfSoilSheetFavorite.fromJson(jsonDecode(raw)))
          .toList();
      expect(decoded, hasLength(1));
      expect(decoded.single.pdfIdentifier, 'Lincoln.pdf');

      // The Santa Fe "Río Salado" card remains unfavorited and unaffected.
      final rioSaladoTile = find.ancestor(
        of: find.text('Río Salado'),
        matching: find.byType(ListTile),
      );
      final rioSaladoFavorite = find.descendant(
        of: rioSaladoTile,
        matching: find.byTooltip('Agregar a favoritos'),
      );
      expect(rioSaladoFavorite, findsOneWidget);
    },
  );

  testWidgets(
    'a favorited carta is shown only in "Favoritos" and disappears from '
    '"Todas las cartas"; un-favoriting restores it',
    (tester) async {
      await _pumpCatalog(tester);

      final lincolnCard = find.byKey(
        const ValueKey('soil-card-Lincoln.pdf'),
      );
      expect(lincolnCard, findsOneWidget);
      expect(find.text('Favoritos (0)'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: lincolnCard,
          matching: find.byTooltip('Agregar a favoritos'),
        ),
      );
      await tester.pumpAndSettle();

      // Still exactly one "Lincoln" card on screen — not duplicated — and
      // the favorites count went up, proving it moved into "Favoritos"
      // rather than just also appearing there.
      expect(find.byKey(const ValueKey('soil-card-Lincoln.pdf')), findsOneWidget);
      expect(find.text('Favoritos (1)'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('soil-card-Lincoln.pdf')),
          matching: find.byTooltip('Quitar de favoritos'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('soil-card-Lincoln.pdf')), findsOneWidget);
      expect(find.text('Favoritos (0)'), findsOneWidget);
    },
  );

  testWidgets(
    'favoriting one province\'s carta does not hide the same-named carta '
    'from the other province',
    (tester) async {
      await _pumpCatalog(tester);

      // Both "Aarón Castellanos" cards (BA + SF) start out only in "Todas".
      expect(
        find.byKey(const ValueKey('soil-card-Aaron_Castellanos.pdf')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('soil-card-santa_fe:AC')),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('soil-card-Aaron_Castellanos.pdf')),
          matching: find.byTooltip('Agregar a favoritos'),
        ),
      );
      await tester.pumpAndSettle();

      // The Buenos Aires one moved into "Favoritos"; the Santa Fe one is
      // untouched and still only in "Todas las cartas".
      expect(find.text('Favoritos (1)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('soil-card-Aaron_Castellanos.pdf')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('soil-card-santa_fe:AC')),
        findsOneWidget,
      );
      expect(find.text('Aarón Castellanos'), findsNWidgets(2));
    },
  );

  testWidgets(
    'a favorited carta stays hidden from "Todas las cartas" search results '
    'but keeps showing under "Favoritos"',
    (tester) async {
      await _pumpCatalog(tester);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('soil-card-Lincoln.pdf')),
          matching: find.byTooltip('Agregar a favoritos'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(SearchBar), 'Lincoln');
      await tester.pumpAndSettle();

      // Only the "Favoritos" copy remains — search doesn't resurrect it in
      // "Todas las cartas".
      expect(find.byKey(const ValueKey('soil-card-Lincoln.pdf')), findsOneWidget);
      expect(find.text('Favoritos (1)'), findsOneWidget);
    },
  );

  testWidgets(
    'a favorite persisted from a previous session (app restart) stays out '
    'of "Todas las cartas" on the very first load',
    (tester) async {
      final existingFavorite = PdfSoilSheetFavorite(
        id: '${PdfSoilSheetFavorite.idPrefix}Lincoln.pdf',
        title: 'Lincoln',
        pdfIdentifier: 'Lincoln.pdf',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        PdfSoilSheetFavorite.storageKey: <String>[
          jsonEncode(existingFavorite.toJson()),
        ],
      });
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: SoilMapsScreen(
            soilMapsLoader: () async => _buenosAiresFixture(),
            santaFeCardsLoader: () async => _santaFeFixture(),
          ),
        ),
      );
      await _waitForText(tester, 'Todas las cartas');
      // The favorites list loads asynchronously; give it a moment to apply.
      await tester.pumpAndSettle();

      expect(find.text('Favoritos (1)'), findsOneWidget);
      expect(find.byKey(const ValueKey('soil-card-Lincoln.pdf')), findsOneWidget);
    },
  );

  testWidgets(
    'FavoritesScreen resolves a saved Santa Fe favorite to its real page '
    'range in the consolidated PDF',
    (tester) async {
      final favorite = PdfSoilSheetFavorite(
        id: '${PdfSoilSheetFavorite.idPrefix}${SoilCard.santaFeFavoriteIdentifierPrefix}RSA',
        title: 'Río Salado',
        pdfIdentifier: '${SoilCard.santaFeFavoriteIdentifierPrefix}RSA',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        PdfSoilSheetFavorite.storageKey: <String>[
          jsonEncode(favorite.toJson()),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: FavoritesScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Río Salado'), findsOneWidget);
      // The raw "santa_fe:" prefix must never leak into the UI.
      expect(find.textContaining('santa_fe:'), findsNothing);

      await tester.tap(find.text('Río Salado'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final viewer = tester.widget<PdfViewerScreen>(
        find.byType(PdfViewerScreen),
      );
      expect(viewer.initialPage, 517);
      expect(viewer.lastPage, 519);
    },
  );
}
