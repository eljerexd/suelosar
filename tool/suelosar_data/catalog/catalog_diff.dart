import 'dart:convert';

import '../validation/finding.dart';

/// Differences between a generated catalog and the one the app ships.
class CatalogDiff {
  CatalogDiff._({
    required this.added,
    required this.removed,
    required this.changed,
    required this.orderDiffers,
    required this.contentEqual,
    required this.textEqual,
    required this.firstTextDifferenceLine,
  });

  /// Compares [generated] with [referenceText] (the file on disk).
  /// Records are matched by [keyOf]; text is compared with line endings
  /// normalized (git checks these files out with CRLF on Windows).
  factory CatalogDiff.compare({
    required Object? generated,
    required String generatedText,
    required String referenceText,
    required Map<String, Map<String, Object?>> Function(Object? document)
    recordsOf,
  }) {
    final reference = jsonDecode(referenceText);
    final generatedRecords = recordsOf(generated);
    final referenceRecords = recordsOf(reference);
    final added = [
      for (final key in generatedRecords.keys)
        if (!referenceRecords.containsKey(key)) key,
    ];
    final removed = [
      for (final key in referenceRecords.keys)
        if (!generatedRecords.containsKey(key)) key,
    ];
    final changed = <String>[];
    for (final entry in generatedRecords.entries) {
      final old = referenceRecords[entry.key];
      if (old == null) continue;
      for (final field in {...entry.value.keys, ...old.keys}) {
        if (jsonEncode(entry.value[field]) != jsonEncode(old[field])) {
          changed.add(
            '${entry.key}.$field: ${jsonEncode(old[field])} -> ${jsonEncode(entry.value[field])}',
          );
        }
      }
    }
    final commonGenerated = [
      for (final k in generatedRecords.keys)
        if (referenceRecords.containsKey(k)) k,
    ];
    final commonReference = [
      for (final k in referenceRecords.keys)
        if (generatedRecords.containsKey(k)) k,
    ];
    final orderDiffers =
        commonGenerated.join('\u0000') != commonReference.join('\u0000');

    String normalize(String text) => text.replaceAll('\r\n', '\n');
    final a = normalize(generatedText);
    final b = normalize(referenceText);
    int? firstDifference;
    if (a != b) {
      final aLines = a.split('\n');
      final bLines = b.split('\n');
      for (var i = 0; i < aLines.length || i < bLines.length; i++) {
        if (i >= aLines.length ||
            i >= bLines.length ||
            aLines[i] != bLines[i]) {
          firstDifference = i + 1;
          break;
        }
      }
    }
    return CatalogDiff._(
      added: added,
      removed: removed,
      changed: changed,
      orderDiffers: orderDiffers,
      contentEqual: jsonEncode(generated) == jsonEncode(reference),
      textEqual: a == b,
      firstTextDifferenceLine: firstDifference,
    );
  }

  final List<String> added;
  final List<String> removed;
  final List<String> changed;
  final bool orderDiffers;

  /// Same JSON document, key order included.
  final bool contentEqual;

  /// Same file text (line endings aside).
  final bool textEqual;
  final int? firstTextDifferenceLine;

  bool get hasRecordDifferences =>
      added.isNotEmpty || removed.isNotEmpty || changed.isNotEmpty;

  Map<String, Object?> toJson() => {
    'contentEqual': contentEqual,
    'textEqual': textEqual,
    'firstTextDifferenceLine': firstTextDifferenceLine,
    'added': added,
    'removed': removed,
    'changed': changed,
    'orderDiffers': orderDiffers,
  };

  void report(FindingSink findings, String referenceLocation) {
    if (textEqual) {
      findings.info(
        'CAT007',
        'El catálogo generado es idéntico al de la app (byte a byte, sin contar fin de línea).',
        location: referenceLocation,
      );
      return;
    }
    if (hasRecordDifferences) {
      findings.warning(
        'CAT006',
        'El catálogo generado difiere del de la app: ${added.length} nuevos, '
            '${removed.length} quitados, ${changed.length} campos cambiados.',
        location: referenceLocation,
        examples: [
          ...added.map((k) => '+ $k'),
          ...removed.map((k) => '- $k'),
          ...changed.map((c) => '~ $c'),
        ],
        count: added.length + removed.length + changed.length,
      );
    }
    if (!hasRecordDifferences && orderDiffers) {
      findings.warning(
        'CAT006',
        'Mismos registros que la app, en otro orden.',
        location: referenceLocation,
      );
    }
    if (!hasRecordDifferences && !orderDiffers) {
      findings.warning(
        'CAT006',
        'Mismos datos que la app pero distinto formato de archivo '
            '(primera diferencia en la línea $firstTextDifferenceLine).',
        location: referenceLocation,
      );
    }
  }
}
