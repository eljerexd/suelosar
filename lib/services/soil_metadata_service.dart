import 'dart:convert';

import 'package:flutter/services.dart';

class SoilSeriesMetadata {
  const SoilSeriesMetadata({this.taxonomy, this.fields = const {}});

  factory SoilSeriesMetadata.fromJson(Map<String, dynamic> json) {
    return SoilSeriesMetadata(
      taxonomy: _readString(json['taxonomy']),
      fields: Map<String, Object?>.unmodifiable(json),
    );
  }

  final String? taxonomy;
  final Map<String, Object?> fields;

  static String? _readString(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}

class SoilMetadataService {
  SoilMetadataService({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  static const String defaultAssetPath = 'assets/data/soil_metadata.json';
  static final SoilMetadataService instance = SoilMetadataService();

  final AssetBundle _assetBundle;

  Future<void>? _loadingFuture;
  Map<String, SoilSeriesMetadata>? _metadataBySeries;

  Future<void> load({String assetPath = defaultAssetPath}) {
    return _loadingFuture ??= _loadFromAsset(assetPath);
  }

  SoilSeriesMetadata? metadataForSeries(String seriesName) {
    return _metadataBySeries?[_normalizeSeriesName(seriesName)];
  }

  String? taxonomyForSeries(String seriesName) {
    return metadataForSeries(seriesName)?.taxonomy;
  }

  Future<void> _loadFromAsset(String assetPath) async {
    final rawJson = await _assetBundle.loadString(assetPath);
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      _metadataBySeries = const <String, SoilSeriesMetadata>{};
      return;
    }

    final metadata = <String, SoilSeriesMetadata>{};
    for (final entry in decoded.entries) {
      final seriesName = entry.key.trim();
      final value = entry.value;
      if (seriesName.isEmpty || value is! Map<String, dynamic>) {
        continue;
      }
      metadata[_normalizeSeriesName(seriesName)] = SoilSeriesMetadata.fromJson(
        value,
      );
    }
    _metadataBySeries = Map<String, SoilSeriesMetadata>.unmodifiable(metadata);
  }

  static String _normalizeSeriesName(String value) {
    return value.trim().toLowerCase();
  }
}
