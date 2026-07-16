import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_icons.dart';
import '../models/favorite_soil_feature.dart';
import '../repositories/sync_aware_local_repository.dart';
import '../repositories/pdf_series_repository.dart';
import 'pdf_viewer_screen.dart';
import '../widgets/app_notification.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/scrollable_empty_state.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({this.openPdfOnTap = false, super.key});

  final bool openPdfOnTap;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final PdfSeriesRepository _pdfSeriesRepository = PdfSeriesRepository();
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
          Expanded(child: _buildFavoritesContent()),
        ],
      ),
    );
  }

  Widget _buildFavoritesContent() {
    final favorites = _favorites;
    if (favorites == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (favorites.isEmpty) {
      return const _EmptyFavorites();
    }

    final filteredFavorites = _filterFavorites(favorites);
    if (filteredFavorites.isEmpty) {
      return const _NoFavoriteSearchResults();
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: filteredFavorites.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final favorite = filteredFavorites[index];
        return ListTile(
          title: Text(
            favorite.unitName.isEmpty ? 'Unidad sin nombre' : favorite.unitName,
          ),
          subtitle: Text(
            'Símbolo: ${favorite.unitSymbol.isEmpty ? 'Sin datos' : favorite.unitSymbol}\n'
            'Serie principal: ${favorite.dominantSoilSeries}',
          ),
          isThreeLine: true,
          onTap: () {
            if (widget.openPdfOnTap) {
              _openFavoritePdf(favorite);
            } else {
              Navigator.of(context).pop(favorite.id);
            }
          },
          trailing: IconButton(
            icon: const Icon(AppIcons.delete),
            tooltip: 'Quitar de favoritos',
            onPressed: () => _removeFavorite(favorite),
          ),
        );
      },
    );
  }

  Future<void> _openFavoritePdf(FavoriteSoilFeature favorite) async {
    final savedIdentifier = favorite.pdfIdentifier?.trim() ?? '';
    final assetPath = savedIdentifier.isNotEmpty
        ? savedIdentifier.startsWith('assets/')
              ? savedIdentifier
              : 'assets/pdfs/$savedIdentifier'
        : await _pdfSeriesRepository.findPdfForSeries(
            favorite.dominantSoilSeries,
          );
    if (!mounted) return;
    if (assetPath == null) {
      AppNotification.show(
        context,
        message: 'Memoria descriptiva no disponible.',
        type: AppNotificationType.warning,
      );
      return;
    }
    await openLocalPdfViewer(
      context,
      title: favorite.dominantSoilSeries,
      assetPath: assetPath,
      unavailableMessage: 'Memoria descriptiva no disponible.',
    );
  }

  List<FavoriteSoilFeature> _filterFavorites(
    List<FavoriteSoilFeature> favorites,
  ) {
    final query = _normalizeSearchText(_searchQuery.trim());
    if (query.isEmpty) {
      return favorites;
    }

    final matches = <({FavoriteSoilFeature favorite, int rank})>[];
    for (final favorite in favorites) {
      final fields = <String>[
        favorite.unitSymbol,
        favorite.unitName,
        favorite.dominantSoilSeries,
      ].map(_normalizeSearchText);
      var bestRank = 3;
      for (final field in fields) {
        final rank = field == query
            ? 0
            : field.startsWith(query)
            ? 1
            : field.contains(query)
            ? 2
            : 3;
        if (rank < bestRank) {
          bestRank = rank;
        }
      }
      if (bestRank < 3) {
        matches.add((favorite: favorite, rank: bestRank));
      }
    }

    matches.sort((first, second) {
      final rankComparison = first.rank.compareTo(second.rank);
      if (rankComparison != 0) {
        return rankComparison;
      }
      return first.favorite.unitName.compareTo(second.favorite.unitName);
    });
    return matches.map((match) => match.favorite).toList(growable: false);
  }

  Future<void> _loadFavorites() async {
    final preferences = await SharedPreferences.getInstance();
    final favorites = <FavoriteSoilFeature>[];
    for (final rawFavorite
        in preferences.getStringList(FavoriteSoilFeature.storageKey) ??
            const <String>[]) {
      try {
        final decoded = jsonDecode(rawFavorite);
        if (decoded is Map<String, dynamic>) {
          final favorite = FavoriteSoilFeature.fromJson(decoded);
          if (favorite.id.isNotEmpty) {
            favorites.add(favorite);
          }
        }
      } catch (_) {
        // Ignore malformed records while preserving valid favorites.
      }
    }
    if (mounted) {
      setState(() => _favorites = favorites);
    }
  }

  Future<void> _removeFavorite(FavoriteSoilFeature favorite) async {
    final favorites = _favorites;
    if (favorites == null) {
      return;
    }
    setState(() => favorites.removeWhere((item) => item.id == favorite.id));

    await SyncAwareLocalRepository.instance.saveFavorites(favorites);
  }
}

String _normalizeSearchText(String value) {
  const replacements = <String, String>{
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'â': 'a',
    'ã': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'ê': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'î': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ô': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'û': 'u',
    'ñ': 'n',
  };
  final normalized = StringBuffer();
  for (final character in value.toLowerCase().split('')) {
    normalized.write(replacements[character] ?? character);
  }
  return normalized.toString();
}

class _EmptyFavorites extends StatelessWidget {
  const _EmptyFavorites();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ScrollableEmptyState(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.star,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('Todavía no hay favoritos', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Guardá unidades desde el mapa para encontrarlas acá.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _NoFavoriteSearchResults extends StatelessWidget {
  const _NoFavoriteSearchResults();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ScrollableEmptyState(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.searchOff,
              size: 48,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No se encontraron favoritos.',
              textAlign: TextAlign.center,
              style: textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
