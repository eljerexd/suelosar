import 'package:flutter/material.dart';

import '../constants/app_icons.dart';
import '../models/favorite_soil_feature.dart';
import '../services/gis_favorites_service.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/scrollable_empty_state.dart';

class GisFavoritesScreen extends StatefulWidget {
  const GisFavoritesScreen({super.key});

  @override
  State<GisFavoritesScreen> createState() => _GisFavoritesScreenState();
}

class _GisFavoritesScreenState extends State<GisFavoritesScreen> {
  final GisFavoritesService _favoritesService = GisFavoritesService();
  List<FavoriteSoilFeature>? _favorites;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  @override
  Widget build(BuildContext context) {
    return FloatingHeaderScaffold(
      header: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingAppBarBackButton(
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 14),
          const FloatingAppBarTitle('Favoritos'),
          const SizedBox(width: 10),
        ],
      ),
      body: Column(
        children: [
          SearchBar(
            hintText: 'Buscar favorito...',
            leading: const Icon(AppIcons.search),
            onChanged: (value) => setState(() => _searchQuery = value),
          ),
          const SizedBox(height: 12),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final favorites = _favorites;
    if (favorites == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final filtered = _filterFavorites(favorites);
    if (filtered.isEmpty) {
      return ScrollableEmptyState(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                favorites.isEmpty ? AppIcons.star : AppIcons.searchOff,
                size: 52,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                favorites.isEmpty
                    ? 'Todavía no hay favoritos'
                    : 'No se encontraron favoritos.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final favorite = filtered[index];
        return ListTile(
          title: Text(
            favorite.unitName.isEmpty ? 'Unidad sin nombre' : favorite.unitName,
          ),
          subtitle: Text(
            'Símbolo: ${favorite.unitSymbol.isEmpty ? 'Sin datos' : favorite.unitSymbol}\n'
            'Serie principal: ${favorite.dominantSoilSeries}',
          ),
          isThreeLine: true,
          onTap: () => Navigator.of(context).pop(favorite.id),
          trailing: IconButton(
            key: ValueKey('remove-gis-favorite-${favorite.id}'),
            icon: Icon(
              AppIcons.star,
              fill: 1,
              color: Theme.of(context).colorScheme.primary,
            ),
            tooltip: 'Quitar de favoritos',
            onPressed: () => _removeFavorite(favorite),
          ),
        );
      },
    );
  }

  List<FavoriteSoilFeature> _filterFavorites(
    List<FavoriteSoilFeature> favorites,
  ) {
    final query = _normalize(_searchQuery.trim());
    if (query.isEmpty) return favorites;
    final matches = <({FavoriteSoilFeature favorite, int rank})>[];
    for (final favorite in favorites) {
      final fields = <String>[
        favorite.unitName,
        favorite.unitSymbol,
        favorite.dominantSoilSeries,
      ].map(_normalize);
      var bestRank = 3;
      for (final field in fields) {
        final rank = field == query
            ? 0
            : field.startsWith(query)
            ? 1
            : field.contains(query)
            ? 2
            : 3;
        if (rank < bestRank) bestRank = rank;
      }
      if (bestRank < 3) matches.add((favorite: favorite, rank: bestRank));
    }
    matches.sort((first, second) {
      final rank = first.rank.compareTo(second.rank);
      return rank != 0
          ? rank
          : first.favorite.unitName.compareTo(second.favorite.unitName);
    });
    return matches.map((match) => match.favorite).toList(growable: false);
  }

  Future<void> _loadFavorites() async {
    final favorites = await _favoritesService.load();
    if (mounted) setState(() => _favorites = favorites);
  }

  Future<void> _removeFavorite(FavoriteSoilFeature favorite) async {
    final favorites = _favorites;
    if (favorites == null) return;
    final updated = favorites.where((item) => item.id != favorite.id).toList();
    setState(() => _favorites = updated);
    await _favoritesService.save(updated);
  }
}

String _normalize(String value) {
  const replacements = <String, String>{
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'ñ': 'n',
  };
  return value
      .toLowerCase()
      .split('')
      .map((character) => replacements[character] ?? character)
      .join();
}
