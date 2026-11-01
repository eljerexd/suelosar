import '../normalize/field_mapping.dart';
import '../validation/finding.dart';
import 'app_declarations.dart';
import 'pmtiles_metadata.dart';

/// PMT001-PMT003 for one archive. [assetPath] is the archive's path
/// relative to the repo (forward slashes), used to find what the app
/// declares about it. [expectedAttributes] are fields that must appear in
/// the sampled tiles. Returns the comparison with the app, for the report.
Map<String, Object?> checkPmtiles({
  required PmtilesMetadata metadata,
  required String assetPath,
  required AppDeclarations app,
  required Iterable<String> expectedAttributes,
  required String layer,
  required FindingSink findings,
}) {
  final location = assetPath;
  if (metadata.sidecarSha256 == null) {
    findings.warning(
      'PMT001',
      'No existe ${'$assetPath.sha256'}; la app lo usa para detectar cambios.',
      location: location,
    );
  } else if (metadata.sidecarMatches == false) {
    findings.error(
      'PMT001',
      'El .sha256 no coincide con el archivo: sidecar ${metadata.sidecarSha256}, real ${metadata.sha256}.',
      location: '$assetPath.sha256',
    );
  }

  if (!metadata.layers.contains(layer)) {
    findings.error(
      'PMT003',
      'Los tiles muestreados no tienen la capa "$layer" (capas: ${metadata.layers.join(', ')}).',
      location: location,
    );
  } else {
    final missing = [
      for (final a in expectedAttributes)
        if (!metadata.attributesSeen.contains(a)) a,
    ];
    if (missing.isNotEmpty) {
      findings.error(
        'PMT003',
        'Campos del esquema ausentes en los ${metadata.sampledTiles} tiles muestreados: ${missing.join(', ')}.',
        location: location,
        examples: missing,
      );
    }
  }

  final declaration = app.forAsset(assetPath);
  final comparison = <String, Object?>{
    'assetPath': assetPath,
    'declaredByApp': declaration != null,
  };
  if (declaration == null) {
    findings.info(
      'PMT002',
      'Ninguna provincia de la app usa este archivo todavía.',
      location: location,
    );
    return comparison;
  }
  comparison
    ..['appField'] = 'ProvinceConfig.${declaration.field}'
    ..['appId'] = declaration.id
    ..['appDownloadSizeBytes'] = declaration.downloadSizeBytes
    ..['actualSizeBytes'] = metadata.sizeBytes
    ..['sizeMatches'] = declaration.downloadSizeBytes == metadata.sizeBytes;
  if (declaration.downloadSizeBytes == null) {
    findings.info(
      'PMT002',
      'ProvinceConfig.${declaration.field} no declara pmtilesDownloadSizeBytes.',
      location: 'lib/gis/province_config.dart',
    );
  } else if (declaration.downloadSizeBytes != metadata.sizeBytes) {
    findings.warning(
      'PMT002',
      'ProvinceConfig.${declaration.field}.pmtilesDownloadSizeBytes está desactualizado: '
          'la app declara ${declaration.downloadSizeBytes} bytes y el archivo pesa ${metadata.sizeBytes} bytes '
          '(${metadata.sizeMiB.toStringAsFixed(2)} MiB).',
      location: 'lib/gis/province_config.dart',
    );
  }
  final bounds = declaration.bounds;
  if (bounds == null) {
    findings.info(
      'PMT002',
      'No se encontraron los bounds de MapCoverage.${declaration.field}.',
      location: 'lib/gis/map_coverage.dart',
    );
  } else {
    const tolerance = 1e-6;
    final pairs = {
      'minLatitude': (bounds.minLatitude, metadata.bounds.minLatitude),
      'maxLatitude': (bounds.maxLatitude, metadata.bounds.maxLatitude),
      'minLongitude': (bounds.minLongitude, metadata.bounds.minLongitude),
      'maxLongitude': (bounds.maxLongitude, metadata.bounds.maxLongitude),
    };
    final different = [
      for (final e in pairs.entries)
        if ((e.value.$1 - e.value.$2).abs() > tolerance)
          '${e.key}: app ${e.value.$1}, archivo ${e.value.$2}',
    ];
    comparison
      ..['appBounds'] = bounds.toJson()
      ..['boundsMatch'] = different.isEmpty;
    if (different.isNotEmpty) {
      findings.warning(
        'PMT002',
        'MapCoverage.${declaration.field} tiene bounds distintos a los del archivo.',
        location: 'lib/gis/map_coverage.dart',
        examples: different,
      );
    }
  }
  return comparison;
}

/// Schema fields a province's archive is expected to carry: the thresholded
/// fields it actually maps (an absent field has nothing to carry, and the
/// sparse series slots may legitimately be missing from a sample).
List<String> expectedArchiveAttributes(
  FieldMapping mapping,
  List<String> thresholdFields,
) => [
  for (final field in thresholdFields)
    if (mapping.ruleFor(field) case final rule? when rule is! AbsentRule) field,
];
