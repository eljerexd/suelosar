import 'dart:collection';

import '../config/province_definition.dart';
import '../sources/pdf_text.dart';
import '../sources/series_rules.dart';
import '../validation/finding.dart';

/// One line of the PDF's table of contents.
class TocEntry {
  const TocEntry({
    required this.title,
    required this.printedPage,
    required this.sourcePage,
    this.code,
    this.name,
  });

  final String title;
  final int printedPage;

  /// Physical page of the table of contents the line was read from.
  final int sourcePage;

  /// Set for series entries only.
  final String? code;
  final String? name;

  bool get isSeries => code != null;
}

class SeriesRange {
  const SeriesRange(this.code, this.name, this.startPage, this.endPage);

  final String code;
  final String name;
  final int startPage;
  final int endPage;
}

/// Index for provinces with one PDF holding every series, in the format of
/// `assets/data/santa_fe_series_index.json` (read by the app's
/// `SantaFeSeriesRepository`), generated from the PDF's own table of
/// contents: a series starts at its printed page plus the page offset and
/// ends right before the next table-of-contents entry, series or not.
class ConsolidatedIndex {
  ConsolidatedIndex._({
    required this.entries,
    required this.series,
    required this.pageOffset,
    required this.pageOffsetDetected,
    required this.pageCount,
    required this.json,
  });

  final List<TocEntry> entries;

  /// Series in table-of-contents order; duplicates keep the first.
  final List<SeriesRange> series;
  final int? pageOffset;
  final bool pageOffsetDetected;
  final int pageCount;

  /// The index document, or null when the offset could not be established.
  final Map<String, Object?>? json;

  /// Lookup keys (`normalizeCode`) of every series.
  Set<String> get seriesKeys => {for (final s in series) normalizeCode(s.code)};

  Map<String, String> get namesByKey => {
    for (final s in series) normalizeCode(s.code): s.name,
  };

  static ConsolidatedIndex build({
    required PdfText text,
    required TocConfig toc,
    required String generatedFrom,
    required String pdfAsset,
    required String provinceLabel,
    required FindingSink findings,
  }) {
    final pageCount = text.pageCount;
    final entries = <TocEntry>[];
    if (toc.lastPage > pageCount) {
      findings.error(
        'CAT002',
        'pdf.toc.pages termina en ${toc.lastPage}, pero el PDF tiene $pageCount páginas.',
      );
    }
    final unrecognized = <String>[];
    for (
      var page = toc.firstPage;
      page <= toc.lastPage && page <= pageCount;
      page++
    ) {
      for (final line in text.page(page).split(RegExp(r'\r?\n'))) {
        final series = toc.seriesPattern.firstMatch(line);
        if (series != null) {
          entries.add(
            TocEntry(
              title: line.trim(),
              printedPage: int.parse(series.namedGroup('page')!),
              sourcePage: page,
              code: series.namedGroup('code')!.trim(),
              name: series.namedGroup('name')!.trim(),
            ),
          );
          continue;
        }
        final entry = toc.entryPattern.firstMatch(line);
        if (entry != null) {
          entries.add(
            TocEntry(
              title: (_group(entry, 'title') ?? line).trim(),
              printedPage: int.parse(entry.namedGroup('page')!),
              sourcePage: page,
            ),
          );
        } else if (RegExp(r'\.{5,}').hasMatch(line)) {
          unrecognized.add('p$page: ${line.trim()}');
        }
      }
    }
    if (unrecognized.isNotEmpty) {
      findings.warning(
        'CAT009',
        '${unrecognized.length} líneas del índice parecen entradas pero no coinciden con los patrones.',
        examples: unrecognized,
        count: unrecognized.length,
      );
    }
    final seriesEntries = entries.where((e) => e.isSeries).toList();
    if (seriesEntries.isEmpty) {
      findings.error(
        'CAT003',
        'No se encontró ninguna serie en el índice (páginas ${toc.firstPage}-${toc.lastPage}).',
      );
      return ConsolidatedIndex._(
        entries: entries,
        series: const [],
        pageOffset: null,
        pageOffsetDetected: false,
        pageCount: pageCount,
        json: null,
      );
    }
    for (var i = 1; i < entries.length; i++) {
      if (entries[i].printedPage < entries[i - 1].printedPage) {
        findings.error(
          'CAT002',
          'El índice no está en orden de páginas: "${entries[i].title}" (${entries[i].printedPage}) '
              'viene después de "${entries[i - 1].title}" (${entries[i - 1].printedPage}).',
          location: 'página ${entries[i].sourcePage}',
        );
      }
    }

    bool headingAt(TocEntry entry, int physicalPage) {
      if (physicalPage < 1 || physicalPage > pageCount) return false;
      final pattern = toc.headingPattern
          .replaceAll('{name}', RegExp.escape(entry.name!))
          .replaceAll('{code}', RegExp.escape(entry.code!));
      return RegExp(pattern).hasMatch(text.page(physicalPage));
    }

    var offset = toc.pageOffset;
    final detected = offset == null;
    if (offset == null) {
      final first = seriesEntries.first;
      for (var page = toc.lastPage + 1; page <= pageCount; page++) {
        if (headingAt(first, page)) {
          offset = page - first.printedPage;
          break;
        }
      }
      if (offset == null) {
        findings.error(
          'CAT003',
          'No se pudo detectar page_offset: el título de "${first.name} (${first.code})" '
              'no aparece al comienzo de ninguna página.',
        );
      } else if (!headingAt(
        seriesEntries.last,
        seriesEntries.last.printedPage + offset,
      )) {
        findings.error(
          'CAT003',
          'page_offset $offset no se confirma con la última serie '
              '"${seriesEntries.last.name}" (página ${seriesEntries.last.printedPage + offset}).',
        );
        offset = null;
      }
    }
    if (offset == null) {
      return ConsolidatedIndex._(
        entries: entries,
        series: const [],
        pageOffset: null,
        pageOffsetDetected: detected,
        pageCount: pageCount,
        json: null,
      );
    }

    final ranges = <SeriesRange>[];
    final seenCodes = <String, String>{};
    final duplicated = <String>[];
    final missingHeadings = <String>[];
    final badRanges = <String>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (!entry.isSeries) continue;
      final start = entry.printedPage + offset;
      final end = i + 1 < entries.length
          ? entries[i + 1].printedPage + offset - 1
          : pageCount;
      final key = normalizeCode(entry.code!);
      if (seenCodes.containsKey(key)) {
        duplicated.add('${entry.code} (también ${seenCodes[key]})');
        continue;
      }
      seenCodes[key] = entry.code!;
      if (start < 1 || end < start || end > pageCount) {
        badRanges.add('${entry.code}: $start-$end');
      }
      if (!headingAt(entry, start)) {
        missingHeadings.add('${entry.code} "${entry.name}" p$start');
      }
      ranges.add(SeriesRange(entry.code!, entry.name!, start, end));
    }
    if (duplicated.isNotEmpty) {
      findings.error(
        'CAT001',
        '${duplicated.length} códigos de serie repetidos (la app compara sin distinguir mayúsculas).',
        examples: duplicated,
        count: duplicated.length,
      );
    }
    if (badRanges.isNotEmpty) {
      findings.error(
        'CAT002',
        '${badRanges.length} series con rango de páginas inválido.',
        examples: badRanges,
      );
    }
    if (missingHeadings.isNotEmpty) {
      findings.warning(
        'CAT005',
        '${missingHeadings.length} series no tienen su título al comienzo de la página inicial calculada.',
        examples: missingHeadings,
        count: missingHeadings.length,
      );
    }
    final names = <String, int>{};
    for (final range in ranges) {
      names[range.name] = (names[range.name] ?? 0) + 1;
    }
    final duplicatedNames = [
      for (final e in names.entries)
        if (e.value > 1) e.key,
    ];
    if (duplicatedNames.isNotEmpty) {
      findings.warning(
        'CAT008',
        'Nombres de serie repetidos.',
        examples: duplicatedNames,
      );
    }

    final json = LinkedHashMap<String, Object?>.of({
      'province': provinceLabel,
      'pdfAsset': pdfAsset,
      'generatedFrom': generatedFrom,
      'pageOffset': offset,
      'series': LinkedHashMap<String, Object?>.of({
        for (final range in ranges)
          range.code: {
            'name': range.name,
            'startPage': range.startPage,
            'endPage': range.endPage,
          },
      }),
    });
    return ConsolidatedIndex._(
      entries: entries,
      series: ranges,
      pageOffset: offset,
      pageOffsetDetected: detected,
      pageCount: pageCount,
      json: json,
    );
  }

  /// Series of an index document the app already ships.
  static Map<String, String> namesFromDocument(Map<String, Object?> document) {
    final series = document['series'];
    if (series is! Map) return const {};
    return {
      for (final entry in series.entries)
        normalizeCode(entry.key.toString()):
            ((entry.value as Map)['name'] ?? '').toString(),
    };
  }

  static String? _group(RegExpMatch match, String name) =>
      match.groupNames.contains(name) ? match.namedGroup(name) : null;
}
