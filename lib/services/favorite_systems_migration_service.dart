import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_soil_feature.dart';
import '../models/pdf_soil_sheet_favorite.dart';

class FavoriteSystemsMigrationService {
  FavoriteSystemsMigrationService._();

  static Future<void>? _inFlight;

  static Future<void> migrateLegacyPdfFavorites() {
    return _inFlight ??= _migrate().whenComplete(() => _inFlight = null);
  }

  static Future<void> _migrate() async {
    final preferences = await SharedPreferences.getInstance();
    final legacy = preferences.getStringList(FavoriteSoilFeature.storageKey);
    if (legacy == null || legacy.isEmpty) return;

    final existingRaw =
        preferences.getStringList(PdfSoilSheetFavorite.storageKey) ??
        const <String>[];
    final pdfFavorites = <String, PdfSoilSheetFavorite>{};
    for (final raw in existingRaw) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final favorite = PdfSoilSheetFavorite.fromJson(decoded);
        if (favorite.pdfIdentifier.isNotEmpty) {
          pdfFavorites[_normalizedPdf(favorite.pdfIdentifier)] = favorite;
        }
      } catch (_) {
        // Malformed records are left untouched by repository readers.
      }
    }

    final remainingGisFavorites = <String>[];
    var migratedAny = false;
    for (final raw in legacy) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          remainingGisFavorites.add(raw);
          continue;
        }
        final legacyId = decoded['id']?.toString() ?? '';
        if (!legacyId.startsWith('soil-map:')) {
          remainingGisFavorites.add(raw);
          continue;
        }

        final legacyFavorite = FavoriteSoilFeature.fromJson(decoded);
        final pdfIdentifier =
            legacyFavorite.pdfIdentifier?.trim().isNotEmpty == true
            ? legacyFavorite.pdfIdentifier!.trim()
            : legacyId.substring('soil-map:'.length).trim();
        if (pdfIdentifier.isEmpty) {
          remainingGisFavorites.add(raw);
          continue;
        }
        final title = legacyFavorite.unitName.trim().isNotEmpty
            ? legacyFavorite.unitName.trim()
            : legacyFavorite.dominantSoilSeries;
        pdfFavorites.putIfAbsent(
          _normalizedPdf(pdfIdentifier),
          () => PdfSoilSheetFavorite(
            id: '${PdfSoilSheetFavorite.idPrefix}$pdfIdentifier',
            title: title,
            pdfIdentifier: pdfIdentifier,
            createdAt: legacyFavorite.createdAt,
          ),
        );
        migratedAny = true;
      } catch (_) {
        remainingGisFavorites.add(raw);
      }
    }

    if (!migratedAny) return;
    await preferences.setStringList(
      PdfSoilSheetFavorite.storageKey,
      pdfFavorites.values.map((item) => jsonEncode(item.toJson())).toList(),
    );
    await preferences.setStringList(
      FavoriteSoilFeature.storageKey,
      remainingGisFavorites,
    );
  }

  static String _normalizedPdf(String value) => value.trim().toLowerCase();
}
