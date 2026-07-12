import 'package:flutter/material.dart';

import '../constants/app_icons.dart';

enum SavedMeasurementMenuAction {
  edit,
  exportPdf,
  exportGeoJson,
  exportCsv,
  delete,
}

class SavedMeasurementOverflowMenu extends StatelessWidget {
  const SavedMeasurementOverflowMenu({
    super.key,
    this.onEdit,
    required this.onExportPdf,
    required this.onExportGeoJson,
    required this.onExportCsv,
    required this.onDelete,
  });

  final VoidCallback? onEdit;
  final VoidCallback onExportPdf;
  final VoidCallback onExportGeoJson;
  final VoidCallback onExportCsv;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<SavedMeasurementMenuAction>(
      key: const ValueKey('saved-measurement-overflow-menu'),
      tooltip: 'Más acciones',
      icon: const Icon(AppIcons.moreVertical),
      onSelected: (action) {
        switch (action) {
          case SavedMeasurementMenuAction.edit:
            onEdit?.call();
          case SavedMeasurementMenuAction.exportPdf:
            onExportPdf();
          case SavedMeasurementMenuAction.exportGeoJson:
            onExportGeoJson();
          case SavedMeasurementMenuAction.exportCsv:
            onExportCsv();
          case SavedMeasurementMenuAction.delete:
            onDelete();
        }
      },
      itemBuilder: (context) => [
        if (onEdit != null)
          const PopupMenuItem<SavedMeasurementMenuAction>(
            value: SavedMeasurementMenuAction.edit,
            child: _SavedMeasurementMenuItem(
              icon: AppIcons.edit,
              label: 'Editar',
            ),
          ),
        const PopupMenuItem<SavedMeasurementMenuAction>(
          value: SavedMeasurementMenuAction.exportPdf,
          child: _SavedMeasurementMenuItem(
            icon: AppIcons.pdf,
            label: 'Exportar PDF',
          ),
        ),
        const PopupMenuItem<SavedMeasurementMenuAction>(
          value: SavedMeasurementMenuAction.exportGeoJson,
          child: _SavedMeasurementMenuItem(
            icon: AppIcons.map,
            label: 'Exportar GeoJSON',
          ),
        ),
        const PopupMenuItem<SavedMeasurementMenuAction>(
          value: SavedMeasurementMenuAction.exportCsv,
          child: _SavedMeasurementMenuItem(
            icon: AppIcons.library,
            label: 'Exportar CSV',
          ),
        ),
        const PopupMenuItem<SavedMeasurementMenuAction>(
          value: SavedMeasurementMenuAction.delete,
          child: _SavedMeasurementMenuItem(
            icon: AppIcons.delete,
            label: 'Eliminar',
          ),
        ),
      ],
    );
  }
}

class _SavedMeasurementMenuItem extends StatelessWidget {
  const _SavedMeasurementMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
