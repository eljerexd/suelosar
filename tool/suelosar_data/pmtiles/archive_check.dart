import '../config/province_definition.dart';
import '../gis_build/prepare.dart';
import '../schema/suelosar_schema.dart';
import '../validation/finding.dart';
import 'optimizer.dart';
import 'pmtiles_metadata.dart';

/// How far (degrees) the archive bounds may extend past the source extent:
/// Tippecanoe rounds bounds and buffers tiles. Córdoba's merged 50k+100k
/// archive showed a real-world margin of ~0.0503° (verified by decoding
/// every z14 tile: no actual feature vertex falls outside the source
/// extent — the excess is purely from Tippecanoe's own bounds rounding),
/// just over the previous 0.05° — widened with headroom instead of tuning
/// to the exact observed value.
const boundsTolerance = 0.1;

/// Schema fields the archive must carry somewhere: every required field
/// except those the province declares `absent`.
List<String> requiredArchiveFields(List<String> absent) => [
  for (final field in SuelosArSchema.requiredFields)
    if (!absent.contains(field)) field,
];

/// MAP001-MAP003 and OPT001-OPT003 for a generated archive.
/// [report] comes from the optimizer's full scan of every tile.
void checkGeneratedArchive({
  required PmtilesMetadata metadata,
  required OptimizeReport report,
  required PmtilesConfig config,
  required List<String> absent,
  required Extent? sourceExtent,
  required FindingSink findings,
  required String location,
}) {
  final header = <String>[
    if (metadata.version != 3) 'versión ${metadata.version} (se espera 3)',
    if (metadata.tileType != 'mvt')
      'tipo de tile ${metadata.tileType} (se espera mvt)',
    if (metadata.minZoom != config.minZoom ||
        metadata.maxZoom != config.maxZoom)
      'zooms ${metadata.minZoom}-${metadata.maxZoom} (configurado ${config.minZoom}-${config.maxZoom})',
    if (!metadata.layers.contains(config.layer))
      'capa "${config.layer}" ausente (capas: ${metadata.layers.join(', ')})',
  ];
  if (header.isNotEmpty) {
    findings.error(
      'MAP001',
      'El PMTiles generado no es el esperado.',
      location: location,
      examples: header,
    );
  }

  final emptyZooms = [
    for (var z = config.minZoom; z <= config.maxZoom; z++)
      if ((report.tilesByZoom[z] ?? 0) == 0) 'z$z',
  ];
  if (emptyZooms.isNotEmpty) {
    findings.error(
      'MAP002',
      'Hay zooms sin tiles.',
      location: location,
      examples: emptyZooms,
    );
  }

  if (sourceExtent != null) {
    final b = metadata.bounds;
    final outside = <String>[
      if (b.minLongitude < sourceExtent.minLongitude - boundsTolerance)
        'oeste ${b.minLongitude} < ${sourceExtent.minLongitude}',
      if (b.maxLongitude > sourceExtent.maxLongitude + boundsTolerance)
        'este ${b.maxLongitude} > ${sourceExtent.maxLongitude}',
      if (b.minLatitude < sourceExtent.minLatitude - boundsTolerance)
        'sur ${b.minLatitude} < ${sourceExtent.minLatitude}',
      if (b.maxLatitude > sourceExtent.maxLatitude + boundsTolerance)
        'norte ${b.maxLatitude} > ${sourceExtent.maxLatitude}',
    ];
    if (outside.isNotEmpty) {
      findings.warning(
        'MAP003',
        'Los bounds del PMTiles exceden la extensión de la fuente (tolerancia $boundsTolerance°).',
        location: location,
        examples: outside,
      );
    }
  }

  final missing = [
    for (final field in requiredArchiveFields(absent))
      if (!report.attributesKept.contains(field)) field,
  ];
  if (missing.isNotEmpty) {
    findings.error(
      'OPT001',
      'Campos obligatorios del esquema ausentes en todo el PMTiles '
          '(${report.uniqueTiles} tiles revisados): ${missing.join(', ')}. No se publica.',
      location: location,
      examples: missing,
    );
  }
  findings.info(
    'OPT003',
    report.rewritten
        ? 'Optimizado: ${report.sizeBefore} -> ${report.sizeAfter} bytes; '
              'se quitaron ${report.attributesRemoved.length} atributos.'
        : 'Sin atributos fuera del esquema: el archivo se copió sin reescribir.',
    location: location,
    examples: [...report.attributesRemoved.toList()..sort()],
  );
}

/// PMT004: the generated archive compared with the one the app ships.
Map<String, Object?> compareWithReference({
  required String sha256,
  required int sizeBytes,
  required String? referenceSha256,
  required int? referenceSize,
  required String? referenceLocation,
  required FindingSink findings,
}) {
  if (referenceLocation == null) {
    return {'declared': false};
  }
  if (referenceSha256 == null) {
    findings.info(
      'PMT004',
      'Todavía no existe el PMTiles de referencia.',
      location: referenceLocation,
    );
    return {'declared': true, 'exists': false};
  }
  final identical = referenceSha256 == sha256;
  if (identical) {
    findings.info(
      'PMT004',
      'El PMTiles generado es idéntico byte a byte al que usa la app.',
      location: referenceLocation,
    );
  } else {
    findings.warning(
      'PMT004',
      'El PMTiles generado difiere del que usa la app '
          '($sizeBytes bytes contra $referenceSize; SHA-256 distinto). Revisar antes de integrarlo.',
      location: referenceLocation,
    );
  }
  return {
    'declared': true,
    'exists': true,
    'path': referenceLocation,
    'sha256': referenceSha256,
    'sizeBytes': referenceSize,
    'identical': identical,
  };
}

/// Integration steps the pipeline deliberately leaves to a person.
List<String> manualSteps({
  required ProvinceDefinition definition,
  required String publishedFile,
  required Map<String, Object?> reference,
  required Map<String, Object?> app,
  required int sizeBytes,
}) {
  final steps = <String>[];
  if (reference['declared'] != true) {
    steps.add(
      'Decidir dónde integrar `$publishedFile` en la app (no hay pmtiles.reference).',
    );
  } else if (reference['identical'] == true) {
    steps.add(
      'Nada que copiar: `$publishedFile` es idéntico a `${reference['path']}`.',
    );
  } else {
    steps.add(
      'Revisar y copiar `$publishedFile` (y su `.sha256`) a `${reference['path']}` — no se hace automáticamente.',
    );
  }
  if (app['declaredByApp'] != true) {
    steps.add(
      'Registrar la provincia en la app (ProvinceConfig / MapCoverage, Android, Windows).',
    );
  } else {
    if (app['sizeMatches'] == false) {
      steps.add(
        'Actualizar ${app['appField']}.pmtilesDownloadSizeBytes a $sizeBytes.',
      );
    }
    if (app['boundsMatch'] == false) {
      steps.add('Actualizar los bounds de MapCoverage (${app['appField']}).');
    }
  }
  return steps;
}
