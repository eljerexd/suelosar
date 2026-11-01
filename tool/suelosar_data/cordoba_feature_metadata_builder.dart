import 'dart:collection';

import 'config/province_definition.dart';
import 'normalize/normalizer.dart';
import 'sources/gis_source.dart';

const cordobaCardMetadataFields = <String>[
  'CLASE',
  'SUBCLASE',
  'IP',
  'FASE1',
  'FASE2',
  'FASE3',
  'FASE4',
];

/// Builds a compact O(1) lookup keyed by the same reversible OBJECTID
/// namespace used by Córdoba's normalized map input.
Future<Map<String, Object?>> buildCordobaFeatureMetadataIndex(
  ProvinceDefinition definition,
) async {
  if (definition.id != 'cordoba') {
    throw ArgumentError.value(
      definition.id,
      'definition.id',
      'must be cordoba',
    );
  }

  final normalizer = Normalizer(definition);
  final features = SplayTreeMap<String, Map<String, Object?>>();

  Future<void> collect(GisConfig sourceConfig, int objectIdOffset) async {
    await for (final record in GisSource.open(sourceConfig).records()) {
      final properties = Map<String, Object?>.of(record.properties);
      if (objectIdOffset != 0) {
        final rawId = properties['id'];
        if (rawId is! num || rawId != rawId.roundToDouble()) {
          throw FormatException(
            '${sourceConfig.source}: record ${record.index} has no integer id.',
          );
        }
        properties['id'] = rawId.toInt() + objectIdOffset;
      }

      final mapped = normalizer.apply(
        properties,
        mapping: sourceConfig.mapping,
      );
      final rawObjectId = mapped['OBJECTID'];
      if (rawObjectId is! num || rawObjectId != rawObjectId.roundToDouble()) {
        throw FormatException(
          '${sourceConfig.source}: record ${record.index} did not map to an integer OBJECTID.',
        );
      }

      final metadata = <String, Object?>{
        'SIMBC': mapped['SIMBC'],
        for (final field in cordobaCardMetadataFields)
          if (_hasMetadataValue(mapped[field])) field: mapped[field],
      };
      if (!cordobaCardMetadataFields.any(
        (field) => metadata.containsKey(field),
      )) {
        continue;
      }

      final key = rawObjectId.toInt().toString();
      if (features.containsKey(key)) {
        throw FormatException('Duplicate Córdoba OBJECTID $key.');
      }
      features[key] = metadata;
    }
  }

  await collect(definition.gis, 0);
  for (final source in definition.gis.additionalSources) {
    await collect(
      GisConfig(
        source: source.source,
        format: source.format,
        encoding: source.encoding,
        layerName: definition.gis.layerName,
        mapping: source.mapping,
        series: definition.gis.series,
        thresholds: definition.gis.thresholds,
      ),
      source.objectIdOffset,
    );
  }

  return <String, Object?>{
    'version': 1,
    'province': 'cordoba',
    'identityField': 'OBJECTID',
    'features': features,
  };
}

bool _hasMetadataValue(Object? value) =>
    value != null && (value is! String || value.trim().isNotEmpty);
