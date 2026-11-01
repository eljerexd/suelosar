import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../config/paths.dart';
import '../config/province_definition.dart';
import '../normalize/field_mapping.dart';
import '../normalize/normalizer.dart';
import '../pmtiles/app_declarations.dart';
import '../pmtiles/optimizer.dart';
import '../pmtiles/pmtiles_checks.dart';
import '../pmtiles/pmtiles_metadata.dart';
import '../report/report_writer.dart';
import '../schema/suelosar_schema.dart';
import '../sources/gis_source.dart';
import '../validation/finding.dart';
import 'init_template.dart';
import 'pipeline.dart';

/// Exit codes.
const exitOk = 0;
const exitFindings = 1;
const exitUsage = 2;

/// Entry point: runs [arguments] and returns the process exit code.
Future<int> runSuelosArData(
  List<String> arguments, {
  Directory? workingDirectory,
}) async {
  final runner =
      CommandRunner<int>(
          'dart run tool/suelosar_data.dart',
          'SuelosAR Data Pipeline: valida y prepara los datos de una provincia '
              'y genera su PMTiles (sin tocar la app).',
        )
        ..argParser.addOption(
          'provinces-dir',
          help: 'Carpeta de provincias (por defecto: data/provinces del repo).',
        )
        ..argParser.addOption(
          'pdftotext',
          help: 'Ejecutable pdftotext (también: variable PDFTOTEXT).',
        )
        ..argParser.addFlag(
          'verbose',
          abbr: 'v',
          negatable: false,
          help: 'Mostrar también los hallazgos INFO.',
        );
  for (final command in [
    _InitCommand(workingDirectory),
    _InspectCommand(workingDirectory),
    _ValidateCommand(workingDirectory),
    _NormalizeCommand(workingDirectory),
    _CatalogCommand(workingDirectory),
    _MetadataCommand(workingDirectory),
    _GeometryCommand(workingDirectory),
    _ReportCommand(workingDirectory),
    _BuildCommand(workingDirectory),
    _StageCommand(
      workingDirectory,
      name: 'prepare-gis',
      stage: 'prepare',
      description:
          'Decide y prepara la entrada del pipeline Docker (fuente original o work/map_input).',
    ),
    _StageCommand(
      workingDirectory,
      name: 'map',
      stage: 'map',
      description:
          'Genera el PMTiles completo con Docker en work/pmtiles (--dry-run muestra el comando).',
      dryRun: true,
    ),
    _OptimizeCommand(workingDirectory),
  ]) {
    runner.addCommand(command);
  }
  try {
    final code = await runner.run(arguments);
    return code ?? exitOk;
  } on UsageException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln()
      ..writeln(e.usage);
    return exitUsage;
  } on ConfigException catch (e) {
    stderr.writeln('ERROR: ${e.message}');
    return exitUsage;
  }
}

abstract class _Command extends Command<int> {
  _Command(this._workingDirectory);

  final Directory? _workingDirectory;

  String get repoRoot => findRepoRoot(_workingDirectory).path;

  String get provincesDir {
    final option = globalResults?['provinces-dir'] as String?;
    if (option == null) return p.join(repoRoot, 'data', 'provinces');
    return p.isAbsolute(option)
        ? option
        : p.join((_workingDirectory ?? Directory.current).path, option);
  }

  bool get verbose => globalResults?['verbose'] == true;

  String get provinceId {
    final rest = argResults!.rest;
    if (rest.length != 1) {
      usageException('Indicá exactamente una provincia (id de carpeta).');
    }
    final id = rest.single;
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(id)) {
      usageException('El id "$id" debe ser snake_case (a-z, 0-9, _).');
    }
    return id;
  }

  ProvinceDefinition loadProvince() => ProvinceDefinition.load(
    id: provinceId,
    provincesDir: provincesDir,
    repoRoot: repoRoot,
  );

  ProvincePipeline pipelineFor(
    ProvinceDefinition definition, {
    RunOptions options = const RunOptions(),
  }) => ProvincePipeline(
    definition,
    pdftotext: globalResults?['pdftotext'] as String?,
    options: options,
    log: stdout.writeln,
  );

  void printFindings(Iterable<Finding> findings) {
    final visible =
        findings.where((f) => verbose || f.severity != Severity.info).toList()
          ..sort((a, b) => a.severity.index.compareTo(b.severity.index));
    final hidden = findings.length - visible.length;
    if (visible.isNotEmpty) stdout.writeln();
    for (final finding in visible) {
      stdout.writeln(
        '${finding.severity.symbol} ${finding.severity.label} ${finding.code}: ${finding.message}'
        '${finding.location == null ? '' : '  [${finding.location}]'}',
      );
      if (finding.examples.isNotEmpty) {
        final shown = finding.examples.take(5).toList();
        final more = (finding.count ?? finding.examples.length) - shown.length;
        stdout.writeln(
          '    ${shown.join(' · ')}${more > 0 ? ' … (+$more)' : ''}',
        );
      }
    }
    if (hidden > 0) {
      stdout.writeln('  ($hidden hallazgos INFO; usar --verbose para verlos)');
    }
  }

  int exitCodeFor(Iterable<Finding> findings, {bool strict = false}) {
    final summary = summarize(findings, strict: strict);
    return summary.status == ReportStatus.notReady ? exitFindings : exitOk;
  }

  int finishWithReport(
    ProvinceDefinition definition,
    ProvincePipeline pipeline,
    Stopwatch watch, {
    bool strict = false,
  }) {
    final findings = [for (final s in pipeline.results) ...s.findings];
    printFindings(findings);
    final report = writeReport(
      definition,
      totalMs: watch.elapsedMilliseconds,
      strict: strict,
    );
    final summary = report.summary;
    stdout
      ..writeln()
      ..writeln(
        'RESULTADO: ${summary.status.label}  (${summary.errors} errores · '
        '${summary.warnings} warnings · ${summary.infos} info)',
      )
      ..writeln('Tiempo total: ${formatDuration(watch.elapsedMilliseconds)}')
      ..writeln('Reporte: ${definition.display(report.markdown)}')
      ..writeln('         ${definition.display(report.json)}');
    return exitCodeFor(findings, strict: strict);
  }
}

class _InitCommand extends _Command {
  _InitCommand(super.workingDirectory);

  @override
  String get name => 'init';

  @override
  String get description =>
      'Crea data/provinces/<id>/ con su province.yaml plantilla.';

  @override
  String get invocation => '${runner!.executableName} init <id>';

  @override
  Future<int> run() async {
    final id = provinceId;
    final dir = Directory(
      ProvinceDefinition.provinceDirectory(provincesDir, id),
    );
    final config = File(p.join(dir.path, 'province.yaml'));
    if (config.existsSync()) {
      throw ConfigException(
        'Ya existe ${displayPath(config.path, repoRoot)}; no se sobrescribe.',
      );
    }
    for (final sub in ['source/gis', 'source/pdf', 'work', 'output']) {
      Directory(p.join(dir.path, sub)).createSync(recursive: true);
    }
    config.writeAsStringSync(provinceTemplate(id));
    stdout
      ..writeln('Creado ${displayPath(dir.path, repoRoot)}/')
      ..writeln(
        '  1. Copiá la capa GIS a source/gis/ y los PDFs a source/pdf/.',
      )
      ..writeln('  2. Completá province.yaml (ver columnas con: inspect $id).')
      ..writeln('  3. Ejecutá: build $id');
    return exitOk;
  }
}

class _InspectCommand extends _Command {
  _InspectCommand(super.workingDirectory);

  @override
  String get name => 'inspect';

  @override
  String get description =>
      'Lista las columnas de la fuente GIS (tipo, cobertura, ejemplos) para escribir el mapping.';

  @override
  String get invocation => '${runner!.executableName} inspect <id>';

  @override
  Future<int> run() async {
    final id = provinceId;
    final dir = ProvinceDefinition.provinceDirectory(provincesDir, id);
    final file = File(p.join(dir, 'province.yaml'));
    if (!file.existsSync()) {
      throw ConfigException('No existe ${displayPath(file.path, repoRoot)}.');
    }
    // Only gis.source/format/encoding are needed: the mapping is what this
    // command helps to write, so it may still be incomplete.
    final yaml = loadYaml(file.readAsStringSync());
    final gisNode = yaml is Map ? yaml['gis'] : null;
    if (gisNode is! Map ||
        gisNode['source'] is! String ||
        gisNode['format'] is! String) {
      throw ConfigException(
        'inspect necesita gis.source y gis.format en province.yaml.',
      );
    }
    final format = GisFormat.values
        .where((f) => f.key == gisNode['format'])
        .firstOrNull;
    if (format == null) {
      throw ConfigException('gis.format "${gisNode['format']}" no es válido.');
    }
    final source = resolveConfigPath(
      gisNode['source'] as String,
      baseDir: p.absolute(dir),
      repoRoot: repoRoot,
    );
    if (!File(source).existsSync()) {
      throw ConfigException('No existe la fuente GIS: $source');
    }
    final config = GisConfig(
      source: source,
      format: format,
      encoding: gisNode['encoding'] as String?,
      layerName: 'soil_polygons',
      mapping: const FieldMapping([]),
      series: const SeriesConfig(
        codeRule: SeriesCodeRule.wholeValue,
        match: SeriesMatch.normalizedName,
        aliases: {},
      ),
      thresholds: ThresholdConfig(
        warnBelow: 90,
        errorBelow: 50,
        fields: SuelosArSchema.defaultThresholdFields,
      ),
    );
    final watch = Stopwatch()..start();
    final gis = GisSource.open(config);
    final types = gis.declaredColumnTypes() ?? {};
    final profiles = <String, ColumnProfile>{};
    var features = 0;
    await for (final record in gis.records()) {
      features++;
      record.properties.forEach(
        (k, v) => profiles.putIfAbsent(k, () => ColumnProfile(k)).add(v),
      );
    }
    for (final column in types.keys) {
      profiles.putIfAbsent(column, () => ColumnProfile(column));
    }
    for (final profile in profiles.values) {
      profile.empty += features - profile.total;
    }
    stdout
      ..writeln(
        '${displayPath(source, repoRoot)} — $features features — ${gis.encodingName} — '
        '${formatDuration(watch.elapsedMilliseconds)}',
      )
      ..writeln()
      ..writeln(
        '${'Columna'.padRight(18)}${'Tipo'.padRight(18)}${'Cobertura'.padLeft(10)}${'Distintos'.padLeft(11)}  Ejemplos',
      );
    final columns = types.isNotEmpty
        ? types.keys.toList()
        : (profiles.keys.toList()..sort());
    for (final column in columns) {
      final profile = profiles[column]!;
      final type = types[column] ?? profile.types.join('/');
      final examples = profile
          .topValues(3)
          .map((e) => _short(e.key))
          .join(' | ');
      stdout.writeln(
        '${column.padRight(18)}${type.padRight(18)}'
        '${'${profile.coverage.toStringAsFixed(1)} %'.padLeft(10)}'
        '${'${profile.distinct}${profile.distinctOverflow ? '+' : ''}'.padLeft(11)}  $examples',
      );
    }
    if (gis.encodingIssues.isNotEmpty) {
      stdout.writeln(
        '\n✗ ${gis.encodingIssues.length} valores con problemas de codificación.',
      );
    }
    stdout
      ..writeln()
      ..writeln(
        'Campos destino SuelosAR: ${SuelosArSchema.requiredFields.join(', ')} (+ ${SuelosArSchema.optionalFields.join(', ')} opcional)',
      );
    return exitOk;
  }

  static String _short(String value) {
    final oneLine = value.replaceAll(RegExp(r'\s+'), ' ');
    return oneLine.length > 32 ? '${oneLine.substring(0, 31)}…' : oneLine;
  }
}

abstract class _StrictCommand extends _Command {
  _StrictCommand(super.workingDirectory) {
    argParser.addFlag(
      'strict',
      negatable: false,
      help: 'Los WARNING también hacen fallar el comando.',
    );
  }

  bool get strict => argResults?['strict'] == true;
}

class _ValidateCommand extends _StrictCommand {
  _ValidateCommand(super.workingDirectory);

  @override
  String get name => 'validate';

  @override
  String get description =>
      'Ejecuta todas las validaciones sin generar artefactos (solo el reporte).';

  @override
  String get invocation => '${runner!.executableName} validate <id>';

  @override
  Future<int> run() async {
    final definition = loadProvince();
    final watch = Stopwatch()..start();
    final pipeline = pipelineFor(definition);
    stdout.writeln('validate ${definition.id}\n');
    await pipeline.runValidate();
    return finishWithReport(definition, pipeline, watch, strict: strict);
  }
}

class _BuildCommand extends _StrictCommand {
  _BuildCommand(super.workingDirectory) {
    argParser
      ..addFlag(
        'force',
        negatable: false,
        help: 'Rehace todas las etapas, sin reutilizar.',
      )
      ..addOption(
        'from',
        allowed: buildStageNames,
        help:
            'Rehace desde esta etapa (las anteriores se reutilizan si siguen válidas).',
      )
      ..addOption(
        'until',
        allowed: buildStageNames,
        help: 'Se detiene después de esta etapa.',
      );
  }

  @override
  String get name => 'build';

  @override
  String get description =>
      'Todo el flujo: fuentes, catálogo, normalización, preparación GIS, PMTiles, '
      'optimización, metadatos (publicación en output/), cruce y reporte.';

  @override
  String get invocation =>
      '${runner!.executableName} build <id> [--force] [--from <etapa>] [--until <etapa>]';

  @override
  Future<int> run() async {
    final definition = loadProvince();
    final from = argResults!['from'] as String?;
    final until = argResults!['until'] as String?;
    if (from != null &&
        until != null &&
        buildStageNames.indexOf(from) > buildStageNames.indexOf(until)) {
      usageException('--from $from es posterior a --until $until.');
    }
    final watch = Stopwatch()..start();
    final pipeline = pipelineFor(
      definition,
      options: RunOptions(
        force: argResults!['force'] == true,
        from: from,
        until: until,
      ),
    );
    stdout.writeln('build ${definition.id}\n');
    await pipeline.runBuild();
    return finishWithReport(definition, pipeline, watch, strict: strict);
  }
}

/// Runs the build up to one stage, re-running that stage and reusing the
/// earlier ones when their stamps are still valid.
class _StageCommand extends _StrictCommand {
  _StageCommand(
    super.workingDirectory, {
    required this.name,
    required this.stage,
    required this.description,
    bool dryRun = false,
  }) {
    if (dryRun) {
      argParser.addFlag(
        'dry-run',
        negatable: false,
        help: 'Muestra el comando docker sin ejecutarlo.',
      );
    }
  }

  @override
  final String name;

  @override
  final String description;

  final String stage;

  @override
  String get invocation => '${runner!.executableName} $name <id>';

  @override
  Future<int> run() async {
    final definition = loadProvince();
    final watch = Stopwatch()..start();
    final pipeline = pipelineFor(
      definition,
      options: RunOptions(
        from: stage,
        until: stage,
        dryRun:
            argParser.options.containsKey('dry-run') &&
            argResults!['dry-run'] == true,
      ),
    );
    stdout.writeln('$name ${definition.id}\n');
    await pipeline.runBuild();
    return finishWithReport(definition, pipeline, watch, strict: strict);
  }
}

class _OptimizeCommand extends _StrictCommand {
  _OptimizeCommand(super.workingDirectory) {
    argParser
      ..addOption(
        'input',
        help: 'PMTiles de entrada (uso suelto, sin provincia).',
      )
      ..addOption('output', help: 'PMTiles de salida (uso suelto).')
      ..addOption(
        'mode',
        allowed: [for (final m in OptimizeMode.values) m.key],
        defaultsTo: 'auto',
        help: 'auto: reescribe solo si hay atributos fuera del esquema.',
      );
  }

  @override
  String get name => 'optimize';

  @override
  String get description =>
      'Quita los atributos que no están en el esquema SuelosAR y escribe el .sha256 '
      '(provincia: work/pmtiles; suelto: --input/--output).';

  @override
  String get invocation =>
      '${runner!.executableName} optimize <id> | optimize --input A.pmtiles --output B.pmtiles';

  @override
  Future<int> run() async {
    final watch = Stopwatch()..start();
    final input = argResults!['input'] as String?;
    final output = argResults!['output'] as String?;
    if (input == null && output == null) {
      final definition = loadProvince();
      final pipeline = pipelineFor(
        definition,
        options: const RunOptions(from: 'optimize', until: 'optimize'),
      );
      stdout.writeln('optimize ${definition.id}\n');
      await pipeline.runBuild();
      return finishWithReport(definition, pipeline, watch, strict: strict);
    }
    if (input == null || output == null || argResults!.rest.isNotEmpty) {
      usageException('Uso suelto: --input y --output juntos, sin provincia.');
    }
    final base = (_workingDirectory ?? Directory.current).path;
    File resolve(String path) =>
        File(p.isAbsolute(path) ? path : p.join(base, path));
    final inputFile = resolve(input);
    if (!inputFile.existsSync()) {
      throw ConfigException('No existe ${inputFile.path}.');
    }
    final mode = OptimizeMode.values.firstWhere(
      (m) => m.key == argResults!['mode'],
    );
    try {
      final report = await PmtilesOptimizer(
        log: (m) => stdout.writeln('  $m'),
      ).run(inputFile, resolve(output), mode: mode);
      final missing = [
        for (final field in SuelosArSchema.requiredFields)
          if (!report.attributesKept.contains(field)) field,
      ];
      stdout
        ..writeln()
        ..writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
      if (missing.isNotEmpty) {
        // Without a province.yaml there is no way to know which fields are
        // legitimately absent: report, do not fail.
        stdout.writeln(
          'ℹ Campos del esquema ausentes en todo el archivo: ${missing.join(', ')}.',
        );
      }
      stdout.writeln(
        'Tiempo total: ${formatDuration(watch.elapsedMilliseconds)}',
      );
      return exitOk;
    } on PmtilesStructureException catch (e) {
      stderr.writeln('✗ ERROR OPT002: ${e.message}');
      return exitFindings;
    }
  }
}

class _NormalizeCommand extends _Command {
  _NormalizeCommand(super.workingDirectory);

  @override
  String get name => 'normalize';

  @override
  String get description =>
      'Aplica gis.mapping y escribe work/normalized.geojson con la cobertura por campo.';

  @override
  String get invocation => '${runner!.executableName} normalize <id>';

  @override
  Future<int> run() async {
    final definition = loadProvince();
    final watch = Stopwatch()..start();
    final pipeline = pipelineFor(definition);
    stdout.writeln('normalize ${definition.id}\n');
    // Derivations need series names: build the catalog in memory only.
    if (definition.gis.mapping.usesDerivations && definition.pdf != null) {
      await pipeline.catalog(write: false, diff: false, persist: false);
    }
    final result = await pipeline.normalize(write: true);
    if (result != null) {
      stdout
        ..writeln()
        ..writeln(
          '${'Campo destino'.padRight(14)}${'Origen'.padRight(26)}${'Cobertura'.padLeft(10)}${'Vacíos'.padLeft(10)}',
        );
      for (final rule in definition.gis.mapping.rules) {
        final profile = result.targetProfiles[rule.target]!;
        final origin = switch (rule) {
          CopyRule() => rule.source,
          AbsentRule() => '(ausente)',
          DeriveRule() => '(${rule.derivation.key})',
        };
        final isAbsent = rule is AbsentRule;
        stdout.writeln(
          '${rule.target.padRight(14)}${origin.padRight(26)}'
          '${(isAbsent ? '—' : '${profile.coverage.toStringAsFixed(1)} %').padLeft(10)}'
          '${(isAbsent ? '—' : '${(100 - profile.coverage).toStringAsFixed(1)} %').padLeft(10)}',
        );
      }
      stdout.writeln(
        '\nSalida: ${definition.display(definition.normalizedGisFile)}',
      );
    }
    final findings = [for (final s in pipeline.results) ...s.findings];
    printFindings(findings);
    stdout.writeln(
      'Tiempo total: ${formatDuration(watch.elapsedMilliseconds)}',
    );
    return exitCodeFor(findings);
  }
}

class _CatalogCommand extends _Command {
  _CatalogCommand(super.workingDirectory) {
    argParser.addFlag(
      'diff',
      negatable: false,
      help: 'Comparar con catalog.reference (el catálogo actual de la app).',
    );
  }

  @override
  String get name => 'catalog';

  @override
  String get description =>
      'Genera el catálogo de cartas (PDF por serie o PDF único) en output/.';

  @override
  String get invocation => '${runner!.executableName} catalog <id> [--diff]';

  @override
  Future<int> run() async {
    final definition = loadProvince();
    final watch = Stopwatch()..start();
    final pipeline = pipelineFor(definition);
    stdout.writeln('catalog ${definition.id}\n');
    await pipeline.catalog(write: true, diff: argResults!['diff'] == true);
    final stage = pipeline.results.single;
    final output = stage.data['output'];
    if (output != null) stdout.writeln('\nGenerado: $output');
    final diff = stage.data['diff'] as Map?;
    if (diff != null) {
      stdout
        ..writeln('\nComparación con ${diff['reference']}:')
        ..writeln(
          '  idéntico byte a byte (sin contar fin de línea): ${diff['textEqual'] ? 'sí' : 'no'}',
        )
        ..writeln(
          '  mismo documento JSON:                          ${diff['contentEqual'] ? 'sí' : 'no'}',
        )
        ..writeln(
          '  registros nuevos: ${(diff['added'] as List).length} · quitados: ${(diff['removed'] as List).length}'
          ' · campos cambiados: ${(diff['changed'] as List).length} · orden distinto: ${diff['orderDiffers'] ? 'sí' : 'no'}',
        );
      for (final line in [
        ...(diff['added'] as List).map((k) => '    + $k'),
        ...(diff['removed'] as List).map((k) => '    - $k'),
        ...(diff['changed'] as List).map((c) => '    ~ $c'),
      ]) {
        stdout.writeln(line);
      }
    }
    // Validation findings about the catalog (duplicates, naming) are shown
    // in full here: they are the inconsistencies the diff alone would not
    // explain.
    final findings = stage.findings;
    printFindingsAll(findings, includeInfo: verbose);
    stdout.writeln(
      'Tiempo total: ${formatDuration(watch.elapsedMilliseconds)}',
    );
    return exitCodeFor(findings);
  }

  void printFindingsAll(List<Finding> findings, {required bool includeInfo}) {
    final visible =
        findings
            .where((f) => includeInfo || f.severity != Severity.info)
            .toList()
          ..sort((a, b) => a.severity.index.compareTo(b.severity.index));
    if (visible.isNotEmpty) stdout.writeln();
    for (final f in visible) {
      stdout.writeln(
        '${f.severity.symbol} ${f.severity.label} ${f.code}: ${f.message}',
      );
      if (f.examples.isNotEmpty) {
        final more = (f.count ?? f.examples.length) - f.examples.length;
        stdout.writeln(
          '    ${f.examples.join(' · ')}${more > 0 ? ' … (+$more)' : ''}',
        );
      }
    }
    final hidden = findings.length - visible.length;
    if (hidden > 0) {
      stdout.writeln('  ($hidden hallazgos INFO; usar --verbose para verlos)');
    }
  }
}

class _MetadataCommand extends _StrictCommand {
  _MetadataCommand(super.workingDirectory) {
    argParser
      ..addOption(
        'province',
        help:
            'Inspeccionar el PMTiles publicado de esta provincia (o, si no hay, '
            'pmtiles.reference) y guardar output/pmtiles_metadata.json.',
      )
      ..addOption('out', help: 'Guardar el JSON en este archivo.')
      ..addOption(
        'layer',
        defaultsTo: 'soil_polygons',
        help: 'Capa vectorial a muestrear.',
      );
  }

  @override
  String get name => 'metadata';

  @override
  String get description =>
      'Tamaño, SHA-256, zooms, bounds y centro de un PMTiles, comparados con lo escrito en la app.';

  @override
  String get invocation =>
      '${runner!.executableName} metadata <archivo.pmtiles> | --province <id>';

  @override
  Future<int> run() async {
    final watch = Stopwatch()..start();
    final province = argResults!['province'] as String?;
    if (province != null) {
      if (argResults!.rest.isNotEmpty) {
        usageException('Usar un archivo o --province, no ambos.');
      }
      final definition = ProvinceDefinition.load(
        id: province,
        provincesDir: provincesDir,
        repoRoot: repoRoot,
      );
      final pipeline = pipelineFor(definition);
      final metadata = await pipeline.inspectMetadata(write: true);
      if (metadata != null) {
        stdout.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(pipeline.results.single.data['metadata']),
        );
      }
      final findings = pipeline.results.single.findings;
      printFindings(findings);
      stdout.writeln(
        'Tiempo total: ${formatDuration(watch.elapsedMilliseconds)}',
      );
      return exitCodeFor(findings, strict: strict);
    }

    if (argResults!.rest.length != 1) {
      usageException('Indicá un archivo .pmtiles o --province <id>.');
    }
    final base = (_workingDirectory ?? Directory.current).path;
    final raw = argResults!.rest.single;
    final file = File(p.isAbsolute(raw) ? raw : p.join(base, raw));
    if (!file.existsSync()) throw ConfigException('No existe ${file.path}.');
    final root = repoRoot;
    final layer = argResults!['layer'] as String;
    final metadata = await PmtilesMetadata.read(file, layer: layer);
    final sink = FindingSink();
    final assetPath = displayPath(p.normalize(file.absolute.path), root);
    final comparison = checkPmtiles(
      metadata: metadata,
      assetPath: assetPath,
      app: AppDeclarations.read(root),
      // Without a province.yaml there is no way to know which fields are
      // legitimately absent, so missing ones are only reported below.
      expectedAttributes: const [],
      layer: layer,
      findings: sink,
    );
    final unseen = [
      for (final f in SuelosArSchema.requiredFields)
        if (!metadata.attributesSeen.contains(f)) f,
    ];
    if (unseen.isNotEmpty) {
      sink.info(
        'PMT003',
        'Campos del esquema no vistos en los ${metadata.sampledTiles} tiles muestreados '
            '(sin province.yaml no se sabe si son ausencias declaradas): ${unseen.join(', ')}.',
        location: assetPath,
      );
    }
    final json = {...metadata.toJson(), 'file': assetPath, 'app': comparison};
    final text = const JsonEncoder.withIndent('  ').convert(json);
    stdout.writeln(text);
    final out = argResults!['out'] as String?;
    if (out != null) {
      final outFile = File(p.isAbsolute(out) ? out : p.join(base, out));
      outFile.parent.createSync(recursive: true);
      outFile.writeAsStringSync(text);
      stdout.writeln('Guardado: ${outFile.path}');
    }
    printFindings(sink.findings);
    stdout.writeln(
      'Tiempo total: ${formatDuration(watch.elapsedMilliseconds)}',
    );
    return exitCodeFor(sink.findings, strict: strict);
  }
}

class _GeometryCommand extends _Command {
  _GeometryCommand(super.workingDirectory);

  @override
  String get name => 'geometry';

  @override
  String get description =>
      'Cuenta geometrías nulas o inválidas con GDAL (Docker, imagen suelosar-gis-builder).';

  @override
  String get invocation => '${runner!.executableName} geometry <id>';

  @override
  Future<int> run() async {
    final definition = loadProvince();
    final watch = Stopwatch()..start();
    final pipeline = pipelineFor(definition);
    await pipeline.geometry();
    final findings = pipeline.results.single.findings;
    printFindings(findings);
    stdout.writeln(
      'Tiempo total: ${formatDuration(watch.elapsedMilliseconds)}',
    );
    return exitCodeFor(findings);
  }
}

class _ReportCommand extends _StrictCommand {
  _ReportCommand(super.workingDirectory);

  @override
  String get name => 'report';

  @override
  String get description =>
      'Regenera output/report.md y output/report.json con las últimas etapas ejecutadas.';

  @override
  String get invocation => '${runner!.executableName} report <id>';

  @override
  Future<int> run() async {
    final definition = loadProvince();
    final stages = loadStages(definition);
    if (stages.isEmpty) {
      throw ConfigException(
        'No hay etapas guardadas en ${definition.display(definition.stagesDir)}; corré validate o build.',
      );
    }
    final report = writeReport(definition, strict: strict);
    stdout
      ..writeln(
        'RESULTADO: ${report.summary.status.label}  (${report.summary.errors} errores · '
        '${report.summary.warnings} warnings · ${report.summary.infos} info)',
      )
      ..writeln('Reporte: ${definition.display(report.markdown)}')
      ..writeln('         ${definition.display(report.json)}');
    return exitCodeFor([for (final s in stages) ...s.findings], strict: strict);
  }
}
