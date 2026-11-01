import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants/asset_paths.dart';
import 'gis_feature.dart';

/// Adds source-backed Córdoba card fields omitted from the current PMTiles.
/// The compact index is loaded once and joined by the pipeline's reversible
/// OBJECTID namespace; no source geometry or per-tap dataset scan is needed.
class CordobaFeatureMetadataRepository {
  CordobaFeatureMetadataRepository({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  static const _metadataFields = <String>{
    'CLASE',
    'SUBCLASE',
    'IP',
    'FASE1',
    'FASE2',
    'FASE3',
    'FASE4',
  };

  final AssetBundle _assetBundle;
  Future<Map<String, Map<String, Object?>>>? _indexFuture;

  Future<GisFeature> enrichCardFeature(GisFeature feature) async {
    final objectId = _integer(feature.properties['OBJECTID']);
    if (objectId == null) return feature;

    final entry = (await (_indexFuture ??= _loadIndex()))[objectId.toString()];
    if (entry == null) return feature;

    final sourceSymbol = _text(entry['SIMBC']);
    final featureSymbol = _text(feature.properties['SIMBC']);
    if (sourceSymbol != null &&
        featureSymbol != null &&
        sourceSymbol != featureSymbol) {
      debugPrint(
        'Córdoba metadata skipped for OBJECTID $objectId: SIMBC mismatch.',
      );
      return feature;
    }

    final properties = Map<String, Object?>.of(feature.properties);
    var changed = false;
    for (final field in _metadataFields) {
      final current = properties[field];
      final sourceValue = entry[field];
      if (_hasValue(current) || !_hasValue(sourceValue)) continue;
      properties[field] = sourceValue;
      changed = true;
    }
    if (!changed) return feature;

    return GisFeature(
      id: feature.id,
      geometry: feature.geometry,
      properties: Map<String, Object?>.unmodifiable(properties),
      locality: feature.locality,
      soilMapId: feature.soilMapId,
    );
  }

  Future<Map<String, Map<String, Object?>>> _loadIndex() async {
    final decoded = jsonDecode(
      await _assetBundle.loadString(AssetPaths.cordobaFeatureMetadata),
    );
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['province'] != 'cordoba' ||
        decoded['identityField'] != 'OBJECTID' ||
        decoded['features'] is! Map) {
      throw const FormatException('Invalid Córdoba feature metadata index.');
    }
    final rawFeatures = decoded['features'] as Map;
    return Map<String, Map<String, Object?>>.unmodifiable({
      for (final item in rawFeatures.entries)
        if (item.key is String && item.value is Map)
          item.key as String: Map<String, Object?>.unmodifiable(
            (item.value as Map).cast<String, Object?>(),
          ),
    });
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

  static bool _hasValue(Object? value) =>
      value != null && (value is! String || value.trim().isNotEmpty);
}
