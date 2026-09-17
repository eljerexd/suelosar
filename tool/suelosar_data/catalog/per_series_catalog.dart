import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../sources/series_rules.dart';
import '../validation/finding.dart';

/// Catalog for provinces with one PDF per series, in the format of
/// `assets/data/soil_maps.json` (`SoilMap.toJson` in the app): one record
/// per PDF, named after its file.
class PerSeriesCatalog {
  PerSeriesCatalog._(this.pdfFiles, this.records);

  /// PDF file names found in the directory, sorted.
  final List<String> pdfFiles;

  /// Generated records, ordered by `id`.
  final List<Map<String, Object?>> records;

  /// Lookup keys (the app's `PdfSeriesRepository.normalizeName`) of every
  /// PDF, the same index the app builds at runtime.
  Set<String> get seriesKeys => {
    for (final file in pdfFiles) normalizeSeriesName(file),
  };

  static List<String> listPdfs(Directory directory) => [
    for (final entity in directory.listSync())
      if (entity is File && entity.path.toLowerCase().endsWith('.pdf'))
        p.basename(entity.path),
  ]..sort();

  /// Display name of a PDF: file name without `.pdf`, with the word
  /// separator turned back into spaces.
  static String nameFromFile(String fileName, String separator) {
    final stem = fileName.replaceFirst(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    return separator == ' ' ? stem : stem.replaceAll(separator, ' ');
  }

  /// Builds the catalog. Records of [reference] keep their `id` and every
  /// field except `name` (which is always derived from the file), so
  /// hand-filled data survives; new PDFs get the next ids, in file order.
  static PerSeriesCatalog build({
    required Directory directory,
    required String wordSeparator,
    List<Map<String, Object?>>? reference,
    FindingSink? findings,
  }) {
    final files = listPdfs(directory);
    final byPdf = <String, Map<String, Object?>>{};
    for (final record in reference ?? const <Map<String, Object?>>[]) {
      final pdf = record['pdf']?.toString();
      if (pdf != null) byPdf.putIfAbsent(pdf, () => record);
    }
    var nextId =
        [
          for (final record in reference ?? const <Map<String, Object?>>[])
            if (record['id'] is int) record['id'] as int,
        ].fold<int>(-1, (a, b) => a > b ? a : b) +
        1;

    final records = <Map<String, Object?>>[];
    for (final file in files) {
      final existing = byPdf[file];
      records.add({
        'id': existing?['id'] ?? nextId++,
        'name': nameFromFile(file, wordSeparator),
        'province': existing?['province'] ?? '',
        'department': existing?['department'] ?? '',
        'scale': existing?['scale'] ?? '',
        'pdf': file,
        'memory': existing?['memory'],
        'map': existing?['map'],
        'notes': existing?['notes'] ?? '',
      });
    }
    records.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    if (findings != null) {
      _validate(directory, files, wordSeparator, reference, findings);
    }
    return PerSeriesCatalog._(files, records);
  }

  static void _validate(
    Directory directory,
    List<String> files,
    String separator,
    List<Map<String, Object?>>? reference,
    FindingSink findings,
  ) {
    if (files.isEmpty) {
      findings.error(
        'SRC001',
        'No hay PDFs en la carpeta de cartas.',
        location: directory.path,
      );
      return;
    }

    final groups = <String, List<String>>{};
    for (final file in files) {
      groups.putIfAbsent(normalizeSeriesName(file), () => []).add(file);
    }
    for (final group in groups.values.where((g) => g.length > 1)) {
      findings.error(
        'PDF001',
        'PDFs duplicados: ${group.join(' / ')} resuelven a la misma serie '
            '("${normalizeSeriesName(group.first)}"); la app abre solo el primero.',
        location: directory.path,
        examples: group,
      );
    }

    if (separator != ' ') {
      final spaced = [
        for (final file in files)
          if (file.contains(' ')) file,
      ];
      if (spaced.isNotEmpty) {
        findings.warning(
          'PDF002',
          '${spaced.length} PDFs usan espacios en el nombre en lugar de "$separator".',
          location: directory.path,
          examples: spaced,
          count: spaced.length,
        );
      }
    }

    final unreadable = <String>[];
    for (final file in files) {
      final raf = File(p.join(directory.path, file)).openSync();
      try {
        if (latin1.decode(raf.readSync(5), allowInvalid: true) != '%PDF-') {
          unreadable.add(file);
        }
      } finally {
        raf.closeSync();
      }
    }
    if (unreadable.isNotEmpty) {
      findings.error(
        'PDF003',
        '${unreadable.length} archivos .pdf no tienen cabecera PDF.',
        location: directory.path,
        examples: unreadable,
        count: unreadable.length,
      );
    }

    if (reference == null) return;
    final ids = <Object?, int>{};
    final pdfs = <Object?, int>{};
    for (final record in reference) {
      ids[record['id']] = (ids[record['id']] ?? 0) + 1;
      pdfs[record['pdf']] = (pdfs[record['pdf']] ?? 0) + 1;
    }
    final duplicatedIds = [
      for (final e in ids.entries)
        if (e.value > 1) '${e.key}',
    ];
    final duplicatedPdfs = [
      for (final e in pdfs.entries)
        if (e.value > 1) '${e.key}',
    ];
    if (duplicatedIds.isNotEmpty || duplicatedPdfs.isNotEmpty) {
      findings.error(
        'CAT001',
        'El catálogo actual repite ids (${duplicatedIds.length}) o PDFs (${duplicatedPdfs.length}).',
        examples: [...duplicatedIds.map((id) => 'id $id'), ...duplicatedPdfs],
      );
    }
    final mismatched = [
      for (final record in reference)
        if (record['pdf'] is String &&
            record['name'] != nameFromFile(record['pdf'] as String, separator))
          '${record['name']} -> ${record['pdf']}',
    ];
    if (mismatched.isNotEmpty) {
      findings.warning(
        'CAT004',
        '${mismatched.length} cartas del catálogo actual no siguen la regla de nombres '
            '(nombre con espacios <-> archivo con "$separator").',
        examples: mismatched,
        count: mismatched.length,
      );
    }
    final onDisk = files.toSet();
    final missing = [
      for (final record in reference)
        if (!onDisk.contains(record['pdf'])) '${record['pdf']}',
    ];
    if (missing.isNotEmpty) {
      findings.error(
        'SRC001',
        '${missing.length} PDFs del catálogo actual no existen en la carpeta.',
        location: directory.path,
        examples: missing,
        count: missing.length,
      );
    }
  }
}
