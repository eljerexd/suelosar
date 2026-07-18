import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/models/favorite_soil_feature.dart';
import 'package:suelosar/models/pdf_soil_sheet_favorite.dart';
import 'package:suelosar/repositories/gis_favorites_repository.dart';
import 'package:suelosar/repositories/pdf_soil_sheet_favorites_repository.dart';
import 'package:suelosar/services/pdf_soil_sheet_favorites_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('legacy mixed favorites migrate into independent stores', () async {
    final pdfFavorite = FavoriteSoilFeature(
      id: 'soil-map:Junin.pdf',
      unitName: 'Junin',
      unitSymbol: '',
      soilSeries: const ['Junin'],
      pdfIdentifier: 'Junin.pdf',
    );
    final gisFavorite = FavoriteSoilFeature(
      id: 'gis-feature-42',
      unitName: 'Unidad GIS',
      unitSymbol: 'UG',
      soilSeries: const ['Serie GIS'],
      pdfIdentifier: null,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      FavoriteSoilFeature.storageKey: <String>[
        jsonEncode(pdfFavorite.toJson()),
        jsonEncode(gisFavorite.toJson()),
      ],
    });

    final pdfFavorites = await const PdfSoilSheetFavoritesRepository().load();
    final gisFavorites = await const GisFavoritesRepository().load();

    expect(pdfFavorites, hasLength(1));
    expect(pdfFavorites.single.title, 'Junin');
    expect(pdfFavorites.single.id, startsWith(PdfSoilSheetFavorite.idPrefix));
    expect(gisFavorites, hasLength(1));
    expect(gisFavorites.single.id, 'gis-feature-42');

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getStringList(PdfSoilSheetFavorite.storageKey),
      hasLength(1),
    );
    expect(
      preferences.getStringList(FavoriteSoilFeature.storageKey),
      hasLength(1),
    );
  });

  test('adding a PDF favorite never changes the GIS collection', () async {
    final gisFavorite = FavoriteSoilFeature(
      id: 'gis-feature-1',
      unitName: 'Unidad GIS',
      unitSymbol: 'UG',
      soilSeries: const ['Serie GIS'],
      pdfIdentifier: null,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      FavoriteSoilFeature.storageKey: <String>[
        jsonEncode(gisFavorite.toJson()),
      ],
    });

    final service = PdfSoilSheetFavoritesService();
    await service.toggle(
      const <PdfSoilSheetFavorite>[],
      title: 'Pergamino',
      pdfIdentifier: 'Pergamino.pdf',
    );

    final gisFavorites = await const GisFavoritesRepository().load();
    final pdfFavorites = await service.load();
    expect(gisFavorites.map((item) => item.id), ['gis-feature-1']);
    expect(pdfFavorites.map((item) => item.title), ['Pergamino']);
  });

  test('GIS repository rejects legacy PDF records defensively', () async {
    final pdfLikeRecord = FavoriteSoilFeature(
      id: 'soil-map:Azul.pdf',
      unitName: 'Azul',
      unitSymbol: '',
      soilSeries: const ['Azul'],
      pdfIdentifier: 'Azul.pdf',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      FavoriteSoilFeature.storageKey: <String>[
        jsonEncode(pdfLikeRecord.toJson()),
      ],
    });

    final gisFavorites = await const GisFavoritesRepository().load();

    expect(gisFavorites, isEmpty);
  });
}
