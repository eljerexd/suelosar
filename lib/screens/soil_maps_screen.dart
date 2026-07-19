import 'package:flutter/material.dart';

import '../constants/app_icons.dart';
import '../models/pdf_soil_sheet_favorite.dart';
import '../models/soil_map.dart';
import '../repositories/soil_map_repository.dart';
import '../services/pdf_soil_sheet_favorites_service.dart';
import '../utils/app_motion.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/responsive_desktop_shell.dart';
import '../widgets/scrollable_empty_state.dart';
import 'pdf_viewer_screen.dart';

class SoilMapsScreen extends StatefulWidget {
  const SoilMapsScreen({super.key});

  @override
  State<SoilMapsScreen> createState() => _SoilMapsScreenState();
}

class _SoilMapsScreenState extends State<SoilMapsScreen> {
  static const String _missingPdfMessage = 'Carta de suelo no disponible';

  final SoilMapRepository _soilMapRepository = const SoilMapRepository();
  final PdfSoilSheetFavoritesService _favoritesService =
      PdfSoilSheetFavoritesService();
  late final Future<List<SoilMap>> _soilMapsFuture;
  List<PdfSoilSheetFavorite> _favorites = const [];
  Set<String> _favoritePdfIdentifiers = const {};
  final Map<SoilMap, String> _searchNames = Map.identity();
  final ValueNotifier<String> _searchQuery = ValueNotifier('');

  @override
  void initState() {
    super.initState();
    _soilMapsFuture = _soilMapRepository.loadSoilMaps().then((soilMaps) {
      for (final soilMap in soilMaps) {
        _searchNames[soilMap] = soilMap.name.toLowerCase();
      }
      return soilMaps;
    });
    _loadFavorites();
  }

  @override
  void dispose() {
    _searchQuery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return FloatingHeaderScaffold(
      header: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingAppBarBackButton(
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 14),
          const FloatingAppBarTitle('Memorias descriptivas'),
          const SizedBox(width: 10),
        ],
      ),
      body: SuelosArResponsivePage(
        builder: (context, layout) {
          final maxContentWidth = layout.isPhone
              ? double.infinity
              : layout.isTablet
              ? 820.0
              : 900.0;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth),
              child: Column(
                children: [
                  FloatingAppBarCard(
                    padding: EdgeInsets.zero,
                    child: SearchBar(
                      onChanged: _updateSearchQuery,
                      hintText: 'Buscar carta de suelo...',
                      leading: const Icon(AppIcons.search),
                      elevation: const WidgetStatePropertyAll(0),
                      backgroundColor: const WidgetStatePropertyAll(
                        Colors.white,
                      ),
                      surfaceTintColor: const WidgetStatePropertyAll(
                        Colors.transparent,
                      ),
                      shape: WidgetStatePropertyAll(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 18),
                      ),
                    ),
                  ),
                  SizedBox(height: layout.isPhone ? 22 : 26),
                  Expanded(
                    child: ValueListenableBuilder<String>(
                      valueListenable: _searchQuery,
                      builder: (context, query, _) =>
                          FutureBuilder<List<SoilMap>>(
                            future: _soilMapsFuture,
                            builder: (context, snapshot) {
                              if (snapshot.connectionState !=
                                  ConnectionState.done) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }

                              if (snapshot.hasError) {
                                return const _SoilMapLoadError();
                              }

                              final soilMaps = _filterSoilMaps(
                                snapshot.data ?? const [],
                                query,
                              );
                              if (soilMaps.isEmpty) {
                                return const _EmptySoilMapSearch();
                              }

                              final favoriteMaps = soilMaps
                                  .where(_isFavorite)
                                  .toList(growable: false);
                              return CustomScrollView(
                                slivers: [
                                  const SliverToBoxAdapter(
                                    child: SizedBox(height: 4),
                                  ),
                                  SliverToBoxAdapter(
                                    child: _SectionTitle(
                                      icon: AppIcons.star,
                                      title:
                                          'Favoritos (${favoriteMaps.length})',
                                    ),
                                  ),
                                  const SliverToBoxAdapter(
                                    child: SizedBox(height: 12),
                                  ),
                                  if (favoriteMaps.isEmpty)
                                    const SliverToBoxAdapter(
                                      child: _EmptyFavorites(),
                                    )
                                  else
                                    SliverList.separated(
                                      addAutomaticKeepAlives: false,
                                      itemCount: favoriteMaps.length,
                                      itemBuilder: (context, index) =>
                                          _buildSoilMapItem(
                                            context,
                                            favoriteMaps[index],
                                            colorScheme,
                                          ),
                                      separatorBuilder: (context, index) =>
                                          const SizedBox(height: 10),
                                    ),
                                  const SliverToBoxAdapter(
                                    child: SizedBox(height: 32),
                                  ),
                                  const SliverToBoxAdapter(
                                    child: _SectionTitle(
                                      icon: AppIcons.library,
                                      title: 'Todas las cartas',
                                    ),
                                  ),
                                  const SliverToBoxAdapter(
                                    child: SizedBox(height: 12),
                                  ),
                                  SliverList.separated(
                                    addAutomaticKeepAlives: false,
                                    itemCount: soilMaps.length,
                                    itemBuilder: (context, index) =>
                                        _buildSoilMapItem(
                                          context,
                                          soilMaps[index],
                                          colorScheme,
                                        ),
                                    separatorBuilder: (context, index) =>
                                        const SizedBox(height: 10),
                                  ),
                                  const SliverToBoxAdapter(
                                    child: SizedBox(height: 24),
                                  ),
                                ],
                              );
                            },
                          ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSoilMapItem(
    BuildContext context,
    SoilMap soilMap,
    ColorScheme colorScheme,
  ) {
    final isFavorite = _isFavorite(soilMap);
    return Material(
      color: colorScheme.surface,
      elevation: 1,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.1),
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: 68,
        contentPadding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        mouseCursor: SystemMouseCursors.click,
        hoverColor: colorScheme.surfaceContainerHigh,
        splashColor: colorScheme.primary.withValues(alpha: 0.08),
        onTap: () => _openSoilMapPdf(context, soilMap),
        leading: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(AppIcons.pdf, size: 22, color: colorScheme.primary),
        ),
        title: Text(
          soilMap.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: isFavorite
                  ? 'Quitar de favoritos'
                  : 'Agregar a favoritos',
              onPressed: () => _toggleFavorite(soilMap),
              icon: AnimatedSwitcher(
                duration: AppMotion.duration(
                  context,
                  const Duration(milliseconds: 220),
                  reduced: const Duration(milliseconds: 60),
                ),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  AppIcons.star,
                  key: ValueKey(isFavorite),
                  color: isFavorite
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  fill: isFavorite ? 1 : 0,
                ),
              ),
            ),
            Icon(
              AppIcons.chevronRight,
              size: 19,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  bool _isFavorite(SoilMap soilMap) {
    return _favoritePdfIdentifiers.contains(soilMap.pdf.trim());
  }

  Future<void> _loadFavorites() async {
    final favorites = await _favoritesService.load();
    if (mounted) {
      setState(() {
        _favorites = favorites;
        _favoritePdfIdentifiers = _favoriteIdentifiers(favorites);
      });
    }
  }

  Future<void> _toggleFavorite(SoilMap soilMap) async {
    final updated = await _favoritesService.toggle(
      _favorites,
      title: soilMap.name,
      pdfIdentifier: soilMap.pdf,
    );
    if (mounted) {
      setState(() {
        _favorites = updated;
        _favoritePdfIdentifiers = _favoriteIdentifiers(updated);
      });
    }
  }

  void _updateSearchQuery(String value) {
    _searchQuery.value = value;
  }

  List<SoilMap> _filterSoilMaps(List<SoilMap> soilMaps, String searchQuery) {
    final query = searchQuery.trim().toLowerCase();

    if (query.isEmpty) {
      return soilMaps;
    }

    return soilMaps
        .where((soilMap) {
          return (_searchNames[soilMap] ?? soilMap.name.toLowerCase()).contains(
            query,
          );
        })
        .toList(growable: false);
  }

  Set<String> _favoriteIdentifiers(List<PdfSoilSheetFavorite> favorites) =>
      favorites.map((favorite) => favorite.pdfIdentifier.trim()).toSet();

  Future<void> _openSoilMapPdf(BuildContext context, SoilMap soilMap) async {
    await openLocalPdfViewer(
      context,
      title: soilMap.name,
      assetPath: soilMap.assetPath,
      unavailableMessage: _missingPdfMessage,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.icon});

  final String title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 17,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _EmptyFavorites extends StatelessWidget {
  const _EmptyFavorites();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Text(
          'Todavía no hay cartas de suelo favoritas.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _EmptySoilMapSearch extends StatelessWidget {
  const _EmptySoilMapSearch();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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
              'No se encontraron cartas de suelo',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _SoilMapLoadError extends StatelessWidget {
  const _SoilMapLoadError();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ScrollableEmptyState(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.warning,
              size: 48,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No se pudieron cargar las cartas de suelo',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Volvé a intentarlo en unos instantes.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
