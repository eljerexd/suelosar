import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../catalog/catalog_diff.dart';
import '../catalog/consolidated_index.dart';
import '../catalog/json_style.dart';
import '../catalog/per_series_catalog.dart';
import '../config/paths.dart';
import '../config/province_definition.dart';
import '../gis_build/docker_map.dart';
import '../gis_build/prepare.dart';
import '../normalize/normalizer.dart';
import '../pmtiles/app_declarations.dart';
import '../pmtiles/archive_check.dart';
import '../pmtiles/optimizer.dart';
import '../pmtiles/pmtiles_checks.dart';
import '../pmtiles/pmtiles_metadata.dart';
import '../schema/suelosar_schema.dart';
import '../sources/geometry_check.dart';
import '../sources/gis_source.dart';
import '../sources/pdf_text.dart';
import '../validation/cross_reference.dart';
import '../validation/finding.dart';
import '../validation/gis_checks.dart';
import 'stamps.dart';
import 'version.dart';

/// Result of one pipeline stage, persisted to `output/stages/<name>.json`
/// so `report` can be regenerated without re-running anything.
class StageResult {
  StageResult(this.name, this.title) : startedAt = DateTime.now();

  StageResult._restore(
    this.name,
    this.title,
    this.startedAt,
    this.durationMs,
    List<Finding> findings,
    Map<String, Object?> data,
  ) {
    sink.findings.addAll(findings);
    this.data.addAll(data);
  }

  factory StageResult.fromJson(Map<String, Object?> json) =>
      StageResult._restore(
        json['name']! as String,
        json['title']! as String,
        DateTime.parse(json['startedAt']! as String),
        json['durationMs']! as int,
        [
          for (final f in json['findings']! as List)
            Finding.fromJson((f as Map).cast()),
        ],
        (json['data']! as Map).cast(),
      );

  final String name;
  final String title;
  final DateTime startedAt;
  int durationMs = 0;
  final FindingSink sink = FindingSink();
  final Map<String, Object?> data = {};

  List<Finding> get findings => sink.findings;

  bool get hasErrors => findings.any((f) => f.severity == Severity.error);

  bool get reused => data['reused'] == true;

  bool get skipped => data['skipped'] == true;

  Map<String, Object?> toJson() => {
    'name': name,
    'title': title,
    'startedAt': startedAt.toIso8601String(),
    'durationMs': durationMs,
    'findings': [for (final f in findings) f.toJson()],
    'data': data,
  };
}

/// Stage order and titles, shared by the report.
const stageTitles = {
  'sources': 'Fuentes',
  'catalog': 'Catálogo',
  'normalize': 'Normalización',
  'prepare': 'Preparación GIS',
  'map': 'PMTiles (Docker)',
  'optimize': 'Optimización',
  'metadata': 'Metadatos y publicación',
  'crossref': 'Cruce GIS ↔ catálogo',
  'geometry': 'Geometrías',
};

/// Stages `build --from/--until` accept, in execution order.
const buildStageNames = [
  'catalog',
  'normalize',
  'prepare',
  'map',
  'optimize',
  'metadata',
  'crossref',
];

/// Stages whose errors keep the PMTiles from being published.
const publicationStages = {
  'normalize',
  'prepare',
  'map',
  'optimize',
  'metadata',
};

/// Everything the catalog stage produced that later stages need.
class CatalogOutcome {
  const CatalogOutcome({required this.keys, required this.namesByKey});

  factory CatalogOutcome.fromJson(Map<String, Object?> json) => CatalogOutcome(
    keys: CatalogKeys(
      keys: {for (final k in json['keys']! as List) k as String},
      labels: (json['labels']! as Map).cast<String, String>(),
      kind: json['kind']! as String,
    ),
    namesByKey: (json['names']! as Map).cast<String, String>(),
  );

  final CatalogKeys keys;

  /// Lookup key -> series name (for `derive: dominant_series_name`).
  final Map<String, String> namesByKey;

  Map<String, Object?> toJson() => {
    'keys': keys.keys.toList()..sort(),
    'labels': keys.labels,
    'kind': keys.kind,
    'names': namesByKey,
  };
}

/// How a `build` run treats stamps.
class RunOptions {
  const RunOptions({
    this.force = false,
    this.from,
    this.until,
    this.dryRun = false,
  });

  /// Ignore every stamp.
  final bool force;

  /// First stage to re-run regardless of its stamp (later ones too).
  final String? from;

  /// Last stage to run.
  final String? until;

  /// `map`: print the Docker command instead of running it.
  final bool dryRun;

  bool get isPartial => from != null || until != null;
}

/// Runs a province's stages. Each stage records its findings, data and
/// duration; unexpected failures become a `STG001` error instead of
/// aborting the run, while [ConfigException] (exit code 2) propagates.
class ProvincePipeline {
  ProvincePipeline(
    this.definition, {
    this.pdftotext,
    this.options = const RunOptions(),
    void Function(String)? log,
  }) : log = log ?? print,
       stamps = StampStore(definition.stampsDir, _hasher);

  static final _hasher = FileHasher();

  final ProvinceDefinition definition;
  final String? pdftotext;
  final RunOptions options;
  final void Function(String) log;
  final StampStore stamps;
  final List<StageResult> results = [];

  FileHasher get hasher => _hasher;

  // State shared between stages of one run.
  CatalogOutcome? catalogOutcome;
  NormalizeResult? normalizeResult;
  MapInputDecision? mapInput;
  Extent? sourceExtent;
  OptimizeReport? optimizeReport;

  ProvinceDefinition get d => definition;

  /// Removes the stage results of a previous run.
  void resetStages() {
    final dir = Directory(d.stagesDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  StageResult? result(String name) =>
      results.where((stage) => stage.name == name).lastOrNull;

  bool succeeded(String name) {
    final stage = result(name);
    return stage != null && !stage.hasErrors && !stage.skipped;
  }

  bool _forced(String name) {
    if (options.force) return true;
    final from = options.from;
    if (from == null) return false;
    return buildStageNames.indexOf(name) >= buildStageNames.indexOf(from);
  }

  /// Runs every build stage in order, honouring `--from`/`--until`.
  Future<void> runBuild() async {
    if (!options.isPartial) resetStages();
    await sources(checkDocker: true);
    for (final name in buildStageNames) {
      switch (name) {
        case 'catalog':
          await catalog(write: true, diff: true, resumable: true);
        case 'normalize':
          await normalize(write: true, resumable: true);
        case 'prepare':
          await prepare();
        case 'map':
          await map();
        case 'optimize':
          await optimize();
        case 'metadata':
          await publishMetadata();
        case 'crossref':
          await crossReference();
      }
      if (name == options.until) break;
    }
  }

  /// `validate`: every check, nothing written but the report.
  Future<void> runValidate() async {
    resetStages();
    await sources(checkDocker: false);
    await catalog(write: false, diff: true);
    await normalize(write: false);
    await crossReference();
    await inspectMetadata(write: false);
  }

  Future<StageResult> _stage(
    String name,
    Future<void> Function(StageResult) body, {
    bool persist = true,
  }) async {
    final stage = StageResult(name, stageTitles[name] ?? name);
    final watch = Stopwatch()..start();
    try {
      await body(stage);
    } on ConfigException {
      rethrow;
    } on Object catch (error) {
      stage.sink.error('STG001', 'La etapa falló: $error');
    }
    stage.durationMs = watch.elapsedMilliseconds;
    results.add(stage);
    if (persist) {
      final file = File(p.join(d.stagesDir, '$name.json'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(stage.toJson()),
      );
    }
    log(formatStageLine(stage));
    return stage;
  }

  /// A stage that is skipped when its stamp still matches its inputs.
  Future<StageResult> _resumable(
    String name, {
    required Future<Map<String, Object?>> Function() fingerprint,
    required List<String> Function() outputs,
    required Future<void> Function(StageResult) body,
    required void Function(Map<String, Object?> extra) restore,
    required Map<String, Object?> Function() extra,
  }) => _stage(name, (stage) async {
    final expected = await fingerprint();
    final previous = stamps.load(name);
    final reason = _forced(name)
        ? (options.force
              ? 'forzada (--force)'
              : 'forzada (--from ${options.from})')
        : await stamps.rejectReason(previous, expected);
    if (reason == null) {
      stage.data
        ..addAll(previous!.data)
        ..['reused'] = true
        ..['originalDurationMs'] = previous.durationMs
        ..['reusedFrom'] = previous.createdAt.toIso8601String();
      stage.sink.findings.addAll(previous.findings);
      restore(previous.extra);
      return;
    }
    stamps.delete(name);
    stage.data['runReason'] = reason;
    final watch = Stopwatch()..start();
    await body(stage);
    if (stage.hasErrors || stage.skipped) return;
    final outputHashes = <String, String>{
      for (final path in outputs()) path: await hasher.sha256(File(path)),
    };
    stamps.save(
      StageStamp(
        stage: name,
        fingerprint: expected,
        outputs: outputHashes,
        data: Map.of(stage.data)..remove('runReason'),
        findings: List.of(stage.findings),
        extra: extra(),
        durationMs: watch.elapsedMilliseconds,
        createdAt: DateTime.now(),
      ),
    );
  });

  void _skip(StageResult stage, String because) {
    stage.data['skipped'] = true;
    stage.sink.info('STG002', 'Etapa omitida: $because.');
  }

  Future<Map<String, String?>> _hashFiles(Iterable<String> paths) async => {
    for (final path in paths)
      p.basename(path): await hasher.sha256OrNull(File(path)),
  };

  List<String> _gisSourceFiles() {
    final source = d.gis.source;
    if (d.gis.format != GisFormat.shapefile) return [source];
    final base = source.substring(
      0,
      source.length - p.extension(source).length,
    );
    return [
      for (final extension in ['.shp', '.dbf', '.shx', '.prj', '.cpg'])
        if (File('$base$extension').existsSync()) '$base$extension',
    ];
  }

  // --- sources -------------------------------------------------------------

  Future<StageResult> sources({
    required bool checkDocker,
  }) => _stage('sources', (stage) async {
    final sink = stage.sink;
    final gis = GisSource.open(d.gis);
    stage.data['gis'] = {
      'file': d.display(d.gis.source),
      'format': d.gis.format.key,
      'exists': gis.exists,
      if (gis.exists) 'sizeBytes': gis.file.lengthSync(),
    };
    if (!gis.exists) {
      sink.error(
        'SRC001',
        'No existe la fuente GIS.',
        location: d.display(d.gis.source),
      );
    } else {
      final missing = gis.missingSidecars();
      stage.data['gis'] = {
        ...stage.data['gis']! as Map<String, Object?>,
        'missingSidecars': [for (final (file, _) in missing) file],
      };
      for (final (file, required) in missing) {
        if (required) {
          sink.error(
            'SRC002',
            'Falta $file junto al shapefile.',
            location: d.display(d.gis.source),
          );
        } else {
          sink.warning(
            'SRC002',
            'Falta $file: se asume ISO-8859-1 salvo que gis.encoding diga otra cosa.',
            location: d.display(d.gis.source),
          );
        }
      }
    }

    final pdf = d.pdf;
    if (pdf == null) {
      sink.info('SRC000', 'La provincia no declara PDFs (sección pdf).');
    } else if (pdf.model == PdfModel.perSeries) {
      final dir = Directory(pdf.directory!);
      final exists = dir.existsSync();
      stage.data['pdf'] = {
        'model': pdf.model.key,
        'directory': d.display(pdf.directory!),
        'exists': exists,
        if (exists) 'files': PerSeriesCatalog.listPdfs(dir).length,
      };
      if (!exists) {
        sink.error(
          'SRC001',
          'No existe la carpeta de PDFs.',
          location: d.display(pdf.directory!),
        );
      }
    } else {
      final file = File(pdf.file!);
      stage.data['pdf'] = {
        'model': pdf.model.key,
        'file': d.display(pdf.file!),
        'exists': file.existsSync(),
        if (file.existsSync()) 'sizeBytes': file.lengthSync(),
      };
      if (!file.existsSync()) {
        sink.error(
          'SRC001',
          'No existe el PDF consolidado.',
          location: d.display(pdf.file!),
        );
      }
    }

    final reference = d.catalog?.reference;
    if (reference != null) {
      final exists = File(reference).existsSync();
      stage.data['catalogReference'] = {
        'file': d.display(reference),
        'exists': exists,
      };
      if (!exists) {
        sink.error(
          'SRC001',
          'No existe el catálogo de referencia declarado.',
          location: d.display(reference),
        );
      }
    }
    final pmtiles = d.pmtiles;
    if (pmtiles == null) {
      sink.info(
        'PMT000',
        'La provincia no declara la sección pmtiles: no se genera PMTiles.',
      );
    } else {
      final ref = pmtiles.reference;
      stage.data['pmtiles'] = {
        'output': pmtiles.output,
        if (ref != null) 'reference': d.display(ref),
        if (ref != null) 'referenceExists': File(ref).existsSync(),
      };
      if (checkDocker) {
        try {
          await DockerMapBuilder(
            repoRoot: d.repoRoot,
            image: d.dockerImage,
          ).ensureAvailable();
          stage.data['docker'] = true;
        } on ConfigException catch (e) {
          stage.data['docker'] = false;
          sink.warning(
            'DKR000',
            'Docker no está disponible: la etapa map no podrá ejecutarse. ${e.message}',
          );
        }
      }
    }
  });

  // --- catalog -------------------------------------------------------------

  /// Generates the catalog; writes it to `output/` when [write].
  Future<CatalogOutcome?> catalog({
    required bool write,
    required bool diff,
    bool persist = true,
    bool resumable = false,
  }) async {
    catalogOutcome = null;
    if (!resumable || d.pdf == null || d.catalog == null) {
      await _stage(
        'catalog',
        (stage) => _catalogBody(stage, write: write, diff: diff),
        persist: persist,
      );
      return catalogOutcome;
    }
    await _resumable(
      'catalog',
      fingerprint: () async => {
        'tool': toolVersion,
        'pdf': d.raw['pdf'],
        'catalog': d.raw['catalog'],
        'inputs': d.pdf!.model == PdfModel.perSeries
            ? await _hashFiles([
                if (Directory(d.pdf!.directory!).existsSync())
                  for (final file in PerSeriesCatalog.listPdfs(
                    Directory(d.pdf!.directory!),
                  ))
                    p.join(d.pdf!.directory!, file),
              ])
            : await _hashFiles([d.pdf!.file!]),
        'reference': d.catalog!.reference == null
            ? null
            : await hasher.sha256OrNull(File(d.catalog!.reference!)),
      },
      outputs: () => [d.catalogOutputFile!],
      body: (stage) => _catalogBody(stage, write: true, diff: diff),
      restore: (extra) => catalogOutcome = CatalogOutcome.fromJson(extra),
      extra: () => catalogOutcome?.toJson() ?? const {},
    );
    return catalogOutcome;
  }

  Future<void> _catalogBody(
    StageResult stage, {
    required bool write,
    required bool diff,
  }) async {
    final pdf = d.pdf;
    final config = d.catalog;
    if (pdf == null || config == null) {
      stage.sink.info(
        'CAT000',
        'Sin catálogo: la provincia no declara pdf/catalog.',
      );
      return;
    }
    final matcher = Normalizer(d);
    final referenceFile = config.reference == null
        ? null
        : File(config.reference!);
    final referenceText = referenceFile != null && referenceFile.existsSync()
        ? referenceFile.readAsStringSync()
        : '';
    Object? document;
    Map<String, Map<String, Object?>> Function(Object?) recordsOf;
    stage.data['model'] = pdf.model.key;

    if (pdf.model == PdfModel.perSeries) {
      final dir = Directory(pdf.directory!);
      if (!dir.existsSync()) {
        stage.sink.error(
          'SRC001',
          'No existe la carpeta de PDFs.',
          location: d.display(pdf.directory!),
        );
        return;
      }
      List<Map<String, Object?>>? reference;
      if (referenceText.isNotEmpty) {
        reference = [
          for (final r in jsonDecode(referenceText) as List)
            (r as Map).cast<String, Object?>(),
        ];
      }
      final built = PerSeriesCatalog.build(
        directory: dir,
        wordSeparator: pdf.wordSeparator!,
        reference: reference,
        findings: stage.sink,
      );
      document = built.records;
      recordsOf = (doc) => {
        for (final r in doc! as List)
          (r as Map)['pdf'].toString(): r.cast<String, Object?>(),
      };
      final labels = <String, String>{};
      final names = <String, String>{};
      for (final record in built.records) {
        final key = matcher.matchKey(record['pdf']! as String);
        labels.putIfAbsent(key, () => record['pdf']! as String);
        names.putIfAbsent(key, () => record['name']! as String);
      }
      catalogOutcome = CatalogOutcome(
        keys: CatalogKeys(
          keys: labels.keys.toSet(),
          labels: labels,
          kind: 'PDFs',
        ),
        namesByKey: names,
      );
      stage.data
        ..['pdfFiles'] = built.pdfFiles.length
        ..['records'] = built.records.length
        ..['seriesKeys'] = labels.length;
    } else {
      final file = File(pdf.file!);
      if (!file.existsSync()) {
        stage.sink.error(
          'SRC001',
          'No existe el PDF consolidado.',
          location: d.display(pdf.file!),
        );
        return;
      }
      final executable = await resolvePdftotext(explicit: pdftotext);
      final text = await PdfText.extract(file, executable: executable);
      final index = ConsolidatedIndex.build(
        text: text,
        toc: pdf.toc!,
        generatedFrom: p.basename(file.path),
        pdfAsset: pdf.assetPath!,
        provinceLabel: config.provinceLabel,
        findings: stage.sink,
      );
      stage.data
        ..['pages'] = text.pageCount
        ..['tocEntries'] = index.entries.length
        ..['series'] = index.series.length
        ..['pageOffset'] = index.pageOffset
        ..['pageOffsetDetected'] = index.pageOffsetDetected
        ..['generatedFrom'] = p.basename(file.path);
      if (index.series.isNotEmpty) {
        stage.data['pageRange'] = [
          index.series.first.startPage,
          index.series.last.endPage,
        ];
      }
      if (index.json == null) return;
      document = index.json;
      recordsOf = (doc) => {
        for (final e in ((doc! as Map)['series'] as Map).entries)
          e.key.toString(): (e.value as Map).cast<String, Object?>(),
      };
      catalogOutcome = CatalogOutcome(
        keys: CatalogKeys(
          keys: {for (final s in index.series) matcher.matchKey(s.code)},
          labels: {
            for (final s in index.series) matcher.matchKey(s.code): s.code,
          },
          kind: 'series del índice',
        ),
        namesByKey: {
          for (final s in index.series) matcher.matchKey(s.code): s.name,
        },
      );
    }

    final text = encodeCatalogJson(document, config.jsonStyle);
    if (write) {
      final out = File(d.catalogOutputFile!);
      out.parent.createSync(recursive: true);
      out.writeAsStringSync(text);
      stage.data['output'] = d.display(out.path);
    }
    if (diff) {
      if (referenceText.isEmpty) {
        stage.sink.info(
          'CAT007',
          'No hay catálogo de referencia contra el cual comparar.',
        );
        if (write) {
          stage.data['manualSteps'] = [
            'Integrar `${d.display(d.catalogOutputFile!)}` en la app (no hay catalog.reference).',
          ];
        }
      } else {
        final comparison = CatalogDiff.compare(
          generated: document,
          generatedText: text,
          referenceText: referenceText,
          recordsOf: recordsOf,
        );
        comparison.report(stage.sink, d.display(config.reference!));
        stage.data['diff'] = {
          'reference': d.display(config.reference!),
          ...comparison.toJson(),
        };
        if (write && !comparison.textEqual) {
          stage.data['manualSteps'] = [
            'Revisar y copiar `${d.display(d.catalogOutputFile!)}` a `${d.display(config.reference!)}` — no se hace automáticamente.',
          ];
        }
      }
    }
  }

  /// Series names the app already ships, when the catalog stage did not
  /// run (used only by `derive` rules).
  Map<String, String> _referenceNames() {
    final reference = d.catalog?.reference;
    if (reference == null || !File(reference).existsSync()) return const {};
    final matcher = Normalizer(d);
    final document = jsonDecode(File(reference).readAsStringSync());
    if (document is Map<String, Object?>) {
      return {
        for (final e in ConsolidatedIndex.namesFromDocument(document).entries)
          matcher.matchKey(e.key): e.value,
      };
    }
    return {
      for (final r in document as List)
        matcher.matchKey((r as Map)['pdf'].toString()): r['name'].toString(),
    };
  }

  // --- normalize -----------------------------------------------------------

  Map<String, String> _seriesNames(StageResult stage) {
    final catalog = catalogOutcome;
    var names = catalog?.namesByKey ?? const <String, String>{};
    if (d.gis.mapping.usesDerivations && catalog == null) {
      names = _referenceNames();
      stage.data['derivationNamesFrom'] = d.catalog?.reference == null
          ? null
          : d.display(d.catalog!.reference!);
    } else if (d.gis.mapping.usesDerivations) {
      stage.data['derivationNamesFrom'] = 'catálogo generado';
    }
    return names;
  }

  /// Reads the GIS and checks it; writes `work/normalized.geojson` when
  /// [write].
  Future<NormalizeResult?> normalize({
    required bool write,
    bool resumable = false,
  }) async {
    normalizeResult = null;
    Future<void> body(StageResult stage) async {
      if (!File(d.gis.source).existsSync()) {
        stage.sink.error(
          'SRC001',
          'No existe la fuente GIS.',
          location: d.display(d.gis.source),
        );
        return;
      }
      final names = _seriesNames(stage);
      if (d.gis.mapping.usesDerivations && names.isEmpty) {
        stage.sink.error(
          'CFG003',
          'gis.mapping usa derive, pero no hay catálogo con nombres de series.',
        );
      }
      final normalizer = Normalizer(
        d,
        seriesNames: names,
        catalogKeys: catalogOutcome?.keys.keys,
      );
      final r = normalizeResult = await normalizer.run(
        output: write ? File(d.normalizedGisFile) : null,
      );
      checkGis(d, r, stage.sink);
      stage.data
        ..['features'] = r.featureCount
        ..['encoding'] = r.encodingName
        ..['sourceColumns'] = r.sourceColumns.length
        ..['declaredColumns'] = r.declaredColumns
        ..['featuresWithSeries'] = r.featuresWithSeries
        ..['distinctSeries'] = r.seriesFeatureCounts.length
        ..['nullGeometries'] = r.nullGeometries
        ..['coverage'] = coverageRows(d, r);
      if (write) {
        stage.data['output'] = d.display(d.normalizedGisFile);
        stage.data['outputBytes'] = File(d.normalizedGisFile).lengthSync();
      }
    }

    if (!resumable) {
      await _stage('normalize', body);
      return normalizeResult;
    }
    await _resumable(
      'normalize',
      fingerprint: () async {
        final keys = catalogOutcome?.keys.keys.toList()?..sort();
        return {
          'tool': toolVersion,
          'gis': d.raw['gis'],
          'sources': await _hashFiles(_gisSourceFiles()),
          'seriesNames': d.gis.mapping.usesDerivations
              ? hashJson(
                  Map.fromEntries(
                    (catalogOutcome?.namesByKey ?? _referenceNames()).entries
                        .toList()
                      ..sort((a, b) => a.key.compareTo(b.key)),
                  ),
                )
              : null,
          'catalogKeys': keys == null ? null : hashJson(keys),
        };
      },
      outputs: () => [d.normalizedGisFile],
      body: body,
      restore: (extra) =>
          normalizeResult = NormalizeResult.fromSummaryJson(extra),
      extra: () => normalizeResult?.toSummaryJson() ?? const {},
    );
    return normalizeResult;
  }

  // --- prepare -------------------------------------------------------------

  Future<void> prepare() async {
    mapInput = null;
    sourceExtent = null;
    final pmtiles = d.pmtiles;
    if (pmtiles == null) {
      await _stage(
        'prepare',
        (stage) async => _skip(stage, 'la provincia no declara pmtiles'),
      );
      return;
    }
    final (decision, problem) = decideMapInput(d);
    if (decision == null) {
      await _stage(
        'prepare',
        (stage) async => stage.sink.error('PRE001', problem!),
      );
      return;
    }
    if (decision.kind == MapInputKind.normalized &&
        (!succeeded('normalize') || !File(d.normalizedGisFile).existsSync())) {
      await _stage('prepare', (stage) async {
        _skip(stage, 'la normalización no terminó bien');
        stage.data['route'] = decision.kind.key;
      });
      return;
    }
    await _resumable(
      'prepare',
      fingerprint: () async => {
        'tool': toolVersion,
        'route': decision.kind.key,
        'input': d.pmtiles!.input.key,
        'optionalAttributes': decision.optionalAttributes,
        'files': decision.kind == MapInputKind.normalized
            ? await _hashFiles([d.normalizedGisFile])
            : await _hashFiles(decision.inputFiles),
      },
      outputs: () => decision.kind == MapInputKind.normalized
          ? [d.mapInputFile]
          : const [],
      body: (stage) async {
        stage.data
          ..['route'] = decision.kind.key
          ..['reason'] = decision.reason
          ..['file'] = d.display(decision.file)
          ..['optionalAttributes'] = decision.optionalAttributes;
        if (decision.kind == MapInputKind.source) {
          final mapInputDir = Directory(d.mapInputDir);
          if (mapInputDir.existsSync()) mapInputDir.deleteSync(recursive: true);
          sourceExtent = p.extension(decision.file).toLowerCase() == '.shp'
              ? shapefileExtent(File(decision.file))
              : null;
        } else {
          final stats = await writeMapInput(
            File(d.normalizedGisFile),
            File(d.mapInputFile),
          );
          sourceExtent = stats.extent;
          stage.data
            ..['features'] = stats.features
            ..['emptiedValues'] = stats.emptiedValues
            ..['outputBytes'] = File(d.mapInputFile).lengthSync();
          if (stats.features !=
              (normalizeResult?.featureCount ?? stats.features)) {
            stage.sink.error(
              'PRE001',
              'map_input tiene ${stats.features} features y el GIS normalizado ${normalizeResult!.featureCount}.',
            );
          }
        }
        stage.data['extent'] = sourceExtent?.toJson();
        stage.sink.info(
          'PRE000',
          decision.reason,
          location: d.display(decision.file),
        );
      },
      restore: (extra) {
        mapInput = decision;
        final extent = extra['extent'];
        sourceExtent = extent == null
            ? null
            : Extent.fromJson((extent as Map).cast());
      },
      extra: () => {'extent': sourceExtent?.toJson()},
    );
    if (succeeded('prepare')) mapInput = decision;
  }

  // --- map -----------------------------------------------------------------

  Map<String, String> _mapEnvironment(
    PmtilesConfig pmtiles,
    MapInputDecision decision,
  ) => {
    'LAYER_NAME': pmtiles.layer,
    'MIN_ZOOM': '${pmtiles.minZoom}',
    'MAX_ZOOM': '${pmtiles.maxZoom}',
    'OPTIONAL_ATTRIBUTES': decision.optionalAttributes.join(','),
  };

  Future<void> map() async {
    final pmtiles = d.pmtiles;
    final decision = mapInput;
    if (pmtiles == null || decision == null) {
      await _stage(
        'map',
        (stage) async => _skip(
          stage,
          pmtiles == null
              ? 'la provincia no declara pmtiles'
              : 'la preparación GIS no terminó bien',
        ),
      );
      return;
    }
    final builder = DockerMapBuilder(
      repoRoot: d.repoRoot,
      image: d.dockerImage,
      log: (m) => log('    $m'),
    );
    final environment = _mapEnvironment(pmtiles, decision);
    final full = d.fullPmtilesFile!;
    final outputName = p.basename(full);
    if (options.dryRun) {
      await _stage('map', (stage) async {
        final command = [
          'docker',
          ...builder.runArguments(
            inputFile: decision.file,
            outputDir: d.pmtilesWorkDir,
            outputName: outputName,
            environment: environment,
          ),
        ];
        stage.data['command'] = command;
        _skip(stage, '--dry-run');
        log(
          '    ${command.map((a) => a.contains(' ') ? '"$a"' : a).join(' ')}',
        );
      }, persist: false);
      return;
    }
    await _resumable(
      'map',
      fingerprint: () async => {
        'tool': toolVersion,
        'scripts': dockerScriptsHash(d.repoRoot),
        'image': d.dockerImage,
        'environment': environment,
        'outputName': outputName,
        'inputs': await _hashFiles(decision.inputFiles),
      },
      outputs: () => [full],
      body: (stage) async {
        await builder.ensureAvailable();
        final image = await builder.ensureImage(
          File(p.join(d.logsDir, 'docker_build.log')),
        );
        stage.data
          ..['image'] = d.dockerImage
          ..['imageId'] = image.imageId
          ..['imageRebuilt'] = image.rebuilt
          ..['scriptsHash'] = dockerScriptsHash(d.repoRoot)
          ..['input'] = d.display(decision.file)
          ..['environment'] = environment;
        for (final stale in [File(full), File('$full.sha256')]) {
          if (stale.existsSync()) stale.deleteSync();
        }
        final logFile = File(p.join(d.logsDir, 'map.log'));
        final run = await builder.run(
          inputFile: decision.file,
          outputDir: d.pmtilesWorkDir,
          outputName: outputName,
          environment: environment,
          log: logFile,
        );
        stage.data
          ..['log'] = d.display(logFile.path)
          ..['dockerMs'] = run.durationMs
          ..['exitCode'] = run.exitCode;
        if (run.exitCode != 0 || !File(full).existsSync()) {
          stage.sink.error(
            'DKR002',
            'build_map.sh falló (código ${run.exitCode}); ver ${d.display(logFile.path)}.',
            examples: run.logTail.reversed.take(8).toList().reversed,
          );
          return;
        }
        final sha = await hasher.sha256(File(full));
        final sidecar = File('$full.sha256');
        final declared = sidecar.existsSync()
            ? sidecar.readAsStringSync().trim()
            : null;
        stage.data
          ..['output'] = d.display(full)
          ..['sizeBytes'] = File(full).lengthSync()
          ..['sha256'] = sha;
        if (declared != sha) {
          stage.sink.error(
            'MAP001',
            'El .sha256 escrito por build_map.sh no coincide con el archivo.',
          );
        }
      },
      restore: (_) {},
      extra: () => const {},
    );
  }

  // --- optimize ------------------------------------------------------------

  Future<void> optimize() async {
    optimizeReport = null;
    final pmtiles = d.pmtiles;
    if (pmtiles == null || !succeeded('map')) {
      await _stage(
        'optimize',
        (stage) async => _skip(
          stage,
          pmtiles == null
              ? 'la provincia no declara pmtiles'
              : 'no hay PMTiles generado',
        ),
      );
      return;
    }
    final input = File(d.fullPmtilesFile!);
    final output = File(d.optimizedPmtilesFile!);
    final keep = SuelosArSchema.appAttributes.toList()..sort();
    await _resumable(
      'optimize',
      fingerprint: () async => {
        'tool': toolVersion,
        'input': await hasher.sha256(input),
        'keep': keep,
        'mode': pmtiles.optimize.key,
      },
      outputs: () => [output.path, '${output.path}.sha256'],
      body: (stage) async {
        try {
          final report = optimizeReport = await PmtilesOptimizer(
            log: (m) => log('    $m'),
          ).run(input, output, mode: pmtiles.optimize);
          stage.data
            ..['output'] = d.display(output.path)
            ..addAll(
              report.toJson()
                ..remove('input')
                ..remove('output'),
            );
        } on PmtilesStructureException catch (e) {
          stage.sink.error(
            'OPT002',
            e.message,
            location: d.display(input.path),
          );
        }
      },
      restore: (extra) => optimizeReport = OptimizeReport.fromJson(extra),
      extra: () => optimizeReport?.toJson() ?? const {},
    );
  }

  // --- metadata ------------------------------------------------------------

  void _unpublish(StageResult stage, String because) {
    final published = d.publishedPmtilesFile;
    final removed = <String>[];
    for (final path in [
      ?published,
      if (published != null) '$published.sha256',
      d.pmtilesMetadataFile,
    ]) {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
        removed.add(d.display(path));
      }
    }
    stage.data
      ..['published'] = false
      ..['notPublishedBecause'] = because
      ..['removedStaleOutputs'] = removed;
    stage.sink.info(
      'PUB001',
      'No se publica el PMTiles: $because.'
          '${removed.isEmpty ? '' : ' Se quitaron salidas de una corrida anterior.'}',
      examples: removed,
    );
  }

  /// `build`: validates the generated archive and publishes it to
  /// `output/` only when no publication stage failed.
  Future<void> publishMetadata() => _stage('metadata', (stage) async {
    final pmtiles = d.pmtiles;
    if (pmtiles == null) {
      _skip(stage, 'la provincia no declara pmtiles');
      return;
    }
    final report = optimizeReport;
    final failed = [
      for (final name in publicationStages)
        if (name != 'metadata' && (result(name)?.hasErrors ?? false))
          stageTitles[name]!,
    ];
    if (report == null || !succeeded('optimize') || failed.isNotEmpty) {
      _unpublish(
        stage,
        failed.isNotEmpty
            ? 'fallaron ${failed.join(', ')}'
            : 'no hay PMTiles optimizado',
      );
      return;
    }
    final work = File(d.optimizedPmtilesFile!);
    final absent = absentFields(d.gis.mapping);
    final location = d.display(work.path);
    final metadata = await PmtilesMetadata.read(work, layer: pmtiles.layer);
    checkGeneratedArchive(
      metadata: metadata,
      report: report,
      config: pmtiles,
      absent: absent,
      sourceExtent: sourceExtent,
      findings: stage.sink,
      location: location,
    );
    final referencePath = pmtiles.reference;
    final app = checkPmtiles(
      metadata: metadata,
      assetPath: d.display(referencePath ?? d.publishedPmtilesFile!),
      app: AppDeclarations.read(d.repoRoot),
      // Attribute presence was checked on every tile (OPT001).
      expectedAttributes: const [],
      layer: pmtiles.layer,
      findings: stage.sink,
    );
    final referenceFile = referencePath == null ? null : File(referencePath);
    final reference = compareWithReference(
      sha256: metadata.sha256,
      sizeBytes: metadata.sizeBytes,
      referenceSha256: referenceFile == null
          ? null
          : await hasher.sha256OrNull(referenceFile),
      referenceSize: referenceFile != null && referenceFile.existsSync()
          ? referenceFile.lengthSync()
          : null,
      referenceLocation: referencePath == null
          ? null
          : d.display(referencePath),
      findings: stage.sink,
    );
    if (stage.hasErrors) {
      _unpublish(stage, 'el PMTiles generado no pasó la validación');
      return;
    }

    // Publish: copy, verify, sidecar, metadata.
    final published = File(d.publishedPmtilesFile!);
    published.parent.createSync(recursive: true);
    final temp = File('${published.path}.tmp');
    await work.copy(temp.path);
    final publishedSha = await hasher.sha256(temp);
    if (publishedSha != metadata.sha256) {
      temp.deleteSync();
      stage.sink.error(
        'PUB002',
        'La copia publicada no coincide con el archivo validado.',
      );
      _unpublish(stage, 'la copia no coincide');
      return;
    }
    if (published.existsSync()) published.deleteSync();
    temp.renameSync(published.path);
    writeSha256Sidecar(published, publishedSha);

    final steps = manualSteps(
      definition: d,
      publishedFile: d.display(published.path),
      reference: reference,
      app: app,
      sizeBytes: metadata.sizeBytes,
    );
    final document = {
      'province': d.id,
      'role': 'published',
      'file': pmtiles.output,
      'path': d.display(published.path),
      ...metadata.toJson()..remove('file'),
      'sha256Sidecar': publishedSha,
      'sha256SidecarMatches': true,
      'layer': pmtiles.layer,
      'attributes': report.attributesKept.toList()..sort(),
      'attributesSource': 'todos los tiles (${report.uniqueTiles})',
      'absentAttributes': absent,
      'optimization': {
        'rewritten': report.rewritten,
        'sizeBefore': report.sizeBefore,
        'sizeAfter': report.sizeAfter,
        'removed': report.attributesRemoved.toList()..sort(),
      },
      'pipeline': {
        'tool': toolVersion,
        'input': result('prepare')?.data['route'],
        'dockerScriptsHash': dockerScriptsHash(d.repoRoot),
        'imageId': result('map')?.data['imageId'],
      },
      'reference': reference,
      'app': app,
      'generatedAt': DateTime.now().toIso8601String(),
    };
    File(
      d.pmtilesMetadataFile,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(document));
    stage.data
      ..['published'] = true
      ..['output'] = d.display(published.path)
      ..['metadataFile'] = d.display(d.pmtilesMetadataFile)
      ..['metadata'] = document
      ..['app'] = app
      ..['reference'] = reference
      ..['manualSteps'] = steps;
  });

  /// `validate` and `metadata --province`: inspects the published archive
  /// (or, before the first build, the one the app ships).
  Future<PmtilesMetadata?> inspectMetadata({required bool write}) async {
    PmtilesMetadata? metadata;
    await _stage('metadata', (stage) async {
      final pmtiles = d.pmtiles;
      if (pmtiles == null) {
        stage.sink.info(
          'PMT000',
          'La provincia no declara la sección pmtiles.',
        );
        return;
      }
      final published = File(d.publishedPmtilesFile!);
      final reference = pmtiles.reference == null
          ? null
          : File(pmtiles.reference!);
      final (file, role) = published.existsSync()
          ? (published, 'published')
          : reference != null && reference.existsSync()
          ? (reference, 'reference')
          : (null, null);
      if (file == null) {
        stage.sink.warning(
          'PMT000',
          'Todavía no hay PMTiles publicado ni de referencia; se valida al ejecutar build.',
        );
        return;
      }
      metadata = await PmtilesMetadata.read(file, layer: pmtiles.layer);
      final app = checkPmtiles(
        metadata: metadata!,
        assetPath: d.display(pmtiles.reference ?? file.path),
        app: AppDeclarations.read(d.repoRoot),
        expectedAttributes: expectedArchiveAttributes(
          d.gis.mapping,
          d.gis.thresholds.fields,
        ),
        layer: pmtiles.layer,
        findings: stage.sink,
      );
      final document = {
        'province': d.id,
        'role': role,
        'path': d.display(file.path),
        ...metadata!.toJson()..remove('file'),
        'file': d.display(file.path),
        'layer': pmtiles.layer,
        'attributes': metadata!.attributesSeen,
        'attributesSource': 'muestra de ${metadata!.sampledTiles} tiles',
        'app': app,
        'generatedAt': DateTime.now().toIso8601String(),
      };
      stage.data
        ..['role'] = role
        ..['metadata'] = document
        ..['app'] = app;
      if (write) {
        final out = File(d.pmtilesMetadataFile);
        out.parent.createSync(recursive: true);
        out.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(document),
        );
        stage.data['metadataFile'] = d.display(out.path);
      }
    });
    return metadata;
  }

  // --- cross reference -----------------------------------------------------

  Future<void> crossReference() => _stage('crossref', (stage) async {
    final gis = normalizeResult;
    final catalog = catalogOutcome;
    if (gis == null || catalog == null) {
      stage.sink.info(
        'XRF000',
        'Cruce omitido: falta el resultado del GIS o del catálogo.',
      );
      return;
    }
    stage.data.addAll(checkCrossReference(d, gis, catalog.keys, stage.sink));
  });

  // --- geometry ------------------------------------------------------------

  Future<void> geometry() => _stage('geometry', (stage) async {
    if (!File(d.gis.source).existsSync()) {
      stage.sink.error(
        'SRC001',
        'No existe la fuente GIS.',
        location: d.display(d.gis.source),
      );
      return;
    }
    final result = await checkGeometriesWithDocker(
      sourceFile: d.gis.source,
      image: d.dockerImage,
    );
    stage.data.addAll({...result.toJson(), 'image': d.dockerImage});
    final problems = result.nullGeometries + result.invalidGeometries;
    if (problems > 0) {
      stage.sink.warning(
        'GIS006',
        '${result.invalidGeometries} geometrías inválidas y ${result.nullGeometries} nulas antes de la reparación '
            '(el pipeline Docker las repara con -makevalid y rechaza las que queden inválidas).',
        location: d.display(d.gis.source),
        examples: result.examples,
        count: problems,
      );
    } else {
      stage.sink.info(
        'GIS006',
        'Las ${result.features} geometrías son válidas.',
        location: d.display(d.gis.source),
      );
    }
  });
}

/// One console line per stage.
String formatStageLine(StageResult stage) {
  final errors = countBySeverity(stage.findings, Severity.error);
  final warnings = countBySeverity(stage.findings, Severity.warning);
  final symbol = errors > 0
      ? '✗'
      : stage.skipped
      ? '–'
      : warnings > 0
      ? '⚠'
      : '✓';
  final note = stage.reused
      ? '   (reutilizada; tomó ${formatDuration(stage.data['originalDurationMs']! as int)})'
      : stage.skipped
      ? '   (omitida)'
      : '';
  return '$symbol ${stage.title.padRight(24)} ${formatDuration(stage.durationMs).padLeft(8)}'
      '   $errors errores · $warnings warnings$note';
}

String formatDuration(int milliseconds) => milliseconds < 1000
    ? '$milliseconds ms'
    : milliseconds < 60000
    ? '${(milliseconds / 1000).toStringAsFixed(milliseconds < 10000 ? 2 : 1)} s'
    : '${milliseconds ~/ 60000} min ${((milliseconds % 60000) / 1000).round()} s';
