import 'dart:convert';
import 'dart:io';

import '../config/province_definition.dart';
import '../schema/suelosar_schema.dart';
import '../sources/gis_source.dart';
import '../sources/series_rules.dart';
import 'field_mapping.dart';

/// Coverage of one column (source or target).
class ColumnProfile {
  ColumnProfile(this.name);

  static const _distinctLimit = 1000;

  final String name;
  int filled = 0;
  int empty = 0;
  int whitespaceOnly = 0;
  int nonNumeric = 0;
  final Map<String, int> _values = {};
  bool distinctOverflow = false;
  final Set<String> types = {};

  void add(Object? value, {bool expectNumeric = false}) {
    if (value == null) {
      empty++;
      return;
    }
    types.add(switch (value) {
      String() => 'texto',
      int() => 'entero',
      double() => 'decimal',
      bool() => 'lógico',
      _ => value.runtimeType.toString(),
    });
    if (value is String && value.trim().isEmpty) {
      empty++;
      if (value.isNotEmpty) whitespaceOnly++;
      return;
    }
    filled++;
    if (expectNumeric &&
        value is! num &&
        double.tryParse(value.toString().trim()) == null) {
      nonNumeric++;
    }
    final key = value.toString();
    if (_values.containsKey(key)) {
      _values[key] = _values[key]! + 1;
    } else if (_values.length < _distinctLimit) {
      _values[key] = 1;
    } else {
      distinctOverflow = true;
    }
  }

  int get total => filled + empty;
  double get coverage => total == 0 ? 0 : filled * 100 / total;
  int get distinct => _values.length;

  List<MapEntry<String, int>> topValues([int count = 5]) {
    final entries = _values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(count).toList();
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'filled': filled,
    'empty': empty,
    'whitespaceOnly': whitespaceOnly,
    'nonNumeric': nonNumeric,
    'coveragePercent': double.parse(coverage.toStringAsFixed(2)),
    'distinct': distinct,
    'distinctOverflow': distinctOverflow,
    'types': types.toList()..sort(),
    'top': [
      for (final e in topValues()) {'value': e.key, 'count': e.value},
    ],
  };
}

/// Result of reading (and optionally normalizing) a province's GIS.
class NormalizeResult {
  NormalizeResult({
    required this.featureCount,
    required this.sourceColumns,
    required this.declaredColumns,
    required this.sourceProfiles,
    required this.targetProfiles,
    required this.seriesFeatureCounts,
    required this.seriesExamples,
    required this.seriesVariants,
    required this.featuresWithSeries,
    required this.featuresWithUncataloguedSeries,
    required this.nullGeometries,
    required this.encodingIssues,
    required this.encodingName,
    required this.outputFile,
  });

  final int featureCount;

  /// Every column seen in the source (union over features for GeoJSON).
  final Set<String> sourceColumns;
  final List<String>? declaredColumns;
  final Map<String, ColumnProfile> sourceProfiles;
  final Map<String, ColumnProfile> targetProfiles;

  /// Catalog lookup key -> number of features using that series.
  final Map<String, int> seriesFeatureCounts;

  /// Catalog lookup key -> one raw series value, for readable reports.
  final Map<String, String> seriesExamples;

  /// Catalog lookup key -> every distinct raw code/name that maps to it.
  final Map<String, Set<String>> seriesVariants;
  final int featuresWithSeries;

  /// Features with at least one series missing from the catalog.
  final int? featuresWithUncataloguedSeries;
  final int? nullGeometries;
  final List<EncodingIssue> encodingIssues;
  final String encodingName;
  final String? outputFile;
}

/// Applies a province's [FieldMapping] to its GIS source.
class Normalizer {
  Normalizer(this.definition, {this.seriesNames = const {}, this.catalogKeys});

  final ProvinceDefinition definition;

  /// Catalog lookup key -> series name, for `derive: dominant_series_name`.
  final Map<String, String> seriesNames;

  /// Catalog lookup keys; when given, features using a series outside the
  /// catalog are counted.
  final Set<String>? catalogKeys;

  GisConfig get _gis => definition.gis;

  String? _codeOf(Object? raw) => switch (_gis.series.codeRule) {
    SeriesCodeRule.firstToken => firstTokenCode(raw),
    SeriesCodeRule.wholeValue =>
      raw == null || raw.toString().trim().isEmpty
          ? null
          : raw.toString().trim(),
  };

  /// Lookup key of a series code from the GIS, after aliases.
  String seriesKey(String code) => matchKey(_gis.series.aliases[code] ?? code);

  /// Lookup key of a code or name, as the app compares them.
  String matchKey(String value) => switch (_gis.series.match) {
    SeriesMatch.caseInsensitive => normalizeCode(value),
    SeriesMatch.normalizedName => normalizeSeriesName(value),
  };

  /// Maps one feature's properties to the SuelosAR schema, in the mapping's
  /// declaration order.
  Map<String, Object?> apply(Map<String, Object?> properties) {
    final mapped = <String, Object?>{};
    final derived = <DeriveRule>[];
    for (final rule in _gis.mapping.rules) {
      switch (rule) {
        case CopyRule():
          mapped[rule.target] = properties[rule.source] ?? rule.emptyValue;
        case AbsentRule():
          mapped[rule.target] = rule.value;
        case DeriveRule():
          mapped[rule.target] = null; // placeholder keeps the declared order
          derived.add(rule);
      }
    }
    for (final rule in derived) {
      switch (rule.derivation) {
        case Derivation.dominantSeriesName:
          final code = dominantSeriesCode(
            [for (final f in SuelosArSchema.seriesFields) mapped[f]],
            [for (final f in SuelosArSchema.percentageFields) mapped[f]],
            _codeOf,
          );
          mapped[rule.target] = code == null
              ? rule.emptyValue
              : seriesNames[seriesKey(code)] ?? rule.emptyValue;
      }
    }
    return mapped;
  }

  /// Reads every feature. With [output], writes the normalized collection
  /// there (one feature per line, geometry copied verbatim).
  Future<NormalizeResult> run({File? output}) async {
    final source = GisSource.open(_gis);
    final declared = source.declaredColumns();
    final sourceProfiles = <String, ColumnProfile>{};
    final targetProfiles = {
      for (final t in _gis.mapping.targets) t: ColumnProfile(t),
    };
    final seriesCounts = <String, int>{};
    final seriesExamples = <String, String>{};
    final seriesVariants = <String, Set<String>>{};
    var features = 0;
    var withSeries = 0;
    var withUncataloguedSeries = 0;
    var nullGeometries = 0;

    IOSink? sink;
    if (output != null) {
      output.parent.createSync(recursive: true);
      sink = output.openWrite();
      sink.write(
        '{"type":"FeatureCollection","name":${jsonEncode('${definition.id}_normalized')},'
        '"crs":{"type":"name","properties":{"name":"urn:ogc:def:crs:OGC:1.3:CRS84"}},"features":[\n',
      );
    }
    try {
      await for (final record in source.records(withGeometry: output != null)) {
        features++;
        record.properties.forEach((column, value) {
          sourceProfiles
              .putIfAbsent(column, () => ColumnProfile(column))
              .add(value);
        });
        final mapped = apply(record.properties);
        mapped.forEach((target, value) {
          targetProfiles[target]!.add(
            value,
            expectNumeric: SuelosArSchema.isPercentage(target),
          );
        });

        final keys = <String>{};
        for (final field in SuelosArSchema.seriesFields) {
          final code = _codeOf(mapped[field]);
          if (code == null) continue;
          final key = seriesKey(code);
          keys.add(key);
          seriesExamples.putIfAbsent(key, () => code);
          seriesVariants.putIfAbsent(key, () => {}).add(code);
        }
        if (keys.isNotEmpty) withSeries++;
        if (catalogKeys != null &&
            keys.any((key) => !catalogKeys!.contains(key))) {
          withUncataloguedSeries++;
        }
        for (final key in keys) {
          seriesCounts[key] = (seriesCounts[key] ?? 0) + 1;
        }

        if (sink != null) {
          if (record.geometryJson == null) nullGeometries++;
          if (features > 1) sink.write(',\n');
          sink.write('{"type":"Feature","properties":');
          sink.write(jsonEncode(mapped));
          sink.write(',"geometry":');
          sink.write(record.geometryJson ?? 'null');
          sink.write('}');
        }
      }
      sink?.write('\n]}\n');
    } finally {
      await sink?.close();
    }
    // Columns that exist in the source schema but are empty on every
    // feature still count as present.
    for (final column in declared ?? const <String>[]) {
      sourceProfiles.putIfAbsent(column, () => ColumnProfile(column));
    }
    // A GeoJSON feature may simply omit a property: that is an empty value.
    for (final profile in sourceProfiles.values) {
      profile.empty += features - profile.total;
    }

    return NormalizeResult(
      featureCount: features,
      sourceColumns: {...sourceProfiles.keys},
      declaredColumns: declared,
      sourceProfiles: sourceProfiles,
      targetProfiles: targetProfiles,
      seriesFeatureCounts: seriesCounts,
      seriesExamples: seriesExamples,
      seriesVariants: seriesVariants,
      featuresWithSeries: withSeries,
      featuresWithUncataloguedSeries: catalogKeys == null
          ? null
          : withUncataloguedSeries,
      nullGeometries: output == null ? null : nullGeometries,
      encodingIssues: List.of(source.encodingIssues),
      encodingName: source.encodingName,
      outputFile: output?.path,
    );
  }
}
