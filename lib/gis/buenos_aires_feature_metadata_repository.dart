import 'dart:convert';

import 'package:flutter/services.dart';

import '../constants/asset_paths.dart';
import 'gis_feature.dart';

/// Restores Buenos Aires source attributes omitted from the optimized PMTiles.
/// Source OBJECTIDs are not unique, so the join uses the stable pair
/// OBJECTID + SIMBC rather than either field alone.
class BuenosAiresFeatureMetadataRepository {
  BuenosAiresFeatureMetadataRepository({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  final AssetBundle _assetBundle;
  Future<Map<String, Map<String, Object?>>>? _indexFuture;

  Future<GisFeature> enrichCardFeature(GisFeature feature) async {
    final objectId = _integer(feature.properties['OBJECTID']);
    final symbol = _text(feature.properties['SIMBC']);
    if (objectId == null || symbol == null) return feature;

    final key = jsonEncode([objectId.toString(), symbol]);
    final metadata = (await (_indexFuture ??= _loadIndex()))[key];
    if (metadata == null) return feature;

    final properties = Map<String, Object?>.of(feature.properties);
    var changed = false;
    for (final entry in metadata.entries) {
      if (_hasValue(properties[entry.key]) || !_hasValue(entry.value)) continue;
      properties[entry.key] = entry.value;
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
      await _assetBundle.loadString(AssetPaths.buenosAiresFeatureMetadata),
    );
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['province'] != 'buenos_aires' ||
        jsonEncode(decoded['identityFields']) !=
            jsonEncode(['OBJECTID', 'SIMBC']) ||
        decoded['keyEncoding'] != 'json-array' ||
        decoded['features'] is! Map) {
      throw const FormatException('Invalid Buenos Aires feature metadata.');
    }
    final features = decoded['features'] as Map;
    return Map<String, Map<String, Object?>>.unmodifiable({
      for (final entry in features.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: Map<String, Object?>.unmodifiable(
            (entry.value as Map).cast<String, Object?>(),
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
