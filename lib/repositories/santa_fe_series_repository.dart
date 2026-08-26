import 'dart:convert';

import 'package:flutter/services.dart';

import '../constants/asset_paths.dart';

/// One entry of the Santa Fe consolidated-PDF series index: a series code,
/// its display name, and the page range (physical PDF pages, not the
/// document's own printed page numbers) where its description lives inside
/// the single consolidated PDF.
class SantaFeSeriesEntry {
  const SantaFeSeriesEntry({
    required this.code,
    required this.name,
    required this.startPage,
    required this.endPage,
  });

  final String code;
  final String name;
  final int startPage;
  final int endPage;
}

/// Resolves Santa Fe soil-polygon features to a series and, from there, to
/// a page range inside the province's single consolidated PDF.
///
/// Deliberately separate from [PdfSeriesRepository]: Buenos Aires indexes
/// one PDF file per series by normalized filename. Santa Fe ships a single
/// 640-page PDF covering all 213 series, so the lookup here goes from a
/// series *code* (read off the GeoJSON feature, e.g. `"MLA"` out of
/// `"comp1":"MLA cc"`) to a page range in `assets/data/santa_fe_series_index.json`
/// — generated from the PDF's own table of contents, see the Santa Fe Fase 1
/// audit. Buenos Aires' repository/catalog are untouched by this class.
class SantaFeSeriesRepository {
  SantaFeSeriesRepository({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  final AssetBundle _assetBundle;
  Future<_SantaFeIndex>? _indexFuture;

  /// The asset path of the single consolidated PDF, as declared in the
  /// index JSON.
  Future<String> get pdfAsset async => (await _loadIndex()).pdfAsset;

  /// Looks up a series by its code (case-insensitive — the audit found at
  /// least one capitalization mismatch between the GeoJSON and the PDF,
  /// e.g. `"ALd"` vs. `"Ald"`). Returns `null`, without throwing, if the
  /// code has no matching series in the index (see [dominantSeriesCode]'s
  /// doc comment for why that can legitimately happen).
  Future<SantaFeSeriesEntry?> findByCode(String code) async {
    final index = await _loadIndex();
    return index.seriesByNormalizedCode[normalizeCode(code)];
  }

  /// Resolves the dominant series for a Santa Fe soil-polygon feature and
  /// looks it up in the index in one step. Returns `null` if the feature
  /// has no usable series component, or if the dominant component's code
  /// isn't in the PDF index (the audit found 10 GeoJSON component codes
  /// with no matching series in the PDF — e.g. misc./non-series
  /// classifications or series from a neighboring province).
  Future<SantaFeSeriesEntry?> resolveDominantSeries(
    Map<String, dynamic> properties,
  ) async {
    final code = dominantSeriesCode(properties);
    if (code == null) return null;
    return findByCode(code);
  }

  /// Reads `comp1..comp6` (the ~248MB dataset's naming) or `comp_1`/`comp_2`
  /// (the ~30MB dataset's naming) together with their `<n>_porc` dominance
  /// percentage, and returns the series code of whichever component has the
  /// highest usable percentage — the deliberate "dominant component" rule
  /// for this first implementation (see Santa Fe Fase 1 task: do not show
  /// multiple series yet).
  ///
  /// Fallback: if no component has a usable numeric percentage (e.g. all
  /// `null`, which the audit found is common in the ~30MB dataset), the
  /// first component with a non-empty series code is used instead — this
  /// is a documented, deliberate degradation, not a silent one.
  static String? dominantSeriesCode(Map<String, dynamic> properties) {
    String? bestCode;
    double? bestPorc;
    String? fallbackCode;

    for (var i = 1; i <= 6; i++) {
      final rawComp = properties['comp$i'] ?? properties['comp_$i'];
      final code = _extractSeriesCode(rawComp);
      if (code == null) continue;
      fallbackCode ??= code;

      final rawPorc = properties['comp${i}_porc'];
      final porc = rawPorc is num
          ? rawPorc.toDouble()
          : double.tryParse(rawPorc?.toString() ?? '');
      if (porc != null && (bestPorc == null || porc > bestPorc)) {
        bestPorc = porc;
        bestCode = code;
      }
    }

    return bestCode ?? fallbackCode;
  }

  /// Component values look like `"MLA cc"` — a series code followed by a
  /// lowercase dominance/phase marker (`cc`, `As`, etc., per the audit).
  /// The series code is the leading whitespace-delimited token.
  static String? _extractSeriesCode(Object? rawComp) {
    if (rawComp == null) return null;
    final trimmed = rawComp.toString().trim();
    if (trimmed.isEmpty) return null;
    final firstSpace = trimmed.indexOf(' ');
    return firstSpace == -1 ? trimmed : trimmed.substring(0, firstSpace);
  }

  /// Same normalization for index keys and lookups, so matching is
  /// case-insensitive end to end.
  static String normalizeCode(String code) => code.trim().toLowerCase();

  /// Public wrapper over [_extractSeriesCode] — needed by
  /// `SantaFeSeriesNameResolver` (Fase 4B) to pull a lookup code out of a
  /// raw `SERIE1..6` vector-tile value (e.g. `"CER cc"` -> `"CER"`), the
  /// same way [dominantSeriesCode] already does for the GeoJSON `comp*`
  /// properties.
  static String? extractSeriesCode(Object? rawComp) =>
      _extractSeriesCode(rawComp);

  /// Every indexed series, sorted by display name. Used by the unified
  /// "Memorias descriptivas" catalog (Santa Fe Fase 7) to list all 213
  /// series as their own catalog entries. Reuses the same cached index as
  /// [findByCode] — does not re-read or duplicate `santa_fe_series_index.json`.
  Future<List<SantaFeSeriesEntry>> loadAllSeries() async {
    final index = await _loadIndex();
    final entries = index.seriesByNormalizedCode.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return List<SantaFeSeriesEntry>.unmodifiable(entries);
  }

  /// Every indexed series' display name, keyed by [normalizeCode]. Reuses
  /// the same cached index as [findByCode] — does not re-read or duplicate
  /// `santa_fe_series_index.json`.
  Future<Map<String, String>> namesByNormalizedCode() async {
    final index = await _loadIndex();
    return Map<String, String>.unmodifiable({
      for (final entry in index.seriesByNormalizedCode.entries)
        entry.key: entry.value.name,
    });
  }

  Future<_SantaFeIndex> _loadIndex() {
    return _indexFuture ??= _buildIndex();
  }

  Future<_SantaFeIndex> _buildIndex() async {
    final raw = await _assetBundle.loadString(AssetPaths.santaFeSeriesIndex);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final pdfAsset = json['pdfAsset'] as String;
    final seriesJson = Map<String, dynamic>.from(json['series'] as Map);

    final byCode = <String, SantaFeSeriesEntry>{};
    for (final entry in seriesJson.entries) {
      final data = Map<String, dynamic>.from(entry.value as Map);
      byCode[normalizeCode(entry.key)] = SantaFeSeriesEntry(
        code: entry.key,
        name: data['name'] as String,
        startPage: data['startPage'] as int,
        endPage: data['endPage'] as int,
      );
    }

    return _SantaFeIndex(
      pdfAsset: pdfAsset,
      seriesByNormalizedCode: Map<String, SantaFeSeriesEntry>.unmodifiable(
        byCode,
      ),
    );
  }
}

class _SantaFeIndex {
  const _SantaFeIndex({
    required this.pdfAsset,
    required this.seriesByNormalizedCode,
  });

  final String pdfAsset;
  final Map<String, SantaFeSeriesEntry> seriesByNormalizedCode;
}
