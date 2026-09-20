import 'dart:convert';
import 'dart:io';

import '../config/province_definition.dart';
import '../gis_build/scale_zone_index.dart';
import '../schema/suelosar_schema.dart';
import '../sources/gis_source.dart';
import '../sources/series_rules.dart';
import 'field_mapping.dart';

/// Merge stats for one [AdditionalGisSource] (Parte 12) — how many of its
/// features were read, discarded, and kept, and why.
class AdditionalSourceStats {
  const AdditionalSourceStats({
    required this.id,
    required this.scale,
    required this.featuresRead,
    required this.emptyGeometryDiscarded,
    required this.emptyGeometryNames,
    required this.outOfZoneDiscarded,
    required this.kept,
  });

  final String id;
  final String scale;
  final int featuresRead;

  /// Features with no geometry at all (never had one in the source) —
  /// discarded, not invented.
  final int emptyGeometryDiscarded;
  final List<String> emptyGeometryNames;

  /// Features whose centroid falls outside this source's own scale zone
  /// (official index) — including anywhere `source`'s own 50k zone applies.
  final int outOfZoneDiscarded;

  /// Features actually merged into the final collection.
  final int kept;

  Map<String, Object?> toJson() => {
    'id': id,
    'scale': scale,
    'featuresRead': featuresRead,
    'emptyGeometryDiscarded': emptyGeometryDiscarded,
    'emptyGeometryNames': emptyGeometryNames,
    'outOfZoneDiscarded': outOfZoneDiscarded,
    'kept': kept,
  };
}

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
    this.nonSeriesFeatureCounts = const {},
    this.additionalSourceStats = const [],
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

  /// Raw `SERIEn` value -> number of features, for values matching
  /// `gis.series.not_series` (kept in the data, not catalogued).
  final Map<String, int> nonSeriesFeatureCounts;
  final int featuresWithSeries;

  /// Features with at least one series missing from the catalog.
  final int? featuresWithUncataloguedSeries;
  final int? nullGeometries;
  final List<EncodingIssue> encodingIssues;
  final String encodingName;
  final String? outputFile;

  /// Per-[AdditionalGisSource] merge stats (Parte 12) — empty for every
  /// province with just one GIS source.
  final List<AdditionalSourceStats> additionalSourceStats;

  /// What later stages (the GIS <-> catalog cross-reference) need, for
  /// replaying a reused normalize stage. Column profiles are not kept.
  Map<String, Object?> toSummaryJson() => {
    'featureCount': featureCount,
    'sourceColumns': sourceColumns.toList()..sort(),
    'seriesFeatureCounts': seriesFeatureCounts,
    'seriesExamples': seriesExamples,
    'seriesVariants': {
      for (final e in seriesVariants.entries) e.key: e.value.toList()..sort(),
    },
    'nonSeriesFeatureCounts': nonSeriesFeatureCounts,
    'featuresWithSeries': featuresWithSeries,
    'featuresWithUncataloguedSeries': featuresWithUncataloguedSeries,
    'nullGeometries': nullGeometries,
    'encodingName': encodingName,
    'outputFile': outputFile,
    'additionalSourceStats': [
      for (final s in additionalSourceStats) s.toJson(),
    ],
  };

  factory NormalizeResult.fromSummaryJson(Map<String, Object?> json) =>
      NormalizeResult(
        featureCount: json['featureCount']! as int,
        sourceColumns: {
          for (final c in json['sourceColumns']! as List) c as String,
        },
        declaredColumns: null,
        sourceProfiles: const {},
        targetProfiles: const {},
        seriesFeatureCounts: (json['seriesFeatureCounts']! as Map)
            .cast<String, int>(),
        seriesExamples: (json['seriesExamples']! as Map).cast<String, String>(),
        seriesVariants: {
          for (final e in (json['seriesVariants']! as Map).entries)
            e.key as String: {for (final v in e.value as List) v as String},
        },
        nonSeriesFeatureCounts:
            (json['nonSeriesFeatureCounts'] as Map? ?? const {})
                .cast<String, int>(),
        featuresWithSeries: json['featuresWithSeries']! as int,
        featuresWithUncataloguedSeries:
            json['featuresWithUncataloguedSeries'] as int?,
        nullGeometries: json['nullGeometries'] as int?,
        encodingIssues: const [],
        encodingName: json['encodingName']! as String,
        outputFile: json['outputFile'] as String?,
        additionalSourceStats: [
          for (final raw in (json['additionalSourceStats'] as List? ?? const []))
            AdditionalSourceStats(
              id: (raw as Map)['id']! as String,
              scale: raw['scale']! as String,
              featuresRead: raw['featuresRead']! as int,
              emptyGeometryDiscarded: raw['emptyGeometryDiscarded']! as int,
              emptyGeometryNames: [
                for (final n in raw['emptyGeometryNames']! as List) n as String,
              ],
              outOfZoneDiscarded: raw['outOfZoneDiscarded']! as int,
              kept: raw['kept']! as int,
            ),
        ],
      );
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
  /// declaration order. [mapping] defaults to the primary source's — pass
  /// an [AdditionalGisSource.mapping] to apply the same logic to an extra
  /// source's own (differently-named) raw columns.
  Map<String, Object?> apply(
    Map<String, Object?> properties, {
    FieldMapping? mapping,
  }) {
    final mapped = <String, Object?>{};
    final derived = <DeriveRule>[];
    for (final rule in (mapping ?? _gis.mapping).rules) {
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

  /// Reads every feature — the primary source, then (Parte 12) each of
  /// [GisConfig.additionalSources] in turn, gated by the official scale
  /// index so an extra source can only fill in where it geographically
  /// owns priority, never override the primary. With [output], writes the
  /// merged collection there (one feature per line, geometry copied
  /// verbatim).
  Future<NormalizeResult> run({File? output}) async {
    final declared = GisSource.open(_gis).declaredColumns();
    final sourceProfiles = <String, ColumnProfile>{};
    // Seeded from the primary mapping AND every additional source's own
    // mapping (Parte 20): an additional source may declare target fields
    // the primary never does — Córdoba's 500mil source maps IP/SUBGRUPOn/
    // POSICIONn, which carta_suelo_50mil_2025's own mapping has no reason
    // to mention. Profiling only the primary's targets would leave those
    // fields with no ColumnProfile to record into below.
    final targetProfiles = {
      for (final t in _gis.mapping.targets) t: ColumnProfile(t),
      for (final extra in _gis.additionalSources)
        for (final t in extra.mapping.targets) t: ColumnProfile(t),
    };
    final seriesCounts = <String, int>{};
    final seriesExamples = <String, String>{};
    final seriesVariants = <String, Set<String>>{};
    final nonSeriesCounts = <String, int>{};
    final notSeries = _gis.series.notSeries;
    var features = 0;
    var withSeries = 0;
    var withUncataloguedSeries = 0;
    var nullGeometries = 0;
    late final String encodingName;
    final encodingIssues = <EncodingIssue>[];

    IOSink? sink;
    if (output != null) {
      output.parent.createSync(recursive: true);
      sink = output.openWrite();
      sink.write(
        '{"type":"FeatureCollection","name":${jsonEncode('${definition.id}_normalized')},'
        '"crs":{"type":"name","properties":{"name":"urn:ogc:def:crs:OGC:1.3:CRS84"}},"features":[\n',
      );
    }

    /// Applies [mapping] to one already-accepted feature and folds it into
    /// every running total/profile/output stream — the exact same logic
    /// for a primary-source feature and a kept additional-source one, so
    /// counts and the written GeoJSON treat them identically once a
    /// feature has been decided to belong in the collection.
    void ingest(Map<String, Object?> properties, String? geometryJson, {
      required FieldMapping mapping,
    }) {
      features++;
      properties.forEach((column, value) {
        sourceProfiles.putIfAbsent(column, () => ColumnProfile(column)).add(value);
      });
      final mapped = apply(properties, mapping: mapping);
      mapped.forEach((target, value) {
        targetProfiles[target]!.add(
          value,
          expectNumeric: SuelosArSchema.isPercentage(target),
        );
      });

      final keys = <String>{};
      final components = <String>{};
      for (final field in [
        ...SuelosArSchema.seriesFields,
        ..._gis.series.extraSeriesFields,
      ]) {
        final code = _codeOf(mapped[field]);
        if (code == null) continue;
        if (notSeries != null && notSeries.hasMatch(code)) {
          components.add(code);
          continue;
        }
        final key = seriesKey(code);
        keys.add(key);
        seriesExamples.putIfAbsent(key, () => code);
        seriesVariants.putIfAbsent(key, () => {}).add(code);
      }
      if (keys.isNotEmpty) withSeries++;
      if (catalogKeys != null && keys.any((key) => !catalogKeys!.contains(key))) {
        withUncataloguedSeries++;
      }
      for (final key in keys) {
        seriesCounts[key] = (seriesCounts[key] ?? 0) + 1;
      }
      for (final value in components) {
        nonSeriesCounts[value] = (nonSeriesCounts[value] ?? 0) + 1;
      }

      if (sink != null) {
        if (geometryJson == null) nullGeometries++;
        if (features > 1) sink.write(',\n');
        sink.write('{"type":"Feature","properties":');
        sink.write(jsonEncode(mapped));
        sink.write(',"geometry":');
        sink.write(geometryJson ?? 'null');
        sink.write('}');
      }
    }

    final additionalStats = <AdditionalSourceStats>[];
    try {
      final primary = GisSource.open(_gis);
      await for (final record in primary.records(withGeometry: output != null)) {
        ingest(record.properties, record.geometryJson, mapping: _gis.mapping);
      }
      encodingName = primary.encodingName;
      encodingIssues.addAll(primary.encodingIssues);

      if (_gis.additionalSources.isNotEmpty) {
        final priority = _gis.scalePriority!;
        final zoneIndex = ScaleZoneIndex.load(
          File(priority.indexFile),
          field: priority.field,
        );
        for (final extra in _gis.additionalSources) {
          final extraSource = GisSource.open(
            GisConfig(
              source: extra.source,
              format: extra.format,
              encoding: extra.encoding,
              layerName: _gis.layerName,
              mapping: extra.mapping,
              series: _gis.series,
              thresholds: _gis.thresholds,
            ),
          );
          var read = 0;
          var emptyGeometry = 0;
          final emptyGeometryNames = <String>[];
          var outOfZone = 0;
          var kept = 0;
          // Geometry is always needed here (for the zone lookup), even on
          // an `output: null` dry run — otherwise `inspect`/`validate`
          // couldn't report accurate merge stats.
          await for (final record in extraSource.records(withGeometry: true)) {
            read++;
            final geometryJson = record.geometryJson;
            if (geometryJson == null) {
              emptyGeometry++;
              final label =
                  record.properties['pdf_simbolo'] ??
                  record.properties['simbolo'] ??
                  record.index;
              emptyGeometryNames.add(label.toString());
              continue;
            }
            final geometry =
                jsonDecode(geometryJson) as Map<String, dynamic>;
            final centroid = polygonCentroid(geometry);
            // A present-but-empty geometry (`"coordinates":[]` — real cases
            // in carta_suelo_100mil_2025, not a hypothetical) has no
            // centroid to test against the scale index: it belongs in the
            // "empty geometry" count, not "out of zone" — those measure
            // different things (a document defect vs. a real feature this
            // province simply doesn't own here).
            if (centroid == null) {
              emptyGeometry++;
              final label =
                  record.properties['pdf_simbolo'] ??
                  record.properties['simbolo'] ??
                  record.index;
              emptyGeometryNames.add(label.toString());
              continue;
            }
            final scale = zoneIndex.scaleAt(centroid.$1, centroid.$2);
            if (scale != extra.scale) {
              outOfZone++;
              continue;
            }
            kept++;
            final properties = Map<String, Object?>.of(record.properties);
            final rawId = properties['id'];
            if (rawId is num) {
              properties['id'] = rawId.toInt() + extra.objectIdOffset;
            }
            ingest(properties, geometryJson, mapping: extra.mapping);
          }
          additionalStats.add(
            AdditionalSourceStats(
              id: extra.id,
              scale: extra.scale,
              featuresRead: read,
              emptyGeometryDiscarded: emptyGeometry,
              emptyGeometryNames: emptyGeometryNames,
              outOfZoneDiscarded: outOfZone,
              kept: kept,
            ),
          );
          encodingIssues.addAll(extraSource.encodingIssues);
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
      nonSeriesFeatureCounts: nonSeriesCounts,
      featuresWithSeries: withSeries,
      featuresWithUncataloguedSeries: catalogKeys == null
          ? null
          : withUncataloguedSeries,
      nullGeometries: output == null ? null : nullGeometries,
      encodingIssues: encodingIssues,
      encodingName: encodingName,
      outputFile: output?.path,
      additionalSourceStats: additionalStats,
    );
  }
}
