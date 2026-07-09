import 'package:flutter/services.dart';

import '../constants/asset_paths.dart';

/// Indexes bundled soil series PDFs and resolves normalized series names.
class PdfSeriesRepository {
  PdfSeriesRepository({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  final AssetBundle _assetBundle;
  Future<Map<String, List<String>>>? _indexFuture;

  /// Returns every PDF asset grouped by its normalized filename.
  Future<Map<String, List<String>>> loadIndex() {
    return _indexFuture ??= _buildIndex();
  }

  /// Finds the first indexed PDF matching [seriesName].
  Future<String?> findPdfForSeries(String seriesName) async {
    final key = normalizeName(seriesName);
    if (key.isEmpty) {
      return null;
    }

    final index = await loadIndex();
    final matches = index[key];
    return matches == null || matches.isEmpty ? null : matches.first;
  }

  Future<Map<String, List<String>>> _buildIndex() async {
    final manifest = await AssetManifest.loadFromAssetBundle(_assetBundle);
    final pdfAssets =
        manifest
            .listAssets()
            .where(
              (assetPath) =>
                  assetPath.startsWith('${AssetPaths.soilMapsPdfDirectory}/') &&
                  assetPath.toLowerCase().endsWith('.pdf'),
            )
            .toList(growable: false)
          ..sort();
    final mutableIndex = <String, List<String>>{};

    for (final assetPath in pdfAssets) {
      final filename = assetPath.split('/').last;
      final key = normalizeName(filename);
      mutableIndex.putIfAbsent(key, () => <String>[]).add(assetPath);
    }

    return Map<String, List<String>>.unmodifiable({
      for (final entry in mutableIndex.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    });
  }

  /// Produces the same lookup key for series names and PDF filenames.
  static String normalizeName(String value) {
    var normalized = value.trim().toLowerCase();
    if (normalized.endsWith('.pdf')) {
      normalized = normalized.substring(0, normalized.length - 4);
    }

    final buffer = StringBuffer();
    for (final rune in normalized.runes) {
      if (rune >= 0x0300 && rune <= 0x036f) {
        continue;
      }

      final character = String.fromCharCode(rune);
      buffer.write(_accentReplacements[character] ?? character);
    }

    return buffer.toString().replaceAll(RegExp(r'[\s_]+'), '_');
  }

  static const Map<String, String> _accentReplacements = {
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ñ': 'n',
    'ç': 'c',
    'ý': 'y',
    'ÿ': 'y',
    'æ': 'ae',
    'œ': 'oe',
  };
}
