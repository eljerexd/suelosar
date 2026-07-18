import 'package:flutter/material.dart';

import '../constants/app_icons.dart';
import '../models/pdf_soil_sheet_favorite.dart';
import '../repositories/pdf_series_repository.dart';
import '../services/pdf_soil_sheet_favorites_service.dart';
import 'pdf_viewer_screen.dart';
import '../widgets/app_notification.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/scrollable_empty_state.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final PdfSeriesRepository _pdfSeriesRepository = PdfSeriesRepository();
  final PdfSoilSheetFavoritesService _favoritesService =
      PdfSoilSheetFavoritesService();
  List<PdfSoilSheetFavorite>? _favorites;
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
            favorite.title.isEmpty ? 'Carta sin nombre' : favorite.title,
          ),
          subtitle: Text('Memoria descriptiva\n${favorite.pdfIdentifier}'),
          isThreeLine: true,
          onTap: () => _openFavoritePdf(favorite),
          trailing: IconButton(
            key: ValueKey('remove-favorite-${favorite.id}'),
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

  Future<void> _openFavoritePdf(PdfSoilSheetFavorite favorite) async {
    final savedIdentifier = favorite.pdfIdentifier.trim();
    final assetPath = savedIdentifier.isNotEmpty
        ? savedIdentifier.startsWith('assets/')
              ? savedIdentifier
              : 'assets/pdfs/$savedIdentifier'
        : await _pdfSeriesRepository.findPdfForSeries(favorite.title);
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
      title: favorite.title,
      assetPath: assetPath,
      unavailableMessage: 'Memoria descriptiva no disponible.',
    );
  }

  List<PdfSoilSheetFavorite> _filterFavorites(
    List<PdfSoilSheetFavorite> favorites,
  ) {
    final query = _normalizeSearchText(_searchQuery.trim());
    if (query.isEmpty) {
      return favorites;
    }

    final matches = <({PdfSoilSheetFavorite favorite, int rank})>[];
    for (final favorite in favorites) {
      final fields = <String>[
        favorite.title,
        favorite.pdfIdentifier,
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
      return first.favorite.title.compareTo(second.favorite.title);
    });
    return matches.map((match) => match.favorite).toList(growable: false);
  }

  Future<void> _loadFavorites() async {
    final favorites = await _favoritesService.load();
    if (mounted) {
      setState(() => _favorites = favorites);
    }
  }

  Future<void> _removeFavorite(PdfSoilSheetFavorite favorite) async {
    final favorites = _favorites;
    if (favorites == null) {
      return;
    }
    final updated = await _favoritesService.remove(favorites, favorite);
    if (mounted) setState(() => _favorites = updated);
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
              'Guardá cartas de suelo para encontrarlas acá.',
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
