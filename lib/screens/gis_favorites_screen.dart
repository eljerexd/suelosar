import 'package:flutter/material.dart';

import '../analytics/analytics_actions.dart';
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
  final ValueNotifier<String> _searchQuery = ValueNotifier('');
  final Map<String, ({String name, String symbol, String series})>
  _searchIndex = {};

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  @override
  void dispose() {
    _searchQuery.dispose();
    super.dispose();
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
            onChanged: (value) => _searchQuery.value = value,
            onSubmitted: logSubmittedSearch,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: _searchQuery,
              builder: (context, query, _) => _buildContent(query),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(String query) {
    final favorites = _favorites;
    if (favorites == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final filtered = _filterFavorites(favorites, query);
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
      addAutomaticKeepAlives: false,
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
    String searchQuery,
  ) {
    final query = _normalize(searchQuery.trim());
    if (query.isEmpty) return favorites;
    final matches = <({FavoriteSoilFeature favorite, int rank})>[];
    for (final favorite in favorites) {
      final indexed = _searchIndex[favorite.id];
      if (indexed == null) continue;
      final fields = [indexed.name, indexed.symbol, indexed.series];
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
    if (mounted) {
      _rebuildSearchIndex(favorites);
      setState(() => _favorites = favorites);
    }
  }

  Future<void> _removeFavorite(FavoriteSoilFeature favorite) async {
    final favorites = _favorites;
    if (favorites == null) return;
    final updated = favorites.where((item) => item.id != favorite.id).toList();
    setState(() {
      _favorites = updated;
      _searchIndex.remove(favorite.id);
    });
    await _favoritesService.save(updated);
  }

  void _rebuildSearchIndex(List<FavoriteSoilFeature> favorites) {
    _searchIndex
      ..clear()
      ..addEntries(
        favorites.map(
          (favorite) => MapEntry(favorite.id, (
            name: _normalize(favorite.unitName),
            symbol: _normalize(favorite.unitSymbol),
            series: _normalize(favorite.dominantSoilSeries),
          )),
        ),
      );
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
