import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_soil_feature.dart';
import '../services/favorite_systems_migration_service.dart';
import 'sync_aware_local_repository.dart';

class GisFavoritesRepository {
  const GisFavoritesRepository();

  Future<List<FavoriteSoilFeature>> load() async {
    await FavoriteSystemsMigrationService.migrateLegacyPdfFavorites();
    final preferences = await SharedPreferences.getInstance();
    final favorites = <FavoriteSoilFeature>[];
    for (final raw
        in preferences.getStringList(FavoriteSoilFeature.storageKey) ??
            const <String>[]) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final favorite = FavoriteSoilFeature.fromJson(decoded);
        if (favorite.id.isNotEmpty && !favorite.id.startsWith('soil-map:')) {
          favorites.add(favorite);
        }
      } catch (_) {
        // Preserve valid entries when one local record is malformed.
      }
    }
    return favorites;
  }

  Future<void> save(Iterable<FavoriteSoilFeature> favorites) {
    return SyncAwareLocalRepository.instance.saveFavorites(favorites);
  }
}
