import 'dart:convert';

import 'package:flutter/services.dart';

import '../constants/asset_paths.dart';
import 'pdf_series_repository.dart';

/// One entry of the Córdoba consolidated-PDF series index: the series' own
/// display name (with the GIS spelling, accents included) and the page
/// range — physical PDF pages, not printed page numbers — where its
/// description lives inside the single consolidated PDF.
class CordobaSeriesEntry {
  const CordobaSeriesEntry({
    required this.name,
    required this.startPage,
    required this.endPage,
  });

  final String name;
  final int startPage;
  final int endPage;
}

/// Resolves a Córdoba soil series to a page range inside the province's
/// single consolidated PDF.
///
/// Deliberately its own class rather than a reuse of either existing
/// repository:
/// - [PdfSeriesRepository] (Buenos Aires) resolves a name to one PDF file
///   per series; Córdoba ships a single 734-page PDF instead.
/// - `SantaFeSeriesRepository` resolves a series *code* (`"CER cc"` ->
///   `"CER"`, its leading token); Córdoba's `SERIE1..6` values are already
///   full names, so that rule would truncate `"AARÓN CASTELLANOS"` to
///   `"AARÓN"`.
///
/// Lookups reuse [PdfSeriesRepository.normalizeName] — the same
/// case/accent/separator normalization the app already applies to Buenos
/// Aires' series names and PDF filenames — so `"VICENTE AGÜERO"`,
/// `"Vicente Aguero"` and `"VICENTE_AGUERO"` all find the same entry. The
/// name shown to the user is always [CordobaSeriesEntry.name], i.e. the
/// index' own spelling, never the normalized lookup key.
class CordobaSeriesRepository {
  CordobaSeriesRepository({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  final AssetBundle _assetBundle;

  /// Static, like `SantaFeSeriesRepository._indexFuture`: several call
  /// sites (the catalog screen, favorites, the GIS map's province config)
  /// build their own repository, and the index should be read and parsed
  /// once per app run rather than once per screen.
  static Future<_CordobaIndex>? _indexFuture;

  /// Only for tests: drops the process-wide cache so a test bundle is not
  /// shadowed by an index another test already loaded.
  static void resetCacheForTesting() => _indexFuture = null;

  /// The asset path of the single consolidated PDF, as declared in the
  /// index JSON.
  Future<String> get pdfAsset async => (await _loadIndex()).pdfAsset;

  /// Looks up a series by name, ignoring case, accents and `_`/`-`/space
  /// differences. Returns `null`, without throwing, when the value is not
  /// a documented series — which legitimately happens for the map-unit
  /// components that are not series ("suelos menores", "roca expuesta"):
  /// they stay in the data and simply have no description to open.
  Future<CordobaSeriesEntry?> findByName(String name) async {
    final key = PdfSeriesRepository.normalizeName(name);
    if (key.isEmpty) return null;
    final index = await _loadIndex();
    return index.seriesByNormalizedName[key];
  }

  /// Every indexed series, in the index' order (alphabetical by normalized
  /// name, as generated). Used by the unified "Memorias descriptivas"
  /// catalog. Reuses the same cached index as [findByName].
  Future<List<CordobaSeriesEntry>> loadAllSeries() async {
    final index = await _loadIndex();
    return index.series;
  }

  Future<_CordobaIndex> _loadIndex() => _indexFuture ??= _buildIndex();

  Future<_CordobaIndex> _buildIndex() async {
    final raw = await _assetBundle.loadString(AssetPaths.cordobaSeriesIndex);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final pdfAsset = json['pdfAsset'] as String;
    final series = [
      for (final item in json['series'] as List)
        () {
          final data = Map<String, dynamic>.from(item as Map);
          return CordobaSeriesEntry(
            name: data['name'] as String,
            startPage: data['startPage'] as int,
            endPage: data['endPage'] as int,
          );
        }(),
    ];

    return _CordobaIndex(
      pdfAsset: pdfAsset,
      series: List<CordobaSeriesEntry>.unmodifiable(series),
      seriesByNormalizedName: Map<String, CordobaSeriesEntry>.unmodifiable({
        for (final entry in series)
          PdfSeriesRepository.normalizeName(entry.name): entry,
      }),
    );
  }
}

class _CordobaIndex {
  const _CordobaIndex({
    required this.pdfAsset,
    required this.series,
    required this.seriesByNormalizedName,
  });

  final String pdfAsset;
  final List<CordobaSeriesEntry> series;
  final Map<String, CordobaSeriesEntry> seriesByNormalizedName;
}
