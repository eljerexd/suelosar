import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cli/pipeline.dart';
import '../config/province_definition.dart';
import '../validation/finding.dart';

const toolVersion = '1.0.0-fase1';

enum ReportStatus {
  ready('✓ LISTA PARA INTEGRAR'),
  readyWithWarnings('⚠ INTEGRABLE CON ADVERTENCIAS'),
  notReady('✗ NO LISTA PARA INTEGRAR');

  const ReportStatus(this.label);
  final String label;
}

class ReportSummary {
  const ReportSummary({
    required this.status,
    required this.errors,
    required this.warnings,
    required this.infos,
  });

  final ReportStatus status;
  final int errors;
  final int warnings;
  final int infos;
}

/// Loads the persisted stage results of a province, in pipeline order.
List<StageResult> loadStages(ProvinceDefinition definition) {
  final dir = Directory(definition.stagesDir);
  if (!dir.existsSync()) return [];
  final stages = <StageResult>[
    for (final file in dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.json'),
    ))
      StageResult.fromJson((jsonDecode(file.readAsStringSync()) as Map).cast()),
  ];
  final order = stageTitles.keys.toList();
  stages.sort((a, b) => order.indexOf(a.name).compareTo(order.indexOf(b.name)));
  return stages;
}

ReportSummary summarize(Iterable<Finding> findings, {bool strict = false}) {
  final errors = countBySeverity(findings, Severity.error);
  final warnings = countBySeverity(findings, Severity.warning);
  final infos = countBySeverity(findings, Severity.info);
  final status = errors > 0 || (strict && warnings > 0)
      ? ReportStatus.notReady
      : warnings > 0
      ? ReportStatus.readyWithWarnings
      : ReportStatus.ready;
  return ReportSummary(
    status: status,
    errors: errors,
    warnings: warnings,
    infos: infos,
  );
}

/// Writes `output/report.md` and `output/report.json` from every persisted
/// stage. [totalMs] is the wall time of the command that produced them
/// (null when only regenerating).
({String markdown, String json, ReportSummary summary}) writeReport(
  ProvinceDefinition definition, {
  int? totalMs,
  bool strict = false,
}) {
  final stages = loadStages(definition);
  final findings = [for (final s in stages) ...s.findings];
  final summary = summarize(findings, strict: strict);
  final now = DateTime.now();
  final stageSum = stages.fold<int>(0, (sum, s) => sum + s.durationMs);

  final json = {
    'tool': 'suelosar_data',
    'toolVersion': toolVersion,
    'generatedAt': now.toIso8601String(),
    'province': {'id': definition.id, 'name': definition.name},
    'config': definition.display(definition.configFile),
    'result': {
      'status': summary.status.name,
      'label': summary.status.label,
      'errors': summary.errors,
      'warnings': summary.warnings,
      'infos': summary.infos,
      'strict': strict,
    },
    'timings': {
      'stages': [
        for (final s in stages)
          {
            'stage': s.name,
            'durationMs': s.durationMs,
            'startedAt': s.startedAt.toIso8601String(),
          },
      ],
      'stagesTotalMs': stageSum,
      'commandTotalMs': totalMs,
    },
    'stages': {for (final s in stages) s.name: s.data},
    'findings': [
      for (final s in stages)
        for (final f in s.findings) {'stage': s.name, ...f.toJson()},
    ],
  };

  final md = _markdown(definition, stages, summary, now, stageSum, totalMs);
  final outDir = Directory(definition.outputDir)..createSync(recursive: true);
  final mdFile = File(p.join(outDir.path, 'report.md'))..writeAsStringSync(md);
  final jsonFile = File(p.join(outDir.path, 'report.json'))
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
  return (markdown: mdFile.path, json: jsonFile.path, summary: summary);
}

String _markdown(
  ProvinceDefinition d,
  List<StageResult> stages,
  ReportSummary summary,
  DateTime now,
  int stageSum,
  int? totalMs,
) {
  final b = StringBuffer()
    ..writeln('# SuelosAR Data Pipeline — ${d.name} (`${d.id}`)')
    ..writeln()
    ..writeln(
      '- Fecha: ${now.toIso8601String().substring(0, 19).replaceFirst('T', ' ')}',
    )
    ..writeln('- Configuración: `${d.display(d.configFile)}`')
    ..writeln('- Herramienta: suelosar_data $toolVersion')
    ..writeln()
    ..writeln('## RESULTADO: ${summary.status.label}')
    ..writeln()
    ..writeln(
      '**${summary.errors} errores · ${summary.warnings} warnings · ${summary.infos} info**',
    )
    ..writeln();
  if (stages.isEmpty) {
    b.writeln('_No hay etapas ejecutadas. Corré `validate` o `build`._');
    return b.toString();
  }

  final byName = {for (final s in stages) s.name: s};
  final sources = byName['sources']?.data;
  if (sources != null) {
    b.writeln('## FUENTES');
    final gis = sources['gis'] as Map?;
    if (gis != null) {
      b.writeln(
        '- ${gis['exists'] == true ? '✓' : '✗'} GIS `${gis['file']}` (${gis['format']}'
        '${gis['sizeBytes'] == null ? '' : ', ${_mib(gis['sizeBytes'] as int)}'})',
      );
    }
    final pdf = sources['pdf'] as Map?;
    if (pdf != null) {
      final what = pdf['model'] == 'per_series'
          ? 'carpeta `${pdf['directory']}`${pdf['files'] == null ? '' : ' — ${pdf['files']} PDFs'}'
          : 'PDF consolidado `${pdf['file']}`${pdf['sizeBytes'] == null ? '' : ' (${_mib(pdf['sizeBytes'] as int)})'}';
      b.writeln('- ${pdf['exists'] == true ? '✓' : '✗'} $what');
    }
    final reference = sources['catalogReference'] as Map?;
    if (reference != null) {
      b.writeln(
        '- ${reference['exists'] == true ? '✓' : '✗'} catálogo actual de la app `${reference['file']}`',
      );
    }
    final pmtiles = sources['pmtiles'] as Map?;
    if (pmtiles != null) {
      b.writeln(
        '- ${pmtiles['exists'] == true ? '✓' : '⚠'} PMTiles `${pmtiles['file']}`',
      );
    }
    b.writeln();
  }

  final gis = byName['gis']?.data;
  if (gis != null && gis['features'] != null) {
    b
      ..writeln('## GIS — ${_int(gis['features'] as int)} features')
      ..writeln()
      ..writeln(
        'Codificación: ${gis['encoding']} · columnas de origen: ${gis['sourceColumns']} · '
        'series distintas: ${gis['distinctSeries']}'
        '${gis['nullGeometries'] == null ? '' : ' · sin geometría: ${gis['nullGeometries']}'}'
        '${gis['output'] == null ? '' : ' · salida: `${gis['output']}` (${_mib(gis['outputBytes'] as int)})'}',
      )
      ..writeln()
      ..writeln('| Campo destino | Origen | Cobertura | Vacíos | Estado |')
      ..writeln('|---|---|---:|---:|---|');
    final gisFindings = byName['gis']!.findings;
    for (final row in (gis['coverage'] as List).cast<Map>()) {
      final target = row['target'];
      final source = switch (row['rule']) {
        'from' => '`${row['source']}`',
        'derive' => 'derivado (`${row['source']}`)',
        _ => '— (ausente)',
      };
      final total = (row['filled'] as int? ?? 0) + (row['empty'] as int? ?? 0);
      final coverage = row['rule'] == 'absent'
          ? '—'
          : _pct(row['coveragePercent'] as num?);
      final empty = row['rule'] == 'absent' || total == 0
          ? '—'
          : _pct((row['empty'] as int) * 100 / total);
      final state = row['rule'] == 'absent'
          ? 'ℹ ${row['reason']}'
          : _fieldState(
              gisFindings,
              target as String,
              row['thresholded'] == true,
            );
      b.writeln('| $target | $source | $coverage | $empty | $state |');
    }
    b.writeln();
  }

  final catalog = byName['catalog']?.data;
  if (catalog != null && catalog['model'] != null) {
    b.writeln('## CATÁLOGO (${catalog['model']})');
    if (catalog['model'] == 'per_series') {
      b.writeln(
        '- ${catalog['records']} cartas desde ${catalog['pdfFiles']} PDFs (${catalog['seriesKeys']} series distintas)',
      );
    } else {
      final range = catalog['pageRange'] as List?;
      b.writeln(
        '- ${catalog['series']} series · ${catalog['pages']} páginas · page_offset ${catalog['pageOffset']}'
        '${catalog['pageOffsetDetected'] == true ? ' (detectado)' : ''}'
        '${range == null ? '' : ' · páginas ${range[0]}–${range[1]}'}',
      );
    }
    if (catalog['output'] != null) {
      b.writeln('- Generado: `${catalog['output']}`');
    }
    final diff = catalog['diff'] as Map?;
    if (diff != null) {
      final verdict = diff['textEqual'] == true
          ? '✓ idéntico byte a byte'
          : diff['contentEqual'] == true
          ? '⚠ mismos datos, distinto formato'
          : '⚠ con diferencias (${(diff['added'] as List).length} nuevos, '
                '${(diff['removed'] as List).length} quitados, ${(diff['changed'] as List).length} cambios)';
      b.writeln('- Comparado con `${diff['reference']}`: $verdict');
    }
    b.writeln();
  }

  final xref = byName['crossref']?.data;
  if (xref != null && xref['gisSeries'] != null) {
    b
      ..writeln('## CRUCE GIS ↔ CATÁLOGO')
      ..writeln(
        '- ${xref['gisSeries']} series en el GIS · ${xref['catalogEntries']} ${xref['catalogKind']}',
      )
      ..writeln(
        '- ${xref['gisSeriesWithoutCatalog']} series del GIS sin catálogo '
        '(${xref['featuresWithUncataloguedSeries']} features, ${_pct(xref['featuresWithUncataloguedSeriesPercent'] as num)} '
        'de las que tienen series)',
      )
      ..writeln(
        '- ${xref['catalogEntriesWithoutGis']} ${xref['catalogKind']} sin series en el GIS',
      )
      ..writeln();
  }

  final pmtiles = byName['pmtiles']?.data;
  final metadata = pmtiles?['metadata'] as Map?;
  if (metadata != null) {
    final bounds = metadata['bounds'] as Map;
    final center = metadata['center'] as Map;
    final app = pmtiles!['app'] as Map?;
    b
      ..writeln('## PMTILES')
      ..writeln(
        '- `${metadata['file']}` — ${_int(metadata['sizeBytes'] as int)} bytes (${metadata['sizeMiB']} MiB)',
      )
      ..writeln(
        '- SHA-256 `${metadata['sha256']}` — sidecar '
        '${metadata['sha256SidecarMatches'] == true
            ? '✓ coincide'
            : metadata['sha256SidecarMatches'] == false
            ? '✗ NO coincide'
            : '⚠ no existe'}',
      )
      ..writeln(
        '- Zoom ${metadata['minZoom']}–${metadata['maxZoom']} · centro ${center['latitude']}, ${center['longitude']} (z${center['zoom']})',
      )
      ..writeln(
        '- Bounds lat ${bounds['minLatitude']} … ${bounds['maxLatitude']}, lon ${bounds['minLongitude']} … ${bounds['maxLongitude']}',
      )
      ..writeln(
        '- Atributos vistos en ${metadata['sampledTiles']} tiles: ${(metadata['attributesSeen'] as List).join(', ')}',
      );
    if (app != null && app['declaredByApp'] == true) {
      b.writeln(
        '- App (`${app['appField']}`): tamaño ${app['sizeMatches'] == true ? '✓' : '⚠'} '
        '${app['appDownloadSizeBytes']} declarado · bounds ${app['boundsMatch'] == true
            ? '✓'
            : app['boundsMatch'] == false
            ? '⚠'
            : '?'}',
      );
    }
    if (pmtiles['output'] != null) {
      b.writeln('- Metadatos: `${pmtiles['output']}`');
    }
    b.writeln();
  }

  final geometry = byName['geometry']?.data;
  if (geometry != null && geometry['features'] != null) {
    b
      ..writeln('## GEOMETRÍAS (GDAL, antes de reparar)')
      ..writeln(
        '- ${geometry['features']} features · ${geometry['invalidGeometries']} inválidas · ${geometry['nullGeometries']} nulas',
      )
      ..writeln();
  }

  b
    ..writeln('## HALLAZGOS')
    ..writeln();
  final all = [
    for (final s in stages)
      for (final f in s.findings) (s, f),
  ]..sort((a, b) => a.$2.severity.index.compareTo(b.$2.severity.index));
  if (all.isEmpty) b.writeln('Sin hallazgos.');
  for (final (stage, finding) in all) {
    b.writeln(
      '- ${finding.severity.symbol} **${finding.severity.label} ${finding.code}** (${stage.title}) ${finding.message}'
      '${finding.location == null ? '' : ' — `${finding.location}`'}',
    );
    if (finding.examples.isNotEmpty) {
      final more =
          (finding.count ?? finding.examples.length) - finding.examples.length;
      b.writeln(
        '  - ${finding.examples.map((e) => '`$e`').join(', ')}${more > 0 ? ' … y $more más' : ''}',
      );
    }
  }
  b
    ..writeln()
    ..writeln('## TIEMPOS')
    ..writeln()
    ..writeln('| Etapa | Duración | Ejecutada |')
    ..writeln('|---|---:|---|');
  for (final s in stages) {
    b.writeln(
      '| ${s.title} | ${formatDuration(s.durationMs)} | ${s.startedAt.toIso8601String().substring(0, 19).replaceFirst('T', ' ')} |',
    );
  }
  b.writeln('| **Suma de etapas** | **${formatDuration(stageSum)}** | |');
  if (totalMs != null) {
    b.writeln('| **Total del comando** | **${formatDuration(totalMs)}** | |');
  }
  return b.toString();
}

String _fieldState(List<Finding> findings, String target, bool thresholded) {
  final related = findings
      .where(
        (f) =>
            f.message.startsWith('$target ') ||
            f.message.startsWith('$target:'),
      )
      .toList();
  if (related.any((f) => f.severity == Severity.error)) return '✗';
  if (related.any((f) => f.severity == Severity.warning)) return '⚠';
  return thresholded ? '✓' : '✓ (sin umbral)';
}

String _pct(num? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1).replaceAll('.', ',')} %';

String _mib(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} MiB';

String _int(int value) =>
    value.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => '.');
