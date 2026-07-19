import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_icons.dart';
import '../export/measurement_export.dart';
import '../models/saved_measurement.dart';
import '../repositories/sync_aware_local_repository.dart';
import '../widgets/app_notification.dart';
import '../widgets/destructive_action_confirmation.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/saved_measurement_overflow_menu.dart';
import '../widgets/scrollable_empty_state.dart';

class MeasurementsScreen extends StatefulWidget {
  const MeasurementsScreen({super.key});

  @override
  State<MeasurementsScreen> createState() => _MeasurementsScreenState();
}

class _MeasurementsScreenState extends State<MeasurementsScreen> {
  List<SavedMeasurement>? _measurements;
  final ValueNotifier<String> _searchQuery = ValueNotifier('');
  final Map<String, String> _searchNames = {};
  _MeasurementFilter _selectedFilter = _MeasurementFilter.all;

  @override
  void initState() {
    super.initState();
    _loadMeasurements();
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
          const FloatingAppBarTitle('Mediciones'),
          const SizedBox(width: 10),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FloatingAppBarCard(
            padding: EdgeInsets.zero,
            child: SearchBar(
              onChanged: (value) => _searchQuery.value = value,
              hintText: 'Buscar medición...',
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
          const SizedBox(height: 16),
          _buildFilterToolbar(),
          const SizedBox(height: 18),
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
    final measurements = _measurements;
    if (measurements == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final filteredMeasurements = _filterMeasurements(measurements, query);
    if (filteredMeasurements.isEmpty) {
      return _EmptyMeasurements(
        filter: _selectedFilter,
        isSearchResult: query.trim().isNotEmpty,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView.separated(
            addAutomaticKeepAlives: false,
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 20),
            itemCount: filteredMeasurements.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) => _MeasurementCard(
              measurement: filteredMeasurements[index],
              formatArea: _formatArea,
              formatDistance: _formatDistance,
              formatDate: _formatDate,
              onTap: () =>
                  Navigator.of(context).pop(filteredMeasurements[index]),
              onToggleVisibility: () =>
                  _toggleVisibility(filteredMeasurements[index]),
              onRename: () => _renameMeasurement(filteredMeasurements[index]),
              overflowMenu: SavedMeasurementOverflowMenu(
                key: ValueKey(
                  'measurement-overflow-${filteredMeasurements[index].id}',
                ),
                onExportPdf: () => _exportMeasurement(
                  filteredMeasurements[index],
                  _MeasurementExportFormat.pdf,
                ),
                onExportGeoJson: () => _exportMeasurement(
                  filteredMeasurements[index],
                  _MeasurementExportFormat.geoJson,
                ),
                onExportCsv: () => _exportMeasurement(
                  filteredMeasurements[index],
                  _MeasurementExportFormat.csv,
                ),
                onDelete: () => _deleteMeasurement(filteredMeasurements[index]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterToolbar() {
    final filters = SegmentedButton<_MeasurementFilter>(
      segments: const [
        ButtonSegment(value: _MeasurementFilter.all, label: Text('Todas')),
        ButtonSegment(value: _MeasurementFilter.areas, label: Text('Áreas')),
        ButtonSegment(
          value: _MeasurementFilter.distances,
          label: Text('Distancias'),
        ),
      ],
      selected: {_selectedFilter},
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
      onSelectionChanged: (selection) {
        setState(() => _selectedFilter = selection.first);
      },
    );
    final visibilityMenu = _VisibilityActionsMenu(
      enabled: _measurements != null,
      onShowAll: () => _setAllVisibility(true),
      onHideAll: () => _setAllVisibility(false),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              filters,
              const SizedBox(height: 4),
              Align(alignment: Alignment.centerRight, child: visibilityMenu),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: filters),
            const SizedBox(width: 8),
            visibilityMenu,
          ],
        );
      },
    );
  }

  List<SavedMeasurement> _filterMeasurements(
    List<SavedMeasurement> measurements,
    String searchQuery,
  ) {
    final query = _normalize(searchQuery.trim());
    return measurements
        .where((measurement) {
          final matchesType = switch (_selectedFilter) {
            _MeasurementFilter.all => true,
            _MeasurementFilter.areas =>
              measurement.type == SavedMeasurementType.area,
            _MeasurementFilter.distances =>
              measurement.type == SavedMeasurementType.distance,
          };
          return matchesType &&
              (query.isEmpty ||
                  (_searchNames[measurement.id] ?? _normalize(measurement.name))
                      .contains(query));
        })
        .toList(growable: false);
  }

  String _formatArea(SavedMeasurement measurement) {
    final area = measurement.areaSquareMeters ?? 0;
    return area >= 10000
        ? '${(area / 10000).toStringAsFixed(1)} ha'
        : '${area.toStringAsFixed(0)} m²';
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

  Future<void> _loadMeasurements() async {
    final preferences = await SharedPreferences.getInstance();
    final measurements = <SavedMeasurement>[];
    for (final encoded
        in preferences.getStringList(SavedMeasurement.storageKey) ??
            const <String>[]) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map<String, dynamic>) {
          measurements.add(SavedMeasurement.fromJson(decoded));
        }
      } catch (_) {
        // Keep valid measurements available if one local record is malformed.
      }
    }
    if (mounted) {
      _rebuildSearchNames(measurements);
      setState(() => _measurements = measurements);
    }
  }

  Future<void> _renameMeasurement(SavedMeasurement measurement) async {
    var editedName = measurement.name;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Renombrar medición'),
        content: TextFormField(
          initialValue: measurement.name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nombre'),
          onChanged: (value) => editedName = value,
          onFieldSubmitted: (value) =>
              Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, editedName.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;

    final index = _measurements!.indexWhere(
      (item) => item.id == measurement.id,
    );
    if (index == -1) return;
    setState(() {
      final updated = measurement.copyWith(name: name);
      _measurements![index] = updated;
      _searchNames[updated.id] = _normalize(updated.name);
    });
    await _persistMeasurements();
  }

  Future<void> _deleteMeasurement(SavedMeasurement measurement) async {
    final confirmed = await confirmDestructiveAction(
      context,
      title: '¿Eliminar medición?',
      message: 'Esta acción elimina la medición permanentemente.',
    );
    if (!mounted || !confirmed) return;
    setState(() {
      _measurements!.removeWhere((item) => item.id == measurement.id);
      _searchNames.remove(measurement.id);
    });
    await _persistMeasurements();
  }

  Future<void> _exportMeasurement(
    SavedMeasurement measurement,
    _MeasurementExportFormat format,
  ) async {
    final exportData = const MeasurementExportService().fromSavedMeasurement(
      measurement,
    );
    try {
      switch (format) {
        case _MeasurementExportFormat.pdf:
          final file = await MeasurementPdfExporter().export(exportData);
          await const MeasurementExportShareService().share(
            file: file,
            mimeType: 'application/pdf',
            text: 'Informe de medición de SuelosAR',
          );
        case _MeasurementExportFormat.geoJson:
          final file = await const MeasurementGeoJsonExporter().export(
            exportData,
          );
          await const MeasurementExportShareService().share(
            file: file,
            mimeType: 'application/geo+json',
            text: 'Medición de SuelosAR en GeoJSON',
          );
        case _MeasurementExportFormat.csv:
          final file = await const MeasurementCsvExporter().export(exportData);
          await const MeasurementExportShareService().share(
            file: file,
            mimeType: 'text/csv',
            text: 'Medición de SuelosAR en CSV',
          );
      }
    } catch (_) {
      if (!mounted) return;
      unawaited(
        AppNotification.show(
          context,
          message: 'No se pudo exportar la medición.',
          type: AppNotificationType.error,
        ),
      );
    }
  }

  Future<void> _toggleVisibility(SavedMeasurement measurement) async {
    final index = _measurements!.indexWhere(
      (item) => item.id == measurement.id,
    );
    if (index == -1) return;
    setState(
      () => _measurements![index] = measurement.withLocalVisibility(
        !measurement.isVisible,
      ),
    );
    await _persistMeasurements();
  }

  Future<void> _setAllVisibility(bool isVisible) async {
    final measurements = _measurements;
    if (measurements == null) return;
    setState(() {
      for (var index = 0; index < measurements.length; index++) {
        measurements[index] = measurements[index].withLocalVisibility(
          isVisible,
        );
      }
    });
    await _persistMeasurements();
  }

  Future<void> _persistMeasurements() async {
    await SyncAwareLocalRepository.instance.saveMeasurements(_measurements!);
  }

  void _rebuildSearchNames(List<SavedMeasurement> measurements) {
    _searchNames
      ..clear()
      ..addEntries(
        measurements.map(
          (measurement) =>
              MapEntry(measurement.id, _normalize(measurement.name)),
        ),
      );
  }

  String _formatDistance(double meters) {
    return meters < 1000
        ? '${meters.toStringAsFixed(0)} m'
        : '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _formatDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${twoDigits(value.day)}/${twoDigits(value.month)}/${value.year} '
        '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }
}

enum _MeasurementExportFormat { pdf, geoJson, csv }

enum _MeasurementFilter { all, areas, distances }

class _VisibilityActionsMenu extends StatelessWidget {
  const _VisibilityActionsMenu({
    required this.enabled,
    required this.onShowAll,
    required this.onHideAll,
  });

  final bool enabled;
  final VoidCallback onShowAll;
  final VoidCallback onHideAll;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<bool>(
      tooltip: 'Visibilidad de mediciones',
      enabled: enabled,
      icon: const Icon(AppIcons.moreVertical),
      onSelected: (show) => show ? onShowAll() : onHideAll(),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: true,
          child: _VisibilityMenuItem(
            icon: AppIcons.visibility,
            label: 'Mostrar todas',
          ),
        ),
        PopupMenuItem(
          value: false,
          child: _VisibilityMenuItem(
            icon: AppIcons.visibilityOff,
            label: 'Ocultar todas',
          ),
        ),
      ],
    );
  }
}

class _VisibilityMenuItem extends StatelessWidget {
  const _VisibilityMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)],
    );
  }
}

class _MeasurementCard extends StatelessWidget {
  const _MeasurementCard({
    required this.measurement,
    required this.formatArea,
    required this.formatDistance,
    required this.formatDate,
    required this.onTap,
    required this.onToggleVisibility,
    required this.onRename,
    required this.overflowMenu,
  });

  final SavedMeasurement measurement;
  final String Function(SavedMeasurement measurement) formatArea;
  final String Function(double meters) formatDistance;
  final String Function(DateTime value) formatDate;
  final VoidCallback onTap;
  final VoidCallback onToggleVisibility;
  final VoidCallback onRename;
  final Widget overflowMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isArea = measurement.type == SavedMeasurementType.area;
    final icon = isArea ? AppIcons.analytics : AppIcons.ruler;
    final value = isArea
        ? formatArea(measurement)
        : formatDistance(measurement.distanceMeters ?? 0);

    return Material(
      color: Colors.white,
      elevation: 1,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.1),
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: measurement.isVisible ? onTap : null,
        mouseCursor: measurement.isVisible
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        hoverColor: colorScheme.surfaceContainerHigh,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stackActions = constraints.maxWidth < 340;
            final details = _MeasurementDetails(
              isArea: isArea,
              value: value,
              perimeter: formatDistance(measurement.perimeterMeters ?? 0),
              date: formatDate(measurement.createdAt),
            );
            final actions = _MeasurementActions(
              measurement: measurement,
              onToggleVisibility: onToggleVisibility,
              onRename: onRename,
              overflowMenu: overflowMenu,
            );

            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (stackActions) ...[
                    _MeasurementIdentity(
                      icon: icon,
                      name: measurement.name,
                      isVisible: measurement.isVisible,
                    ),
                    const SizedBox(height: 2),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ] else
                    Row(
                      children: [
                        Expanded(
                          child: _MeasurementIdentity(
                            icon: icon,
                            name: measurement.name,
                            isVisible: measurement.isVisible,
                          ),
                        ),
                        actions,
                      ],
                    ),
                  const SizedBox(height: 10),
                  details,
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MeasurementIdentity extends StatelessWidget {
  const _MeasurementIdentity({
    required this.icon,
    required this.name,
    required this.isVisible,
  });

  final IconData icon;
  final String name;
  final bool isVisible;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            icon,
            size: 21,
            color: isVisible
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _MeasurementActions extends StatelessWidget {
  const _MeasurementActions({
    required this.measurement,
    required this.onToggleVisibility,
    required this.onRename,
    required this.overflowMenu,
  });

  final SavedMeasurement measurement;
  final VoidCallback onToggleVisibility;
  final VoidCallback onRename;
  final Widget overflowMenu;

  @override
  Widget build(BuildContext context) {
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('visibility-measurement-${measurement.id}'),
            tooltip: measurement.isVisible ? 'Ocultar' : 'Mostrar',
            icon: Icon(
              measurement.isVisible
                  ? AppIcons.visibility
                  : AppIcons.visibilityOff,
            ),
            onPressed: onToggleVisibility,
          ),
          IconButton(
            key: ValueKey('rename-measurement-${measurement.id}'),
            tooltip: 'Renombrar',
            icon: const Icon(AppIcons.edit),
            onPressed: onRename,
          ),
          overflowMenu,
        ],
      ),
    );
  }
}

class _MeasurementDetails extends StatelessWidget {
  const _MeasurementDetails({
    required this.isArea,
    required this.value,
    required this.perimeter,
    required this.date,
  });

  final bool isArea;
  final String value;
  final String perimeter;
  final String date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 300;
        final valueText = Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            color: colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        );
        final typeBadge = _MeasurementTypeBadge(isArea: isArea);
        final dateText = Text(
          date,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: secondaryStyle,
        );
        final perimeterText = Text(
          'Perímetro $perimeter',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: secondaryStyle,
        );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: valueText),
                  const SizedBox(width: 8),
                  typeBadge,
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  if (isArea) Expanded(child: perimeterText),
                  if (isArea) const SizedBox(width: 8),
                  Expanded(child: dateText),
                ],
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: valueText),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                typeBadge,
                const SizedBox(height: 3),
                if (isArea) perimeterText,
                dateText,
              ],
            ),
          ],
        );
      },
    );
  }
}

class _MeasurementTypeBadge extends StatelessWidget {
  const _MeasurementTypeBadge({required this.isArea});

  final bool isArea;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        isArea ? 'Área' : 'Distancia',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyMeasurements extends StatelessWidget {
  const _EmptyMeasurements({
    required this.filter,
    required this.isSearchResult,
  });

  final _MeasurementFilter filter;
  final bool isSearchResult;

  @override
  Widget build(BuildContext context) {
    final isArea = filter == _MeasurementFilter.areas;
    final isDistance = filter == _MeasurementFilter.distances;
    final icon = isArea
        ? AppIcons.analytics
        : isDistance
        ? AppIcons.ruler
        : AppIcons.searchOff;
    final title = isSearchResult
        ? 'No se encontraron mediciones.'
        : isArea
        ? 'Todavía no hay áreas'
        : isDistance
        ? 'Todavía no hay distancias'
        : 'Todavía no hay mediciones';
    return ScrollableEmptyState(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              isSearchResult
                  ? 'Probá con otro nombre o cambiá el filtro.'
                  : 'Guardá mediciones desde el mapa para encontrarlas acá.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
