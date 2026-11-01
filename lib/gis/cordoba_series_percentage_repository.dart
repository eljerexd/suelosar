import 'dart:convert';

import 'package:flutter/services.dart';

import '../constants/asset_paths.dart';
import 'gis_feature.dart';
import 'gis_soil_series.dart';

String _percentageKey(String series, String phase) => '$series\u0000$phase';

/// Applies only curated, official Córdoba series proportions that are absent
/// from the bundled WFS attributes. Original feature properties are untouched.
class CordobaSeriesPercentageRepository {
  CordobaSeriesPercentageRepository({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  final AssetBundle _assetBundle;
  Future<Map<String, _CordobaUnitSupplement>>? _indexFuture;

  static const _supplementedSymbols = {'SEl3', 'BYc3', 'Ota5'};

  bool mayHaveSupplement(GisFeature feature) {
    final objectId = _integer(feature.properties['OBJECTID']);
    final symbol = _text(feature.properties['SIMBC']);
    return (objectId == 617 && symbol == 'SEl3') ||
        (objectId == 1281 && symbol == 'Ota5') ||
        (objectId == 1371 && symbol == 'BYc3');
  }

  Future<CordobaSeriesCompositionResult> enrichCardSeries({
    required GisFeature feature,
    required List<GisSoilSeries> sourceSeries,
  }) async {
    final objectId = _integer(feature.properties['OBJECTID']);
    if (objectId == null ||
        !_supplementedSymbols.contains(_text(feature.properties['SIMBC']))) {
      return CordobaSeriesCompositionResult(sourceSeries);
    }

    final unit = (await (_indexFuture ??= _loadIndex()))[objectId.toString()];
    if (unit == null ||
        unit.symbol != _text(feature.properties['SIMBC']) ||
        unit.scale != _scaleForObjectId(objectId)) {
      return CordobaSeriesCompositionResult(sourceSeries);
    }

    final supplements = {
      for (final item in unit.individual)
        _percentageKey(item.series, item.phase): item,
    };
    final enriched = sourceSeries
        .map((series) {
          final supplement =
              supplements[_percentageKey(series.name, series.phase)];
          if (series.percentage.isNotEmpty || supplement == null) return series;
          return GisSoilSeries(
            name: series.name,
            percentage: supplement.percentage,
            phase: series.phase,
            position: series.position,
          );
        })
        .toList(growable: false);

    return CordobaSeriesCompositionResult(
      enriched,
      aggregateCompositions: unit.aggregates,
    );
  }

  Future<Map<String, _CordobaUnitSupplement>> _loadIndex() async {
    final decoded = jsonDecode(
      await _assetBundle.loadString(
        AssetPaths.cordobaSeriesPercentageSupplement,
      ),
    );
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['province'] != 'cordoba' ||
        decoded['identityField'] != 'OBJECTID' ||
        decoded['records'] is! Map) {
      throw const FormatException(
        'Invalid Córdoba series-percentage supplement.',
      );
    }

    final records = decoded['records'] as Map;
    final parsed = <String, _CordobaUnitSupplement>{};
    for (final entry in records.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('Invalid Córdoba supplement record.');
      }
      final objectId = int.tryParse(entry.key as String);
      final value = (entry.value as Map).cast<String, Object?>();
      final symbol = _text(value['SIMBC']);
      final scale = _text(value['scale']);
      if (objectId == null ||
          symbol == null ||
          scale == null ||
          scale != _scaleForObjectId(objectId)) {
        throw FormatException(
          'Invalid scale or identity for Córdoba OBJECTID ${entry.key}.',
        );
      }
      parsed[entry.key as String] = _CordobaUnitSupplement(
        symbol: symbol,
        scale: scale,
        individual: _parseIndividual(value['individualPercentages']),
        aggregates: _parseAggregates(value['aggregateCompositions']),
      );
    }
    return Map<String, _CordobaUnitSupplement>.unmodifiable(parsed);
  }

  List<_IndividualPercentage> _parseIndividual(Object? value) {
    if (value is! List) {
      throw const FormatException('Invalid individual percentage list.');
    }
    return List<_IndividualPercentage>.unmodifiable(
      value.map((item) {
        if (item is! Map) {
          throw const FormatException('Invalid individual percentage.');
        }
        final fields = item.cast<String, Object?>();
        final series = _text(fields['series']);
        final percentage = _text(fields['percentage']);
        final phase = fields['phase'];
        if (series == null ||
            percentage == null ||
            phase is! String ||
            !{
              'EXACT_INDIVIDUAL',
              'APPROXIMATE_INDIVIDUAL',
            }.contains(fields['classification']) ||
            _text(fields['sourceUrl']) == null ||
            _text(fields['sourceSha256']) == null ||
            fields['page'] is! int ||
            _text(fields['evidence']) == null) {
          throw const FormatException('Incomplete individual percentage.');
        }
        return _IndividualPercentage(series, phase.trim(), percentage);
      }),
    );
  }

  List<CordobaAggregateSeriesComposition> _parseAggregates(Object? value) {
    if (value is! List) {
      throw const FormatException('Invalid aggregate composition list.');
    }
    return List<CordobaAggregateSeriesComposition>.unmodifiable(
      value.map((item) {
        if (item is! Map) {
          throw const FormatException('Invalid aggregate composition.');
        }
        final fields = item.cast<String, Object?>();
        final series = fields['series'];
        final percentage = _text(fields['percentage']);
        final qualifier = _text(fields['qualifier']);
        if (series is! List ||
            series.isEmpty ||
            series.any((name) => _text(name) == null) ||
            percentage == null ||
            qualifier == null ||
            fields['classification'] != 'AGGREGATE_ONLY' ||
            _text(fields['sourceUrl']) == null ||
            _text(fields['sourceSha256']) == null ||
            fields['page'] is! int ||
            _text(fields['evidence']) == null) {
          throw const FormatException('Incomplete aggregate composition.');
        }
        return CordobaAggregateSeriesComposition(
          series: List<String>.unmodifiable(series.cast<String>()),
          percentage: percentage,
          qualifier: qualifier,
          sourceUrl: fields['sourceUrl'] as String,
          page: fields['page'] as int,
          evidence: fields['evidence'] as String,
        );
      }),
    );
  }

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num && value == value.roundToDouble()) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  static String? _text(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static String? _scaleForObjectId(int objectId) {
    if (objectId >= 0 && objectId < 100000) return '1:50000';
    if (objectId >= 100000 && objectId < 500000) return '1:100000';
    if (objectId >= 500000 && objectId < 600000) return '1:500000';
    return null;
  }
}

class CordobaSeriesCompositionResult {
  CordobaSeriesCompositionResult(
    List<GisSoilSeries> series, {
    this.aggregateCompositions = const [],
  }) : series = List<GisSoilSeries>.unmodifiable(series);

  final List<GisSoilSeries> series;
  final List<CordobaAggregateSeriesComposition> aggregateCompositions;

  List<GisSoilSeries> applyTo(List<GisSoilSeries> current) {
    final supplementalPercentages = {
      for (final item in series)
        if (item.percentage.isNotEmpty)
          _percentageKey(item.name, item.phase): item.percentage,
    };
    return List<GisSoilSeries>.unmodifiable(
      current.map((item) {
        final percentage =
            supplementalPercentages[_percentageKey(item.name, item.phase)];
        if (item.percentage.isNotEmpty || percentage == null) return item;
        return GisSoilSeries(
          name: item.name,
          percentage: percentage,
          phase: item.phase,
          position: item.position,
        );
      }),
    );
  }
}

class CordobaAggregateSeriesComposition {
  const CordobaAggregateSeriesComposition({
    required this.series,
    required this.percentage,
    required this.qualifier,
    required this.sourceUrl,
    required this.page,
    required this.evidence,
  });

  final List<String> series;
  final String percentage;
  final String qualifier;
  final String sourceUrl;
  final int page;
  final String evidence;

  String get displayText {
    final names = series.length == 2
        ? '${series.first} y ${series.last}'
        : series.join(', ');
    final amount = qualifier == 'approximately'
        ? 'aproximadamente $percentage%'
        : '$percentage%';
    return '$names representan $amount en conjunto; la fuente no informa '
        'el porcentaje individual de cada serie.';
  }
}

class _CordobaUnitSupplement {
  const _CordobaUnitSupplement({
    required this.symbol,
    required this.scale,
    required this.individual,
    required this.aggregates,
  });

  final String symbol;
  final String scale;
  final List<_IndividualPercentage> individual;
  final List<CordobaAggregateSeriesComposition> aggregates;
}

class _IndividualPercentage {
  const _IndividualPercentage(this.series, this.phase, this.percentage);

  final String series;
  final String phase;
  final String percentage;
}
