import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'measurement_export_models.dart';

class MeasurementPdfExporter {
  MeasurementPdfExporter({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  static const String _logoAssetPath = 'assets/images/logoapp.png';

  final AssetBundle _assetBundle;

  Future<File> export(MeasurementExportData data) async {
    final document = PdfDocument();
    try {
      document.pageSettings
        ..orientation = PdfPageOrientation.portrait
        ..margins.all = 36;

      final page = document.pages.add();
      final layout = _PdfReportLayout(document: document, page: page);
      final logoBytes = await _loadLogoBytes();

      layout.drawHeader(logoBytes);
      layout.drawInformation(data);
      layout.drawCoordinates(data);
      layout.drawFooter();

      final bytes = document.saveSync();
      final output = await _createOutputFile(data);
      await output.writeAsBytes(bytes, flush: true);
      return output;
    } finally {
      document.dispose();
    }
  }

  Future<Uint8List?> _loadLogoBytes() async {
    try {
      final data = await _assetBundle.load(_logoAssetPath);
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<File> _createOutputFile(MeasurementExportData data) async {
    final directory = await getTemporaryDirectory();
    final timestamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final title = data.title?.trim().isNotEmpty == true
        ? data.title!.trim()
        : 'measurement';
    final safeTitle = title
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return File(
      '${directory.path}${Platform.pathSeparator}'
      'suelosar_medicion_${safeTitle}_$timestamp.pdf',
    );
  }
}

class _PdfReportLayout {
  _PdfReportLayout({required this.document, required this.page})
    : _graphics = page.graphics,
      _bounds = page.getClientSize();

  final PdfDocument document;
  final PdfPage page;
  final Size _bounds;
  late PdfGraphics _graphics;

  final PdfFont _titleFont = PdfStandardFont(
    PdfFontFamily.helvetica,
    22,
    style: PdfFontStyle.bold,
  );
  final PdfFont _sectionFont = PdfStandardFont(
    PdfFontFamily.helvetica,
    13,
    style: PdfFontStyle.bold,
  );
  final PdfFont _labelFont = PdfStandardFont(
    PdfFontFamily.helvetica,
    10,
    style: PdfFontStyle.bold,
  );
  final PdfFont _bodyFont = PdfStandardFont(PdfFontFamily.helvetica, 10);
  final PdfFont _smallFont = PdfStandardFont(PdfFontFamily.helvetica, 8);

  final PdfBrush _darkBrush = PdfSolidBrush(PdfColor(45, 47, 42));
  final PdfBrush _mutedBrush = PdfSolidBrush(PdfColor(94, 91, 82));
  final PdfBrush _surfaceBrush = PdfSolidBrush(PdfColor(248, 246, 239));
  final PdfPen _linePen = PdfPen(PdfColor(218, 211, 196), width: 0.8);

  double _y = 0;

  void drawHeader(Uint8List? logoBytes) {
    var x = 0.0;
    if (logoBytes != null) {
      final image = PdfBitmap(logoBytes);
      final imageWidth = math.min(120.0, _bounds.width * 0.28);
      final imageHeight = image.height * imageWidth / image.width;
      _graphics.drawImage(image, Rect.fromLTWH(0, 0, imageWidth, imageHeight));
      x = imageWidth + 18;
    }

    _graphics.drawString(
      'Informe de medición',
      _titleFont,
      brush: _darkBrush,
      bounds: Rect.fromLTWH(x, 4, _bounds.width - x, 30),
    );
    _graphics.drawString(
      'Resumen de medición generado por SuelosAR',
      _bodyFont,
      brush: _mutedBrush,
      bounds: Rect.fromLTWH(x, 34, _bounds.width - x, 18),
    );

    _y = 68;
    _graphics.drawLine(_linePen, Offset(0, _y), Offset(_bounds.width, _y));
    _y += 22;
  }

  void drawInformation(MeasurementExportData data) {
    _drawSectionTitle('Información');
    final rows = <_PdfInfoRow>[
      _PdfInfoRow('Tipo de medición', _measurementTypeLabel(data.type)),
      _PdfInfoRow('Fecha', _formatDate(data.createdAt)),
      if (data.areaSquareMeters != null)
        _PdfInfoRow('Área', _formatArea(data.areaSquareMeters!)),
      if (data.perimeterMeters != null)
        _PdfInfoRow('Perímetro', _formatDistance(data.perimeterMeters!)),
      if (data.distanceMeters != null)
        _PdfInfoRow('Distancia', _formatDistance(data.distanceMeters!)),
      _PdfInfoRow('Vértices', '${data.coordinates.length}'),
      _PdfInfoRow('CRS', data.crs),
      if (data.title != null) _PdfInfoRow('Título', data.title!),
      if (data.notes != null) _PdfInfoRow('Notas', data.notes!),
    ];

    final rowHeight = 20.0;
    final tableHeight = rows.length * rowHeight + 18;
    _graphics.drawRectangle(
      brush: _surfaceBrush,
      pen: PdfPen(PdfColor(232, 226, 214), width: 0.5),
      bounds: Rect.fromLTWH(0, _y, _bounds.width, tableHeight),
    );

    var rowY = _y + 10;
    for (final row in rows) {
      _graphics.drawString(
        row.label,
        _labelFont,
        brush: _mutedBrush,
        bounds: Rect.fromLTWH(14, rowY, 140, rowHeight),
      );
      _graphics.drawString(
        row.value,
        _bodyFont,
        brush: _darkBrush,
        bounds: Rect.fromLTWH(168, rowY, _bounds.width - 182, rowHeight),
      );
      rowY += rowHeight;
    }
    _y += tableHeight + 24;
  }

  void drawCoordinates(MeasurementExportData data) {
    _drawSectionTitle('Coordenadas');
    _drawCoordinateHeader();

    for (var index = 0; index < data.coordinates.length; index++) {
      if (_y > _bounds.height - 56) {
        drawFooter();
        _addPage();
        _drawCoordinateHeader();
      }
      final coordinate = data.coordinates[index];
      _drawCoordinateRow(index + 1, coordinate);
    }
  }

  void drawFooter() {
    final footerY = _bounds.height - 18;
    _graphics.drawLine(
      _linePen,
      Offset(0, footerY - 8),
      Offset(_bounds.width, footerY - 8),
    );
    _graphics.drawString(
      'Generado por SuelosAR.',
      _smallFont,
      brush: _mutedBrush,
      bounds: Rect.fromLTWH(0, footerY, _bounds.width, 12),
    );
  }

  void _drawSectionTitle(String title) {
    _graphics.drawString(
      title,
      _sectionFont,
      brush: _darkBrush,
      bounds: Rect.fromLTWH(0, _y, _bounds.width, 18),
    );
    _y += 24;
  }

  void _drawCoordinateHeader() {
    _graphics.drawRectangle(
      brush: _surfaceBrush,
      bounds: Rect.fromLTWH(0, _y, _bounds.width, 22),
    );
    _graphics.drawString(
      '#',
      _labelFont,
      brush: _mutedBrush,
      bounds: Rect.fromLTWH(10, _y + 6, 40, 12),
    );
    _graphics.drawString(
      'Latitud',
      _labelFont,
      brush: _mutedBrush,
      bounds: Rect.fromLTWH(72, _y + 6, 120, 12),
    );
    _graphics.drawString(
      'Longitud',
      _labelFont,
      brush: _mutedBrush,
      bounds: Rect.fromLTWH(220, _y + 6, 120, 12),
    );
    _y += 24;
  }

  void _drawCoordinateRow(int index, MeasurementExportCoordinate coordinate) {
    final rowY = _y;
    _graphics.drawString(
      '$index',
      _bodyFont,
      brush: _darkBrush,
      bounds: Rect.fromLTWH(10, rowY, 40, 16),
    );
    _graphics.drawString(
      _formatCoordinate(coordinate.latitude),
      _bodyFont,
      brush: _darkBrush,
      bounds: Rect.fromLTWH(72, rowY, 120, 16),
    );
    _graphics.drawString(
      _formatCoordinate(coordinate.longitude),
      _bodyFont,
      brush: _darkBrush,
      bounds: Rect.fromLTWH(220, rowY, 120, 16),
    );
    _graphics.drawLine(
      _linePen,
      Offset(0, rowY + 18),
      Offset(_bounds.width, rowY + 18),
    );
    _y += 20;
  }

  void _addPage() {
    final newPage = document.pages.add();
    _graphics = newPage.graphics;
    _y = 0;
  }

  static String _measurementTypeLabel(MeasurementExportType type) {
    return switch (type) {
      MeasurementExportType.distance => 'Distancia',
      MeasurementExportType.area => 'Área',
    };
  }

  static String _formatDate(DateTime date) {
    final local = date.toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${twoDigits(local.day)}/${twoDigits(local.month)}/${local.year} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  static String _formatArea(double squareMeters) {
    if (squareMeters >= 10000) {
      return '${_formatNumber(squareMeters / 10000, decimals: 2)} ha';
    }
    return '${_formatNumber(squareMeters, decimals: 0)} m²';
  }

  static String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${_formatNumber(meters / 1000, decimals: 2)} km';
    }
    return '${_formatNumber(meters, decimals: 0)} m';
  }

  static String _formatCoordinate(double value) {
    return _formatNumber(value, decimals: 6);
  }

  static String _formatNumber(double value, {required int decimals}) {
    final formatted = value.toStringAsFixed(decimals);
    final locale = Platform.localeName.toLowerCase();
    if (locale.startsWith('es')) {
      return formatted.replaceAll('.', ',');
    }
    return formatted;
  }
}

class _PdfInfoRow {
  const _PdfInfoRow(this.label, this.value);

  final String label;
  final String value;
}
