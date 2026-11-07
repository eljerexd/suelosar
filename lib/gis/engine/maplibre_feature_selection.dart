import 'package:maplibre/maplibre.dart' as ml;

/// Identifies one rendered source feature without copying its tile geometry.
///
/// MVT geometries are clipped to tile boundaries. Selection should therefore
/// filter the original vector source rather than re-encoding a queried tile
/// fragment as a separate GeoJSON polygon.
class MapLibreFeatureSelector {
  const MapLibreFeatureSelector._({
    this.featureId,
    this.propertyName,
    this.propertyValue,
  });

  factory MapLibreFeatureSelector.forFeature({
    required String featureId,
    required Map<String, Object?> properties,
  }) {
    // MVT feature ids are scoped to a tile and can repeat in neighboring
    // tiles. Prefer the source's stable object identifier so selection only
    // highlights fragments belonging to the tapped source feature.
    for (final name in const [
      'OBJECTID',
      'objectid',
      'OBJECTID_1',
      'fid',
      'FID',
    ]) {
      final value = properties[name];
      if (value is num || value is String && value.isNotEmpty) {
        return MapLibreFeatureSelector._(
          propertyName: name,
          propertyValue: value,
        );
      }
    }

    final unprefixedId = featureId.contains(':')
        ? featureId.substring(featureId.indexOf(':') + 1)
        : featureId;
    final numericId = int.tryParse(unprefixedId);
    if (numericId != null && numericId != 0) {
      return MapLibreFeatureSelector._(featureId: numericId);
    }

    return const MapLibreFeatureSelector._();
  }

  final int? featureId;
  final String? propertyName;
  final Object? propertyValue;

  bool get isUsable => featureId != null || propertyName != null;

  ml.Expression<bool> get filter {
    if (featureId case final id?) {
      return ml.Expression<bool>.raw(['==', r'$id', id]);
    }
    if (propertyName case final name?) {
      return ml.Expression<bool>.raw(['==', name, propertyValue]);
    }
    return ml.Expression<bool>.raw(['==', r'$id', -1]);
  }
}
