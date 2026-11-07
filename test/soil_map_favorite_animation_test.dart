import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/constants/app_icons.dart';
import 'package:suelosar/models/pdf_soil_sheet_favorite.dart';
import 'package:suelosar/models/soil_card.dart';
import 'package:suelosar/models/soil_map.dart';
import 'package:suelosar/screens/soil_maps_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('favorite star stays visible and animates fill without scaling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);
    addTearDown(tester.view.reset);

    await _pumpCatalog(tester);
    final card = find.byKey(const ValueKey('soil-card-Azul.pdf'));
    final star = _starIn(card);
    expect(star, findsOneWidget);
    expect(tester.widget<Icon>(star).fill, 0);

    await tester.tap(star);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));

    expect(star, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(ScaleTransition)),
      findsNothing,
    );
    final selectingIcon = tester.widget<Icon>(star);
    expect(selectingIcon.fill, greaterThan(0));
    expect(selectingIcon.fill, lessThan(1));

    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<Icon>(star).fill, 1);

    await tester.tap(star);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(star, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(ScaleTransition)),
      findsNothing,
    );
    final removingIcon = tester.widget<Icon>(star);
    expect(removingIcon.fill, greaterThan(0));
    expect(removingIcon.fill, lessThan(1));

    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<Icon>(star).fill, 0);
    expect(
      tester
          .widget<Icon>(
            _starIn(find.byKey(const ValueKey('soil-card-Olavarria.pdf'))),
          )
          .fill,
      0,
    );

    // Two taps during consecutive animation frames must resolve to the
    // unselected state, not lose a toggle while persistence is in flight.
    await tester.tap(star);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(star);
    await tester.pumpAndSettle();
    expect(tester.widget<Icon>(star).fill, 0);

    await tester.tap(star);
    await tester.pumpAndSettle();
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getStringList(PdfSoilSheetFavorite.storageKey),
      isNotEmpty,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpCatalog(tester);
    final reopenedCard = find.byKey(const ValueKey('soil-card-Azul.pdf'));
    expect(tester.widget<Icon>(_starIn(reopenedCard)).fill, 1);
    expect(
      tester
          .widget<Icon>(
            _starIn(find.byKey(const ValueKey('soil-card-Olavarria.pdf'))),
          )
          .fill,
      0,
    );
  });
}

Finder _starIn(Finder card) => find.descendant(
  of: card,
  matching: find.byWidgetPredicate(
    (widget) => widget is Icon && widget.icon == AppIcons.star,
  ),
);

Future<void> _pumpCatalog(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SoilMapsScreen(
        soilMapsLoader: () async => const <SoilMap>[
          SoilMap(id: 1, name: 'Azul', pdf: 'Azul.pdf'),
          SoilMap(id: 2, name: 'Olavarria', pdf: 'Olavarria.pdf'),
        ],
        santaFeCardsLoader: () async => const <SoilCard>[],
        cordobaCardsLoader: () async => const <SoilCard>[],
      ),
    ),
  );
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.text('Azul').evaluate().isNotEmpty) return;
  }
  fail('The soil-map catalog did not finish loading.');
}
