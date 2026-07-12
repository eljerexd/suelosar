import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_icons.dart';
import '../models/personal_marker.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/destructive_action_confirmation.dart';
import '../widgets/personal_marker_category_icon.dart';
import '../widgets/scrollable_empty_state.dart';

class PersonalMarkersScreen extends StatefulWidget {
  const PersonalMarkersScreen({super.key});

  @override
  State<PersonalMarkersScreen> createState() => _PersonalMarkersScreenState();
}

class _PersonalMarkersScreenState extends State<PersonalMarkersScreen> {
  List<PersonalMarker>? _markers;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadMarkers();
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
          const FloatingAppBarTitle('Marcadores personales'),
          const SizedBox(width: 10),
        ],
      ),
      body: Column(
        children: [
          FloatingAppBarCard(
            padding: EdgeInsets.zero,
            child: SearchBar(
              onChanged: (value) => setState(() => _searchQuery = value),
              hintText: 'Buscar marcador...',
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
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final markers = _markers;
    if (markers == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (markers.isEmpty) {
      return const _EmptyPersonalMarkers();
    }

    final filteredMarkers = _filterMarkers(markers);
    if (filteredMarkers.isEmpty) {
      return const _NoMarkerSearchResults();
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 20),
      itemCount: filteredMarkers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final marker = filteredMarkers[index];
        final description = marker.description.split(RegExp(r'\r?\n')).first;
        final colorScheme = Theme.of(context).colorScheme;
        return Material(
          color: Colors.white,
          elevation: 1,
          shadowColor: colorScheme.shadow.withValues(alpha: 0.1),
          surfaceTintColor: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            mouseCursor: SystemMouseCursors.click,
            hoverColor: colorScheme.surfaceContainerHigh,
            leading: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                personalMarkerCategoryIcon(marker.category),
                color: Colors.red,
                size: 22,
              ),
            ),
            title: Text(
              marker.name,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    marker.category.label,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 5),
                  Text(
                    '${marker.latitude.toStringAsFixed(6)}, '
                    '${marker.longitude.toStringAsFixed(6)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatDate(marker.createdAt),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            onTap: () => Navigator.of(context).pop(marker.id),
            trailing: IconButton(
              key: ValueKey('delete-personal-marker-${marker.id}'),
              tooltip: 'Eliminar marcador',
              icon: const Icon(AppIcons.delete),
              onPressed: () => _deleteMarker(marker),
            ),
          ),
        );
      },
    );
  }

  List<PersonalMarker> _filterMarkers(List<PersonalMarker> markers) {
    final query = _normalize(_searchQuery.trim());
    if (query.isEmpty) return markers;
    return markers
        .where(
          (marker) =>
              _normalize(marker.name).contains(query) ||
              _normalize(marker.description).contains(query) ||
              _normalize(marker.category.label).contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _loadMarkers() async {
    final preferences = await SharedPreferences.getInstance();
    final markers = <PersonalMarker>[];
    for (final encoded
        in preferences.getStringList(PersonalMarker.storageKey) ??
            const <String>[]) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map<String, dynamic>) {
          markers.add(PersonalMarker.fromJson(decoded));
        }
      } catch (_) {
        // Preserve valid local markers if one stored entry is malformed.
      }
    }
    if (mounted) setState(() => _markers = markers);
  }

  Future<void> _deleteMarker(PersonalMarker marker) async {
    final markers = _markers;
    if (markers == null) return;
    final confirmed = await confirmDestructiveAction(
      context,
      title: '¿Eliminar marcador?',
      message: 'Se eliminará "${marker.name}" permanentemente.',
    );
    if (!mounted || !confirmed) return;
    setState(() => markers.removeWhere((item) => item.id == marker.id));
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      PersonalMarker.storageKey,
      markers.map((item) => jsonEncode(item.toJson())).toList(growable: false),
    );
  }

  String _formatDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${twoDigits(value.day)}/${twoDigits(value.month)}/${value.year} '
        '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }

  String _normalize(String value) {
    const accents = 'áàäâãéèëêíìïîóòöôõúùüûñ';
    const plain = 'aaaaaeeeeiiiiooooouuuun';
    final buffer = StringBuffer();
    for (final character in value.toLowerCase().split('')) {
      final index = accents.indexOf(character);
      buffer.write(index == -1 ? character : plain[index]);
    }
    return buffer.toString();
  }
}

class _EmptyPersonalMarkers extends StatelessWidget {
  const _EmptyPersonalMarkers();

  @override
  Widget build(BuildContext context) {
    return ScrollableEmptyState(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.location,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Todavía no hay marcadores personales.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Creá marcadores desde el mapa para encontrarlos acá.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _NoMarkerSearchResults extends StatelessWidget {
  const _NoMarkerSearchResults();

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
              'No se encontraron marcadores.',
              textAlign: TextAlign.center,
              style: textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
