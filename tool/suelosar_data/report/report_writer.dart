import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cli/pipeline.dart';
import '../cli/version.dart';
import '../config/province_definition.dart';
import '../validation/finding.dart';

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

/// Every pending manual step recorded by the stages.
List<String> collectManualSteps(List<StageResult> stages) => [
  for (final s in stages)
    for (final step in s.data['manualSteps'] as List? ?? const [])
      step as String,
];

String _stageState(StageResult s) {
  if (s.hasErrors) return '✗ con errores';
  if (s.skipped) return '– omitida';
  if (s.reused) return '↺ reutilizada';
  if (s.findings.any((f) => f.severity == Severity.warning)) {
    return '⚠ ejecutada';
  }
  return '✓ ejecutada';
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
  final steps = collectManualSteps(stages);

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
            'state': _stageState(s),
            'reused': s.reused,
            'skipped': s.skipped,
            if (s.reused) 'originalDurationMs': s.data['originalDurationMs'],
            'startedAt': s.startedAt.toIso8601String(),
          },
      ],
      'stagesTotalMs': stageSum,
      'commandTotalMs': totalMs,
    },
    'manualSteps': steps,
    'stages': {for (final s in stages) s.name: s.data},
    'findings': [
      for (final s in stages)
        for (final f in s.findings) {'stage': s.name, ...f.toJson()},
    ],
  };

  final md = _markdown(
    definition,
    stages,
    summary,
    now,
    stageSum,
    totalMs,
    steps,
  );
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
  List<String> steps,
) {
  final b = StringBuffer()
    ..writeln('# SuelosAR Data Pipeline — ${d.name} (`${d.id}`)')
    ..writeln()
    ..writeln('- Fecha: ${_time(now)}')
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

  b
    ..writeln('## ETAPAS')
    ..writeln()
    ..writeln('| Etapa | Estado | Tiempo |')
    ..writeln('|---|---|---:|');
  for (final s in stages) {
    b.writeln('| ${s.title} | ${_stageState(s)} | ${_stageTime(s)} |');
  }
  b.writeln();

  final byName = {for (final s in stages) s.name: s};
  _sources(b, byName['sources']?.data);
  _normalize(b, byName['normalize']);
  _catalog(b, byName['catalog']?.data);
  _crossref(b, byName['crossref']?.data);
  _prepare(b, byName['prepare']);
  _map(b, byName['map']);
  _optimize(b, byName['optimize']);
  _metadata(b, byName['metadata']);

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
    ..writeln('## PASOS MANUALES PENDIENTES')
    ..writeln();
  if (steps.isEmpty) {
    b.writeln('Ninguno registrado.');
  } else {
    for (final step in steps) {
      b.writeln('- [ ] $step');
    }
  }
  b
    ..writeln()
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
    ..writeln('| Etapa | Duración | Estado | Ejecutada |')
    ..writeln('|---|---:|---|---|');
  for (final s in stages) {
    b.writeln(
      '| ${s.title} | ${formatDuration(s.durationMs)} | ${_stageState(s)}'
      '${s.reused ? ' (originalmente ${formatDuration(s.data['originalDurationMs']! as int)})' : ''} | ${_time(s.startedAt)} |',
    );
  }
  b.writeln('| **Suma de etapas** | **${formatDuration(stageSum)}** | | |');
  if (totalMs != null) {
    b.writeln('| **Total del comando** | **${formatDuration(totalMs)}** | | |');
  }
  return b.toString();
}

void _sources(StringBuffer b, Map<String, Object?>? sources) {
  if (sources == null) return;
  b.writeln('## FUENTE GIS Y DATOS');
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
    b.writeln('- PMTiles a generar: `${pmtiles['output']}`');
    if (pmtiles['reference'] != null) {
      b.writeln(
        '- ${pmtiles['referenceExists'] == true ? '✓' : 'ℹ'} PMTiles actual de la app `${pmtiles['reference']}`',
      );
    }
    if (pmtiles['docker'] != null) {
      b.writeln(
        '- ${pmtiles['docker'] == true || sources['docker'] == true ? '✓' : '⚠'} Docker',
      );
    }
  }
  if (sources['docker'] != null) {
    b.writeln(
      '- ${sources['docker'] == true ? '✓ Docker disponible' : '⚠ Docker no disponible'}',
    );
  }
  b.writeln();
}

void _normalize(StringBuffer b, StageResult? stage) {
  final gis = stage?.data;
  if (stage == null || gis == null || gis['features'] == null) return;
  b
    ..writeln(
      '## NORMALIZACIÓN — ${_int(gis['features'] as int)} features${stage.reused ? ' (reutilizada)' : ''}',
    )
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
            stage.findings,
            target as String,
            row['thresholded'] == true,
          );
    b.writeln('| $target | $source | $coverage | $empty | $state |');
  }
  b.writeln();
}

void _catalog(StringBuffer b, Map<String, Object?>? catalog) {
  if (catalog == null || catalog['model'] == null) return;
  b.writeln(
    '## CATÁLOGO (${catalog['model']})${catalog['reused'] == true ? ' (reutilizado)' : ''}',
  );
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

void _crossref(StringBuffer b, Map<String, Object?>? xref) {
  if (xref == null || xref['gisSeries'] == null) return;
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

void _prepare(StringBuffer b, StageResult? stage) {
  final data = stage?.data;
  if (stage == null || data == null || data['route'] == null) return;
  b
    ..writeln('## PREPARACIÓN GIS')
    ..writeln(
      '- ${stage.hasErrors
          ? '✗'
          : stage.skipped
          ? '–'
          : '✓'} Entrada de Docker: '
      '${data['route'] == 'source' ? 'fuente original' : 'GIS normalizado'} `${data['file'] ?? '—'}`',
    );
  if (data['reason'] != null) b.writeln('- Motivo: ${data['reason']}');
  final optional = data['optionalAttributes'] as List?;
  if (optional != null && optional.isNotEmpty) {
    b.writeln(
      '- OPTIONAL_ATTRIBUTES (campos `absent`): ${optional.join(', ')}',
    );
  }
  final emptied = data['emptiedValues'] as Map?;
  if (emptied != null) {
    final total = emptied.values.fold<int>(0, (a, v) => a + (v as int));
    b.writeln(
      '- Textos vacíos convertidos en nulos: ${_int(total)}'
      '${emptied.isEmpty ? '' : ' (${emptied.entries.map((e) => '${e.key}: ${e.value}').join(', ')})'}',
    );
  }
  if (data['outputBytes'] != null) {
    b.writeln(
      '- Tamaño de `map_input.geojson`: ${_mib(data['outputBytes'] as int)}',
    );
  }
  b.writeln();
}

void _map(StringBuffer b, StageResult? stage) {
  final data = stage?.data;
  if (stage == null || data == null) return;
  b.writeln('## PMTILES (DOCKER)');
  if (stage.skipped) {
    b
      ..writeln('- – Omitido')
      ..writeln();
    return;
  }
  b.writeln(
    '- ${stage.hasErrors ? '✗ falló' : '✓ generado'}${stage.reused ? ' (reutilizado)' : ''}'
    '${data['output'] == null ? '' : ': `${data['output']}`'}'
    '${data['sizeBytes'] == null ? '' : ' — ${_mib(data['sizeBytes'] as int)} (${_int(data['sizeBytes'] as int)} bytes)'}',
  );
  if (data['sha256'] != null) b.writeln('- SHA-256 `${data['sha256']}`');
  if (data['dockerMs'] != null) {
    b.writeln(
      '- Docker: ${formatDuration(data['dockerMs'] as int)}'
      '${data['imageRebuilt'] == true ? ' (imagen reconstruida)' : ''} · log `${data['log']}`',
    );
  }
  b.writeln();
}

void _optimize(StringBuffer b, StageResult? stage) {
  final data = stage?.data;
  if (stage == null || data == null) return;
  b.writeln('## OPTIMIZACIÓN');
  if (stage.skipped || data['sizeBefore'] == null) {
    b
      ..writeln(stage.hasErrors ? '- ✗ falló' : '- – Omitida')
      ..writeln();
    return;
  }
  final before = data['sizeBefore']! as int;
  final after = data['sizeAfter']! as int;
  final removed = (data['attributesRemoved'] as List).cast<String>();
  b
    ..writeln(
      '- ${data['rewritten'] == true ? '✓ ${_mib(before)} → ${_mib(after)} (${_pct(data['savedPercent'] as num)} menos)' : '✓ sin atributos que quitar: copiado sin reescribir (${_mib(after)})'}'
      '${stage.reused ? ' (reutilizada)' : ''}',
    )
    ..writeln(
      '- Campos eliminados: ${removed.isEmpty ? 'ninguno' : removed.join(', ')}',
    )
    ..writeln(
      '- Campos conservados: ${(data['attributesKept'] as List).join(', ')}',
    )
    ..writeln(
      '- Tiles revisados: ${_int(data['uniqueTiles'] as int)} · SHA-256 `${data['sha256After']}`',
    )
    ..writeln();
}

void _metadata(StringBuffer b, StageResult? stage) {
  final data = stage?.data;
  if (stage == null || data == null) return;
  final metadata = data['metadata'] as Map?;
  final published = data['published'];
  b.writeln(
    published == null
        ? '## PMTILES (INSPECCIÓN)'
        : '## METADATOS Y PUBLICACIÓN',
  );
  if (published == false) {
    b
      ..writeln('- ✗ No publicado: ${data['notPublishedBecause']}')
      ..writeln();
    return;
  }
  if (metadata == null) {
    b
      ..writeln(
        stage.skipped ? '- – Omitido' : '- Sin PMTiles para inspeccionar',
      )
      ..writeln();
    return;
  }
  final bounds = metadata['bounds'] as Map;
  final center = metadata['center'] as Map;
  final app = data['app'] as Map?;
  final reference = data['reference'] as Map?;
  final absent =
      (metadata['absentAttributes'] as List?)?.cast<String>() ?? const [];
  if (published == true) {
    b
      ..writeln('- ✓ Publicado: `${metadata['path']}` (+ `.sha256`)')
      ..writeln('- ✓ Metadatos: `${data['metadataFile']}`');
  } else {
    b.writeln(
      '- Archivo inspeccionado (${metadata['role']}): `${metadata['path']}`',
    );
  }
  b
    ..writeln(
      '- ${_int(metadata['sizeBytes'] as int)} bytes (${metadata['sizeMiB']} MiB) · SHA-256 `${metadata['sha256']}`'
      ' · sidecar ${metadata['sha256SidecarMatches'] == true
          ? '✓'
          : metadata['sha256SidecarMatches'] == false
          ? '✗'
          : '⚠ no existe'}',
    )
    ..writeln(
      '- Zoom ${metadata['minZoom']}–${metadata['maxZoom']} · capa `${metadata['layer']}` · '
      'centro ${center['latitude']}, ${center['longitude']} (z${center['zoom']})',
    )
    ..writeln(
      '- Bounds lat ${bounds['minLatitude']} … ${bounds['maxLatitude']}, lon ${bounds['minLongitude']} … ${bounds['maxLongitude']}',
    )
    ..writeln(
      '- ${stage.findings.any((f) => f.code == 'OPT001') ? '✗' : '✓'} Atributos (${metadata['attributesSource']}): '
      '${(metadata['attributes'] as List).join(', ')}'
      '${absent.isEmpty ? '' : ' — ausentes declarados: ${absent.join(', ')}'}',
    );
  if (reference != null && reference['exists'] == true) {
    b.writeln(
      '- Comparado con `${reference['path']}`: '
      '${reference['identical'] == true ? '✓ idéntico byte a byte' : '⚠ distinto (${_int(reference['sizeBytes'] as int)} bytes)'}',
    );
  }
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
  b.writeln();
}

String _stageTime(StageResult s) => s.reused
    ? '${formatDuration(s.durationMs)} (antes ${formatDuration(s.data['originalDurationMs']! as int)})'
    : formatDuration(s.durationMs);

String _time(DateTime time) =>
    time.toIso8601String().substring(0, 19).replaceFirst('T', ' ');

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
