import 'dart:async';

import 'package:flutter/material.dart';

import '../analytics/analytics_actions.dart';
import '../analytics/analytics_service.dart';
import '../constants/app_icons.dart';
import '../models/pdf_soil_sheet_favorite.dart';
import '../models/soil_card.dart';
import '../models/soil_map.dart';
import '../repositories/santa_fe_series_repository.dart';
import '../repositories/soil_map_repository.dart';
import '../services/pdf_soil_sheet_favorites_service.dart';
import '../utils/app_motion.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/responsive_desktop_shell.dart';
import '../widgets/scrollable_empty_state.dart';
import 'pdf_viewer_screen.dart';

class SoilMapsScreen extends StatefulWidget {
  const SoilMapsScreen({this.soilMapsLoader, this.santaFeCardsLoader, super.key});

  /// Buenos Aires' catalog loader. Optional and additive — unchanged since
  /// before Santa Fe Fase 7, so existing test fixtures keep working as-is.
  final Future<List<SoilMap>> Function()? soilMapsLoader;

  /// Santa Fe's catalog loader, already mapped to [SoilCard]s (each series
  /// carries its own page range, unlike [soilMapsLoader]'s [SoilMap]s).
  /// Defaults to the real [SantaFeSeriesRepository]-backed catalog.
  final Future<List<SoilCard>> Function()? santaFeCardsLoader;

  @override
  State<SoilMapsScreen> createState() => _SoilMapsScreenState();
}

class _SoilMapsScreenState extends State<SoilMapsScreen> {
  static const String _missingPdfMessage = 'Carta de suelo no disponible';

  final SoilMapRepository _soilMapRepository = const SoilMapRepository();
  final PdfSoilSheetFavoritesService _favoritesService =
      PdfSoilSheetFavoritesService();
  late final Future<List<SoilCard>> _soilCardsFuture;
  List<PdfSoilSheetFavorite> _favorites = const [];
  Set<String> _favoritePdfIdentifiers = const {};
  final Map<SoilCard, String> _searchNames = Map.identity();
  final ValueNotifier<String> _searchQuery = ValueNotifier('');
  final ValueNotifier<SoilCardProvince?> _provinceFilter = ValueNotifier(
    null,
  );

  @override
  void initState() {
    super.initState();
    _soilCardsFuture = _loadCatalog();
    _loadFavorites();
  }

  Future<List<SoilCard>> _loadCatalog() async {
    final buenosAiresCards =
        (widget.soilMapsLoader ?? _soilMapRepository.loadSoilMaps)().then(
      (soilMaps) => [for (final soilMap in soilMaps) SoilCard.buenosAires(soilMap)],
    );
    final santaFeCards = (widget.santaFeCardsLoader ?? _loadSantaFeCards)();
    final results = await Future.wait([buenosAiresCards, santaFeCards]);
    final cards = [...results[0], ...results[1]]
      ..sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    for (final card in cards) {
      _searchNames[card] = _normalizeForSearch(card.title);
    }
    return cards;
  }

  static Future<List<SoilCard>> _loadSantaFeCards() async {
    final repository = SantaFeSeriesRepository();
    final entries = await repository.loadAllSeries();
    final pdfAsset = await repository.pdfAsset;
    return [
      for (final entry in entries) SoilCard.santaFe(entry, pdfAsset: pdfAsset),
    ];
  }

  @override
  void dispose() {
    _searchQuery.dispose();
    _provinceFilter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return FloatingHeaderScaffold(
      collapseHeaderForAndroidPhoneLandscapeKeyboard: true,
      header: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingAppBarBackButton(
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 14),
          const FloatingAppBarTitle('Cartas de suelo'),
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
                      onSubmitted: logSubmittedSearch,
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
                  _SoilMapsSearchGap(isPhone: layout.isPhone),
                  ValueListenableBuilder<SoilCardProvince?>(
                    valueListenable: _provinceFilter,
                    builder: (context, provinceFilter, _) =>
                        _ProvinceFilterSection(
                          selected: provinceFilter,
                          onChanged: (value) =>
                              _provinceFilter.value = value,
                        ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<String>(
                      valueListenable: _searchQuery,
                      builder: (context, query, _) =>
                          ValueListenableBuilder<SoilCardProvince?>(
                            valueListenable: _provinceFilter,
                            builder: (context, provinceFilter, _) =>
                                FutureBuilder<List<SoilCard>>(
                            future: _soilCardsFuture,
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

                              final soilMaps = _filterSoilCards(
                                snapshot.data ?? const [],
                                query,
                                provinceFilter,
                              );
                              if (soilMaps.isEmpty) {
                                return const _EmptySoilMapSearch();
                              }

                              final favoriteMaps = soilMaps
                                  .where(_isFavorite)
                                  .toList(growable: false);
                              // A favorited carta only shows in "Favoritos"
                              // — it's excluded here so it isn't listed
                              // twice on screen. This is purely a display
                              // filter: favoriteIdentifier already
                              // distinguishes cards by province (so a BA
                              // and an SF carta sharing a name never
                              // collide here), and nothing about
                              // persistence, IDs, or province logic
                              // changes.
                              final nonFavoriteMaps = soilMaps
                                  .where((soilMap) => !_isFavorite(soilMap))
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
                                    itemCount: nonFavoriteMaps.length,
                                    itemBuilder: (context, index) =>
                                        _buildSoilMapItem(
                                          context,
                                          nonFavoriteMaps[index],
                                          colorScheme,
                                        ),
                                    separatorBuilder: (context, index) =>
                                        const SizedBox(height: 10),
                                  ),
                                  const SliverToBoxAdapter(
                                    child: _SoilMapListBottomClearance(),
                                  ),
                                ],
                              );
                            },
                          ),
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
    SoilCard soilCard,
    ColorScheme colorScheme,
  ) {
    final isFavorite = _isFavorite(soilCard);
    return Material(
      key: ValueKey('soil-card-${soilCard.favoriteIdentifier}'),
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
        onTap: () => _openSoilCardPdf(context, soilCard),
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
          soilCard.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Align(
          alignment: AlignmentDirectional.centerStart,
          child: _ProvinceTag(province: soilCard.province),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: isFavorite
                  ? 'Quitar de favoritos'
                  : 'Agregar a favoritos',
              onPressed: () => _toggleFavorite(soilCard),
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
                // Favorited gets a soft circular backing (same soft-green
                // token as the leading PDF icon) so the active state reads
                // at a glance, not just from the icon's own fill/color.
                child: Container(
                  key: ValueKey(isFavorite),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isFavorite
                        ? colorScheme.primaryContainer.withValues(alpha: 0.55)
                        : Colors.transparent,
                  ),
                  child: Icon(
                    AppIcons.star,
                    color: isFavorite
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    fill: isFavorite ? 1 : 0,
                  ),
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

  bool _isFavorite(SoilCard soilCard) {
    return _favoritePdfIdentifiers.contains(soilCard.favoriteIdentifier.trim());
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

  Future<void> _toggleFavorite(SoilCard soilCard) async {
    final wasFavorite = _isFavorite(soilCard);
    final updated = await _favoritesService.toggle(
      _favorites,
      title: soilCard.title,
      pdfIdentifier: soilCard.favoriteIdentifier,
    );
    final updatedIdentifiers = _favoriteIdentifiers(updated);
    if (!wasFavorite &&
        updatedIdentifiers.contains(soilCard.favoriteIdentifier.trim())) {
      unawaited(AnalyticsService.instance.logFavoriteAdded());
    }
    if (mounted) {
      setState(() {
        _favorites = updated;
        _favoritePdfIdentifiers = updatedIdentifiers;
      });
    }
  }

  void _updateSearchQuery(String value) {
    _searchQuery.value = value;
  }

  List<SoilCard> _filterSoilCards(
    List<SoilCard> soilCards,
    String searchQuery,
    SoilCardProvince? provinceFilter,
  ) {
    final query = _normalizeForSearch(searchQuery.trim());

    return soilCards.where((soilCard) {
      if (provinceFilter != null && soilCard.province != provinceFilter) {
        return false;
      }
      if (query.isEmpty) {
        return true;
      }
      return (_searchNames[soilCard] ?? _normalizeForSearch(soilCard.title))
          .contains(query);
    }).toList(growable: false);
  }

  /// Lowercases and strips accents so searching "Rio Salado" (no tilde)
  /// still finds "Río Salado" — series names carry real accents (both
  /// provinces), but users typing on a phone keyboard often don't.
  static String _normalizeForSearch(String value) {
    var normalized = value.toLowerCase();
    for (final entry in _accentReplacements.entries) {
      normalized = normalized.replaceAll(entry.key, entry.value);
    }
    return normalized;
  }

  static const Map<String, String> _accentReplacements = {
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

  Set<String> _favoriteIdentifiers(List<PdfSoilSheetFavorite> favorites) =>
      favorites.map((favorite) => favorite.pdfIdentifier.trim()).toSet();

  Future<void> _openSoilCardPdf(BuildContext context, SoilCard soilCard) async {
    await openLocalPdfViewer(
      context,
      title: soilCard.title,
      assetPath: soilCard.location.assetPath,
      initialPage: soilCard.location.startPage,
      lastPage: soilCard.location.endPage,
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
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _SoilMapsSearchGap extends StatelessWidget {
  const _SoilMapsSearchGap({required this.isPhone});

  final bool isPhone;

  @override
  Widget build(BuildContext context) {
    final compactLandscapeKeyboard =
        isSuelosArAndroidPhoneLandscape(context) &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    return SizedBox(height: compactLandscapeKeyboard ? 8 : (isPhone ? 22 : 26));
  }
}

/// Display name for a [SoilCardProvince], shared by the catalog cards'
/// province tag and the filter chips so both stay in sync.
String _provinceDisplayName(SoilCardProvince province) {
  switch (province) {
    case SoilCardProvince.buenosAires:
      return 'Buenos Aires';
    case SoilCardProvince.santaFe:
      return 'Santa Fe';
  }
}

/// Accent color for a [SoilCardProvince]'s [_ProvinceTag]. Centralized here
/// so a future province only needs one more switch arm (alongside
/// [_provinceDisplayName]) — [_ProvinceTag] itself never changes.
/// Soft, muted tones consistent with SuelosAR's earthy palette, chosen to
/// read clearly as small text on a barely-tinted background (see
/// [_ProvinceTag]) rather than as a saturated/loud color.
Color _provinceAccentColor(SoilCardProvince province) {
  switch (province) {
    case SoilCardProvince.buenosAires:
      return const Color(0xFF4A6FA5);
    case SoilCardProvince.santaFe:
      return const Color(0xFF9C6B3F);
  }
}

/// The province metadata tag shown under a catalog card's title — replaces
/// what used to be a plain `Text` subtitle. Deliberately plain (no
/// `Material`/`InkWell`, no icon, no shadow): it reads as metadata, not as
/// an interactive control.
class _ProvinceTag extends StatelessWidget {
  const _ProvinceTag({required this.province});

  final SoilCardProvince province;

  @override
  Widget build(BuildContext context) {
    final color = _provinceAccentColor(province);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _provinceDisplayName(province),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
    );
  }
}

/// Collapses [_ProvinceFilterChips] to zero height on narrow Android phones
/// in landscape — the same cramped-viewport condition [_SoilMapsSearchGap]
/// already shrinks for (though that one only during the keyboard-up case;
/// this one always in landscape, since even without a keyboard there isn't
/// enough height left for an extra always-on row once the floating header,
/// search bar, and their gaps are accounted for). Everywhere else — phone
/// portrait, tablet, desktop — the filter renders normally.
class _ProvinceFilterSection extends StatelessWidget {
  const _ProvinceFilterSection({required this.selected, required this.onChanged});

  final SoilCardProvince? selected;
  final ValueChanged<SoilCardProvince?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (isSuelosArAndroidPhoneLandscape(context)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _ProvinceFilterChips(selected: selected, onChanged: onChanged),
    );
  }
}

/// Filters the "Memorias descriptivas" catalog by province: a horizontally
/// scrollable row of pill chips — "Todas" first, then one chip per
/// [SoilCardProvince] value. Never touches the GIS map's own province
/// switch (`ProvinceConfig`).
///
/// Built from [SoilCardProvince.values] rather than any hardcoded chip
/// list, so a future province only needs a new enum value (and its
/// [_provinceDisplayName] entry) — this row, its scrolling, and its
/// selection handling need no changes.
class _ProvinceFilterChips extends StatelessWidget {
  const _ProvinceFilterChips({required this.selected, required this.onChanged});

  final SoilCardProvince? selected;
  final ValueChanged<SoilCardProvince?> onChanged;

  @override
  Widget build(BuildContext context) {
    final provinces = <SoilCardProvince?>[null, ...SoilCardProvince.values];
    return SizedBox(
      height: 42,
      child: ListView.separated(
        key: const ValueKey('province-filter-chips'),
        scrollDirection: Axis.horizontal,
        itemCount: provinces.length,
        separatorBuilder: (context, index) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final province = provinces[index];
          return _ProvinceChip(
            key: ValueKey('province-chip-${province?.name ?? 'todas'}'),
            label: province == null ? 'Todas' : _provinceDisplayName(province),
            selected: province == selected,
            onTap: () => onChanged(province),
          );
        },
      ),
    );
  }
}

class _ProvinceChip extends StatelessWidget {
  const _ProvinceChip({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colorScheme.primaryContainer.withValues(alpha: 0.55)
          : colorScheme.surface,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? colorScheme.primary : colorScheme.outlineVariant,
          width: selected ? 1.4 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            widthFactor: 1,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                AnimatedSwitcher(
                  duration: AppMotion.duration(
                    context,
                    const Duration(milliseconds: 160),
                    reduced: const Duration(milliseconds: 40),
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SizeTransition(
                      sizeFactor: animation,
                      axis: Axis.horizontal,
                      child: Center(child: child),
                    ),
                  ),
                  child: selected
                      ? Padding(
                          key: const ValueKey(true),
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            AppIcons.check,
                            size: 13,
                            color: colorScheme.primary,
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey(false)),
                ),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
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

class _SoilMapListBottomClearance extends StatelessWidget {
  const _SoilMapListBottomClearance();

  @override
  Widget build(BuildContext context) {
    final keyboardInset = isSuelosArCompactAndroidPortrait(context)
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    return SizedBox(
      key: const ValueKey('soil-maps-keyboard-clearance'),
      height: 24 + keyboardInset,
    );
  }
}
