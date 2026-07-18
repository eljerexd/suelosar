import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/pdf_soil_sheet_favorite.dart';
import '../services/favorite_systems_migration_service.dart';

class PdfSoilSheetFavoritesRepository {
  const PdfSoilSheetFavoritesRepository();

  Future<List<PdfSoilSheetFavorite>> load() async {
    await FavoriteSystemsMigrationService.migrateLegacyPdfFavorites();
    final preferences = await SharedPreferences.getInstance();
    final favorites = <PdfSoilSheetFavorite>[];
    for (final raw
        in preferences.getStringList(PdfSoilSheetFavorite.storageKey) ??
            const <String>[]) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final favorite = PdfSoilSheetFavorite.fromJson(decoded);
        if (favorite.id.isNotEmpty && favorite.pdfIdentifier.isNotEmpty) {
          favorites.add(favorite);
        }
      } catch (_) {
        // Preserve valid entries when one local record is malformed.
      }
    }
    return favorites;
  }

  Future<void> save(Iterable<PdfSoilSheetFavorite> favorites) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      PdfSoilSheetFavorite.storageKey,
      favorites.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }
}
