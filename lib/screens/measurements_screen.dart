import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_icons.dart';
import '../export/measurement_export.dart';
import '../models/saved_measurement.dart';
import '../widgets/app_notification.dart';
import '../widgets/destructive_action_confirmation.dart';
import '../widgets/saved_measurement_overflow_menu.dart';
import '../widgets/scrollable_empty_state.dart';

class MeasurementsScreen extends StatefulWidget {
  const MeasurementsScreen({super.key});

  @override
  State<MeasurementsScreen> createState() => _MeasurementsScreenState();
}

class _MeasurementsScreenState extends State<MeasurementsScreen>
    with SingleTickerProviderStateMixin {
  List<SavedMeasurement>? _measurements;

  @override
  void initState() {
    super.initState();
    _loadMeasurements();
  }

  @override
  Widget build(BuildContext context) {
    final measurementsLoaded = _measurements != null;
    final compactActions = MediaQuery.sizeOf(context).width < 500;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Mediciones',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: compactActions
              ? [
                  IconButton(
                    tooltip: 'Mostrar todas',
                    onPressed: measurementsLoaded
                        ? () => _setAllVisibility(true)
                        : null,
                    icon: const Icon(AppIcons.visibility),
                  ),
                  IconButton(
                    tooltip: 'Ocultar todas',
                    onPressed: measurementsLoaded
                        ? () => _setAllVisibility(false)
                        : null,
                    icon: const Icon(AppIcons.visibilityOff),
                  ),
                  const SizedBox(width: 8),
                ]
              : [
                  TextButton(
                    onPressed: measurementsLoaded
                        ? () => _setAllVisibility(true)
                        : null,
                    child: const Text('Mostrar todas'),
                  ),
                  TextButton(
                    onPressed: measurementsLoaded
                        ? () => _setAllVisibility(false)
                        : null,
                    child: const Text('Ocultar todas'),
                  ),
                  const SizedBox(width: 8),
                ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Áreas'),
              Tab(text: 'Distancias'),
            ],
          ),
        ),
        body: _measurements == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _buildList(SavedMeasurementType.area),
                  _buildList(SavedMeasurementType.distance),
                ],
              ),
      ),
    );
  }

  Widget _buildList(SavedMeasurementType type) {
    final measurements = _measurements!
        .where((measurement) => measurement.type == type)
        .toList(growable: false);
    if (measurements.isEmpty) {
      return _EmptyMeasurements(type: type);
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: measurements.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final measurement = measurements[index];
        return ListTile(
          leading: Icon(
            type == SavedMeasurementType.area
                ? AppIcons.analytics
                : AppIcons.ruler,
          ),
          title: Text(measurement.name),
          onTap: measurement.isVisible
              ? () => Navigator.of(context).pop(measurement)
              : null,
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _formatValue(measurement),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text(
                _formatDate(measurement.createdAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          trailing: Row(
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
                onPressed: () => _toggleVisibility(measurement),
              ),
              IconButton(
                key: ValueKey('rename-measurement-${measurement.id}'),
                tooltip: 'Renombrar',
                icon: const Icon(AppIcons.edit),
                onPressed: () => _renameMeasurement(measurement),
              ),
              SavedMeasurementOverflowMenu(
                key: ValueKey('measurement-overflow-${measurement.id}'),
                onExportPdf: () => _exportMeasurement(
                  measurement,
                  _MeasurementExportFormat.pdf,
                ),
                onExportGeoJson: () => _exportMeasurement(
                  measurement,
                  _MeasurementExportFormat.geoJson,
                ),
                onExportCsv: () => _exportMeasurement(
                  measurement,
                  _MeasurementExportFormat.csv,
                ),
                onDelete: () => _deleteMeasurement(measurement),
              ),
            ],
          ),
        );
      },
    );
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
    if (mounted) setState(() => _measurements = measurements);
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
    setState(() => _measurements![index] = measurement.copyWith(name: name));
    await _persistMeasurements();
  }

  Future<void> _deleteMeasurement(SavedMeasurement measurement) async {
    final confirmed = await confirmDestructiveAction(
      context,
      title: '¿Eliminar medición?',
      message: 'Esta acción elimina la medición permanentemente.',
    );
    if (!mounted || !confirmed) return;
    setState(
      () => _measurements!.removeWhere((item) => item.id == measurement.id),
    );
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
      () => _measurements![index] = measurement.copyWith(
        isVisible: !measurement.isVisible,
      ),
    );
    await _persistMeasurements();
  }

  Future<void> _setAllVisibility(bool isVisible) async {
    final measurements = _measurements;
    if (measurements == null) return;
    setState(() {
      for (var index = 0; index < measurements.length; index++) {
        measurements[index] = measurements[index].copyWith(
          isVisible: isVisible,
        );
      }
    });
    await _persistMeasurements();
  }

  Future<void> _persistMeasurements() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      SavedMeasurement.storageKey,
      _measurements!
          .map((measurement) => jsonEncode(measurement.toJson()))
          .toList(growable: false),
    );
  }

  String _formatValue(SavedMeasurement measurement) {
    if (measurement.type == SavedMeasurementType.distance) {
      return _formatDistance(measurement.distanceMeters ?? 0);
    }
    final area = measurement.areaSquareMeters ?? 0;
    final areaLabel = area >= 10000
        ? '${(area / 10000).toStringAsFixed(1)} ha'
        : '${area.toStringAsFixed(0)} m²';
    return '$areaLabel · Perímetro ${_formatDistance(measurement.perimeterMeters ?? 0)}';
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

class _EmptyMeasurements extends StatelessWidget {
  const _EmptyMeasurements({required this.type});

  final SavedMeasurementType type;

  @override
  Widget build(BuildContext context) {
    final isArea = type == SavedMeasurementType.area;
    return ScrollableEmptyState(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isArea ? AppIcons.analytics : AppIcons.ruler,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              isArea ? 'Todavía no hay áreas' : 'Todavía no hay distancias',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Guarda mediciones desde el mapa para encontrarlas acá.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
