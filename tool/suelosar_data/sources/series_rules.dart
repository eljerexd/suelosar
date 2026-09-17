/// Series-name and series-code rules the app applies at runtime, replicated
/// here because their originals live in `lib/` files that import Flutter
/// (which `dart run` cannot load). `test/tool/suelosar_data/series_rules_parity_test.dart`
/// checks every function against its original on the real data.
library;

/// Same key as `PdfSeriesRepository.normalizeName` (Buenos Aires: series
/// name <-> PDF filename).
String normalizeSeriesName(String value) {
  var normalized = value.trim().toLowerCase();
  if (normalized.endsWith('.pdf')) {
    normalized = normalized.substring(0, normalized.length - 4);
  }
  final buffer = StringBuffer();
  for (final rune in normalized.runes) {
    if (rune >= 0x0300 && rune <= 0x036f) continue;
    final character = String.fromCharCode(rune);
    buffer.write(_accentReplacements[character] ?? character);
  }
  return buffer.toString().replaceAll(RegExp(r'[\s_]+'), '_');
}

const Map<String, String> _accentReplacements = {
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

/// Same as `SantaFeSeriesRepository.extractSeriesCode`: the leading
/// whitespace-delimited token (`"CER cc"` -> `"CER"`), or null when empty.
String? firstTokenCode(Object? raw) {
  if (raw == null) return null;
  final trimmed = raw.toString().trim();
  if (trimmed.isEmpty) return null;
  final firstSpace = trimmed.indexOf(' ');
  return firstSpace == -1 ? trimmed : trimmed.substring(0, firstSpace);
}

/// Same as `SantaFeSeriesRepository.normalizeCode`.
String normalizeCode(String code) => code.trim().toLowerCase();

final _leadingFloat = RegExp(
  r'^[\t\n\v\f\r  ﻿]*([+-]?(?:Infinity|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?))',
);

/// JavaScript `parseFloat`, as used by `remap_santa_fe.mjs` for
/// non-numeric percentages: leading number of the text, or null (NaN).
double? jsParseFloat(Object? value) {
  if (value == null) return null;
  final match = _leadingFloat.firstMatch(value.toString());
  if (match == null) return null;
  var text = match.group(1)!;
  if (text.endsWith('Infinity')) {
    return text.startsWith('-') ? double.negativeInfinity : double.infinity;
  }
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return double.tryParse(text);
}

/// Dominant-series rule shared by `remap_santa_fe.mjs` and
/// `SantaFeSeriesRepository.dominantSeriesCode`: the component with the
/// highest percentage wins (first one on ties); with no usable percentage,
/// the first component with a code. [codeOf] extracts the code from a raw
/// series value.
String? dominantSeriesCode(
  List<Object?> seriesValues,
  List<Object?> percentageValues,
  String? Function(Object?) codeOf,
) {
  String? bestCode;
  double? bestPercentage;
  String? fallbackCode;
  for (var i = 0; i < seriesValues.length; i++) {
    final code = codeOf(seriesValues[i]);
    if (code == null) continue;
    fallbackCode ??= code;
    final raw = i < percentageValues.length ? percentageValues[i] : null;
    final percentage = raw is num ? raw.toDouble() : jsParseFloat(raw);
    if (percentage != null &&
        !percentage.isNaN &&
        (bestPercentage == null || percentage > bestPercentage)) {
      bestPercentage = percentage;
      bestCode = code;
    }
  }
  return bestCode ?? fallbackCode;
}
