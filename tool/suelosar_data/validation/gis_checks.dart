import '../config/province_definition.dart';
import '../normalize/field_mapping.dart';
import '../normalize/normalizer.dart';
import '../schema/suelosar_schema.dart';
import 'finding.dart';

/// Attribute-level checks of a GIS read (GIS001-GIS007, CFG002, SRC003).
void checkGis(
  ProvinceDefinition definition,
  NormalizeResult result,
  FindingSink findings,
) {
  final gis = definition.gis;
  final location = definition.display(gis.source);

  final missingTargets = gis.mapping.missingRequiredTargets;
  if (missingTargets.isNotEmpty) {
    findings.error(
      'CFG002',
      'gis.mapping no declara ${missingTargets.length} campos del esquema SuelosAR '
          '(usar from, derive o absent).',
      location: definition.display(definition.configFile),
      examples: missingTargets,
      count: missingTargets.length,
    );
  }

  if (result.featureCount == 0) {
    findings.error(
      'GIS005',
      'La fuente GIS no tiene features.',
      location: location,
    );
    return;
  }

  final lowerColumns = {
    for (final c in result.sourceColumns) c.toLowerCase(): c,
  };
  for (final rule in gis.mapping.rules.whereType<CopyRule>()) {
    if (result.sourceColumns.contains(rule.source)) continue;
    final similar = lowerColumns[rule.source.toLowerCase()];
    findings.error(
      'GIS001',
      '${rule.target}: la columna de origen "${rule.source}" no existe en la fuente'
          '${similar == null ? '' : ' (¿quisiste decir "$similar"?)'}.',
      location: location,
    );
  }

  for (final target in gis.thresholds.fields) {
    final rule = gis.mapping.ruleFor(target);
    final profile = result.targetProfiles[target];
    if (rule == null || rule is AbsentRule || profile == null) continue;
    if (rule is CopyRule && !result.sourceColumns.contains(rule.source)) {
      continue;
    }
    final coverage = profile.coverage;
    final text =
        '$target (${_describe(rule)}): cobertura ${coverage.toStringAsFixed(1)} % '
        '(${profile.empty} de ${profile.total} vacíos).';
    if (coverage < gis.thresholds.errorBelow) {
      findings.error(
        'GIS002',
        '$text Mínimo: ${gis.thresholds.errorBelow} %.',
        location: location,
      );
    } else if (coverage < gis.thresholds.warnBelow) {
      findings.warning(
        'GIS002',
        '$text Recomendado: ${gis.thresholds.warnBelow} %.',
        location: location,
      );
    }
  }

  for (final profile in result.targetProfiles.values) {
    if (profile.whitespaceOnly > 0) {
      findings.info(
        'GIS003',
        '${profile.name}: ${profile.whitespaceOnly} valores son solo espacios (cuentan como vacíos).',
        location: location,
      );
    }
    if (profile.nonNumeric > 0) {
      findings.warning(
        'GIS004',
        '${profile.name}: ${profile.nonNumeric} valores no son numéricos.',
        location: location,
      );
    }
  }

  for (final rule in gis.mapping.rules.whereType<AbsentRule>()) {
    final sameName = result.sourceProfiles[rule.target];
    if (sameName != null && sameName.filled > 0) {
      findings.warning(
        'GIS007',
        '${rule.target} está declarado como ausente, pero la fuente tiene una columna '
            '"${rule.target}" con ${sameName.filled} valores.',
        location: location,
      );
    }
  }

  final undecodable = [
    for (final i in result.encodingIssues)
      if (!i.suspected) i,
  ];
  final doubleEncoded = [
    for (final i in result.encodingIssues)
      if (i.suspected) i,
  ];
  if (undecodable.isNotEmpty) {
    findings.error(
      'SRC003',
      '${undecodable.length} valores de texto no son válidos en ${result.encodingName} '
          '(o ya contienen el carácter de reemplazo U+FFFD).',
      location: location,
      examples: [
        for (final i in undecodable) 'registro ${i.record}, campo ${i.field}',
      ],
      count: undecodable.length,
    );
  }
  if (doubleEncoded.isNotEmpty) {
    findings.warning(
      'SRC003',
      '${doubleEncoded.length} valores parecen tener doble codificación '
          '(UTF-8 leído como Latin-1, p. ej. "Ã±" en lugar de "ñ").',
      location: location,
      examples: [
        for (final i in doubleEncoded)
          'registro ${i.record}, ${i.field} = "${i.value}"',
      ],
      count: doubleEncoded.length,
    );
  }

  final nullGeometries = result.nullGeometries;
  if (nullGeometries != null && nullGeometries > 0) {
    findings.warning(
      'GIS006',
      '$nullGeometries features no tienen geometría.',
      location: location,
    );
  }
}

String _describe(FieldRule rule) => switch (rule) {
  CopyRule() => 'desde ${rule.source}',
  AbsentRule() => 'ausente',
  DeriveRule() => 'derivado: ${rule.derivation.key}',
};

/// Table rows for the report: one per mapped target.
List<Map<String, Object?>> coverageRows(
  ProvinceDefinition definition,
  NormalizeResult result,
) => [
  for (final rule in definition.gis.mapping.rules)
    {
      'target': rule.target,
      'rule': switch (rule) {
        CopyRule() => 'from',
        AbsentRule() => 'absent',
        DeriveRule() => 'derive',
      },
      'source': switch (rule) {
        CopyRule() => rule.source,
        AbsentRule() => null,
        DeriveRule() => rule.derivation.key,
      },
      if (rule is AbsentRule) 'reason': rule.reason,
      'thresholded': definition.gis.thresholds.fields.contains(rule.target),
      'required': SuelosArSchema.requiredFields.contains(rule.target),
      ...?result.targetProfiles[rule.target]?.toJson(),
    },
];
