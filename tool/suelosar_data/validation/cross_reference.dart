import '../config/province_definition.dart';
import '../normalize/normalizer.dart';
import 'finding.dart';

/// Catalog side of the GIS <-> catalog comparison.
class CatalogKeys {
  const CatalogKeys({
    required this.keys,
    required this.labels,
    required this.kind,
  });

  /// Lookup keys, compared the way the app compares them.
  final Set<String> keys;

  /// Key -> what the catalog actually holds (file name or series code).
  final Map<String, String> labels;

  /// `PDFs` or `series del índice`, for messages.
  final String kind;
}

/// XRF001-XRF003: series used by the GIS that the catalog cannot open, and
/// catalog entries no polygon uses.
Map<String, Object?> checkCrossReference(
  ProvinceDefinition definition,
  NormalizeResult gis,
  CatalogKeys catalog,
  FindingSink findings,
) {
  final gisKeys = gis.seriesFeatureCounts.keys.toSet();
  final missing = gisKeys.difference(catalog.keys).toList()
    ..sort(
      (a, b) =>
          gis.seriesFeatureCounts[b]!.compareTo(gis.seriesFeatureCounts[a]!),
    );
  final orphans = catalog.keys.difference(gisKeys).toList()..sort();
  final affected = gis.featuresWithUncataloguedSeries ?? 0;
  final share = gis.featuresWithSeries == 0
      ? 0.0
      : affected * 100 / gis.featuresWithSeries;

  if (missing.isNotEmpty) {
    final rawValues = missing.fold<int>(
      0,
      (sum, key) => sum + (gis.seriesVariants[key]?.length ?? 1),
    );
    final message =
        '${missing.length} series del GIS no tienen ${catalog.kind == 'PDFs' ? 'PDF' : 'entrada en el índice'}'
        '${rawValues == missing.length ? '' : ' ($rawValues valores distintos en la fuente; la app los compara normalizados)'}: '
        '$affected de ${gis.featuresWithSeries} features con series '
        '(${share.toStringAsFixed(1)} %) usan al menos una.';
    final examples = [
      for (final key in missing)
        '${gis.seriesVariants[key]!.join(' / ')} '
            '(${gis.seriesFeatureCounts[key]} features)',
    ];
    if (share > definition.xrefErrorAbovePercent) {
      findings.error(
        'XRF001',
        '$message Límite: ${definition.xrefErrorAbovePercent} %.',
        examples: examples,
        count: missing.length,
      );
    } else {
      findings.warning(
        'XRF001',
        message,
        examples: examples,
        count: missing.length,
      );
    }
  }
  if (orphans.isNotEmpty) {
    findings.info(
      'XRF002',
      '${orphans.length} ${catalog.kind} no corresponden a ninguna serie del GIS.',
      examples: [for (final key in orphans) catalog.labels[key] ?? key],
      count: orphans.length,
    );
  }

  final caseOnly = [
    if (definition.gis.series.match == SeriesMatch.caseInsensitive)
      for (final key in gisKeys.intersection(catalog.keys))
        for (final variant in gis.seriesVariants[key]!)
          if (variant != catalog.labels[key] &&
              !definition.gis.series.aliases.containsKey(variant))
            '$variant (GIS) = ${catalog.labels[key]} (catálogo)',
  ];
  if (caseOnly.isNotEmpty) {
    findings.info(
      'XRF003',
      '${caseOnly.length} códigos coinciden solo ignorando mayúsculas.',
      examples: caseOnly,
      count: caseOnly.length,
    );
  }
  final aliases = definition.gis.series.aliases;
  if (aliases.isNotEmpty) {
    findings.info(
      'XRF003',
      '${aliases.length} alias declarados en province.yaml.',
      examples: [for (final e in aliases.entries) '${e.key} -> ${e.value}'],
    );
  }

  return {
    'gisSeries': gisKeys.length,
    'catalogEntries': catalog.keys.length,
    'catalogKind': catalog.kind,
    'gisSeriesWithoutCatalog': missing.length,
    'gisSeriesWithoutCatalogRawValues': missing.fold<int>(
      0,
      (sum, key) => sum + (gis.seriesVariants[key]?.length ?? 1),
    ),
    'catalogEntriesWithoutGis': orphans.length,
    'featuresWithSeries': gis.featuresWithSeries,
    'featuresWithUncataloguedSeries': affected,
    'featuresWithUncataloguedSeriesPercent': double.parse(
      share.toStringAsFixed(2),
    ),
    'missing': [
      for (final key in missing)
        {
          'series': gis.seriesExamples[key],
          'variants': (gis.seriesVariants[key] ?? const <String>{}).toList(),
          'features': gis.seriesFeatureCounts[key],
        },
    ],
    'orphans': [for (final key in orphans) catalog.labels[key] ?? key],
  };
}
