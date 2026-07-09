import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_icons.dart';
import '../models/favorite_soil_feature.dart';
import '../models/soil_map.dart';
import '../repositories/soil_map_repository.dart';
import '../utils/app_motion.dart';
import '../widgets/floating_app_bar_card.dart';
import 'pdf_viewer_screen.dart';

class SoilMapsScreen extends StatefulWidget {
  const SoilMapsScreen({super.key});

  @override
  State<SoilMapsScreen> createState() => _SoilMapsScreenState();
}

class _SoilMapsScreenState extends State<SoilMapsScreen> {
  static const String _missingPdfMessage = 'Carta de suelo no disponible';

  final SoilMapRepository _soilMapRepository = const SoilMapRepository();
  late final Future<List<SoilMap>> _soilMapsFuture;
  List<FavoriteSoilFeature> _favorites = const [];
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _soilMapsFuture = _soilMapRepository.loadSoilMaps();
    _loadFavorites();
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
          Text(
            'Memorias descriptivas',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Column(
        children: [
          FloatingAppBarCard(
            padding: EdgeInsets.zero,
            child: SearchBar(
              onChanged: _updateSearchQuery,
              hintText: 'Buscar carta de suelo...',
              leading: const Icon(AppIcons.search),
              elevation: const WidgetStatePropertyAll(0),
              backgroundColor: const WidgetStatePropertyAll(Colors.white),
              surfaceTintColor: const WidgetStatePropertyAll(
                Colors.transparent,
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 18),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Expanded(
            child: FutureBuilder<List<SoilMap>>(
              future: _soilMapsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return const _SoilMapLoadError();
                }

                final soilMaps = _filterSoilMaps(snapshot.data ?? const []);
                if (soilMaps.isEmpty) {
                  return const _EmptySoilMapSearch();
                }

                final favoriteMaps = soilMaps
                    .where(_isFavorite)
                    .toList(growable: false);
                return ListView(
                  padding: const EdgeInsets.only(top: 4),
                  children: [
                    AnimatedSize(
                      duration: AppMotion.duration(
                        context,
                        const Duration(milliseconds: 220),
                        reduced: const Duration(milliseconds: 60),
                      ),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: Column(
                        children: [
                          _SectionTitle(
                            icon: AppIcons.star,
                            title: 'Favoritos (${favoriteMaps.length})',
                          ),
                          const SizedBox(height: 8),
                          if (favoriteMaps.isEmpty)
                            const _EmptyFavorites()
                          else
                            ..._buildSoilMapItems(
                              context,
                              favoriteMaps,
                              colorScheme,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 30),
                    const _SectionTitle(
                      icon: AppIcons.library,
                      title: 'Todas las cartas',
                    ),
                    const SizedBox(height: 8),
                    ..._buildSoilMapItems(context, soilMaps, colorScheme),
                    const SizedBox(height: 20),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSoilMapItems(
    BuildContext context,
    List<SoilMap> soilMaps,
    ColorScheme colorScheme,
  ) {
    final theme = Theme.of(context);
    return [
      for (var index = 0; index < soilMaps.length; index++) ...[
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 3,
          ),
          mouseCursor: SystemMouseCursors.click,
          hoverColor: colorScheme.surfaceContainerHigh,
          splashColor: colorScheme.primary.withValues(alpha: 0.08),
          onTap: () => _openSoilMapPdf(context, soilMaps[index]),
          title: Text(
            soilMaps[index].name,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: _isFavorite(soilMaps[index])
                    ? 'Quitar de favoritos'
                    : 'Agregar a favoritos',
                onPressed: () => _toggleFavorite(soilMaps[index]),
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
                    key: ValueKey(_isFavorite(soilMaps[index])),
                    color: _isFavorite(soilMaps[index])
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    fill: _isFavorite(soilMaps[index]) ? 1 : 0,
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
        if (index != soilMaps.length - 1)
          Divider(height: 1, thickness: 0.5, color: colorScheme.outlineVariant),
      ],
    ];
  }

  bool _isFavorite(SoilMap soilMap) {
    return _favorites.any((favorite) {
      final pdf = favorite.pdfIdentifier?.trim();
      return pdf == soilMap.pdf ||
          favorite.unitName == soilMap.name ||
          favorite.dominantSoilSeries == soilMap.name;
    });
  }

  Future<void> _loadFavorites() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded =
        preferences.getStringList(FavoriteSoilFeature.storageKey) ?? const [];
    final favorites = <FavoriteSoilFeature>[];
    for (final value in encoded) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) {
          favorites.add(FavoriteSoilFeature.fromJson(decoded));
        }
      } on FormatException {
        // Keep valid local favorites when one entry is malformed.
      }
    }
    if (mounted) {
      setState(() => _favorites = favorites);
    }
  }

  Future<void> _toggleFavorite(SoilMap soilMap) async {
    final updated = List<FavoriteSoilFeature>.of(_favorites);
    if (_isFavorite(soilMap)) {
      updated.removeWhere((favorite) {
        final pdf = favorite.pdfIdentifier?.trim();
        return pdf == soilMap.pdf ||
            favorite.unitName == soilMap.name ||
            favorite.dominantSoilSeries == soilMap.name;
      });
    } else {
      updated.add(
        FavoriteSoilFeature(
          id: 'soil-map:${soilMap.pdf}',
          unitName: soilMap.name,
          unitSymbol: '',
          soilSeries: [soilMap.name],
          pdfIdentifier: soilMap.pdf,
        ),
      );
    }
    setState(() => _favorites = updated);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      FavoriteSoilFeature.storageKey,
      updated.map((favorite) => jsonEncode(favorite.toJson())).toList(),
    );
  }

  void _updateSearchQuery(String value) {
    setState(() {
      _searchQuery = value;
    });
  }

  List<SoilMap> _filterSoilMaps(List<SoilMap> soilMaps) {
    final query = _searchQuery.trim().toLowerCase();

    if (query.isEmpty) {
      return soilMaps;
    }

    return soilMaps
        .where((soilMap) {
          return soilMap.name.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
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
    return Center(
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
    return Center(
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
