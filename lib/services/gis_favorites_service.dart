import '../models/favorite_soil_feature.dart';
import '../repositories/gis_favorites_repository.dart';

class GisFavoritesService {
  GisFavoritesService([this._repository = const GisFavoritesRepository()]);

  final GisFavoritesRepository _repository;

  Future<List<FavoriteSoilFeature>> load() => _repository.load();

  Future<void> save(Iterable<FavoriteSoilFeature> favorites) {
    return _repository.save(favorites);
  }
}
