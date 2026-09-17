import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../catalog/catalog_diff.dart';
import '../catalog/consolidated_index.dart';
import '../catalog/json_style.dart';
import '../catalog/per_series_catalog.dart';
import '../config/paths.dart';
import '../config/province_definition.dart';
import '../normalize/normalizer.dart';
import '../pmtiles/app_declarations.dart';
import '../pmtiles/pmtiles_checks.dart';
import '../pmtiles/pmtiles_metadata.dart';
import '../sources/geometry_check.dart';
import '../sources/gis_source.dart';
import '../sources/pdf_text.dart';
import '../validation/cross_reference.dart';
import '../validation/finding.dart';
import '../validation/gis_checks.dart';

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
  'gis': 'GIS',
  'crossref': 'Cruce GIS ↔ catálogo',
  'pmtiles': 'PMTiles',
  'geometry': 'Geometrías',
};

/// Everything the catalog stage produced that later stages need.
class CatalogOutcome {
  const CatalogOutcome({required this.keys, required this.namesByKey});

  final CatalogKeys keys;

  /// Lookup key -> series name (for `derive: dominant_series_name`).
  final Map<String, String> namesByKey;
}

/// Runs a province's stages. Each stage records its findings, data and
/// duration; unexpected failures become a `STG001` error instead of
/// aborting the run, while [ConfigException] (exit code 2) propagates.
class ProvincePipeline {
  ProvincePipeline(
    this.definition, {
    this.pdftotext,
    void Function(String)? log,
  }) : log = log ?? print;

  final ProvinceDefinition definition;
  final String? pdftotext;
  final void Function(String) log;
  final List<StageResult> results = [];

  ProvinceDefinition get d => definition;

  /// Removes the stage results of a previous run.
  void resetStages() {
    final dir = Directory(d.stagesDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
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

  // --- sources -------------------------------------------------------------

  Future<StageResult> sources() => _stage('sources', (stage) async {
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
    if (pmtiles != null) {
      final exists = File(pmtiles.file).existsSync();
      stage.data['pmtiles'] = {
        'file': d.display(pmtiles.file),
        'exists': exists,
      };
      if (!exists) {
        sink.warning(
          'SRC001',
          'Todavía no existe el PMTiles declarado.',
          location: d.display(pmtiles.file),
        );
      }
    }
  });

  // --- catalog -------------------------------------------------------------

  /// Generates the catalog; writes it to `output/` when [write].
  Future<CatalogOutcome?> catalog({
    required bool write,
    required bool diff,
    bool persist = true,
  }) async {
    CatalogOutcome? outcome;
    await _stage('catalog', (stage) async {
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
      final String referenceText;
      final referenceFile = config.reference == null
          ? null
          : File(config.reference!);
      referenceText = referenceFile != null && referenceFile.existsSync()
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
        outcome = CatalogOutcome(
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
        outcome = CatalogOutcome(
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
        }
      }
    }, persist: persist);
    return outcome;
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

  // --- gis -----------------------------------------------------------------

  /// Reads the GIS and checks it; writes `work/normalized.geojson` when
  /// [write].
  Future<NormalizeResult?> gis({
    required bool write,
    CatalogOutcome? catalog,
  }) async {
    NormalizeResult? result;
    await _stage('gis', (stage) async {
      if (!File(d.gis.source).existsSync()) {
        stage.sink.error(
          'SRC001',
          'No existe la fuente GIS.',
          location: d.display(d.gis.source),
        );
        return;
      }
      var names = catalog?.namesByKey ?? const <String, String>{};
      if (d.gis.mapping.usesDerivations && catalog == null) {
        names = _referenceNames();
        stage.data['derivationNamesFrom'] = d.catalog?.reference == null
            ? null
            : d.display(d.catalog!.reference!);
      } else if (d.gis.mapping.usesDerivations) {
        stage.data['derivationNamesFrom'] = 'catálogo generado';
      }
      if (d.gis.mapping.usesDerivations && names.isEmpty) {
        stage.sink.error(
          'CFG003',
          'gis.mapping usa derive, pero no hay catálogo con nombres de series.',
        );
      }
      final normalizer = Normalizer(
        d,
        seriesNames: names,
        catalogKeys: catalog?.keys.keys,
      );
      result = await normalizer.run(
        output: write ? File(d.normalizedGisFile) : null,
      );
      final r = result!;
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
    });
    return result;
  }

  // --- cross reference -----------------------------------------------------

  Future<void> crossReference(NormalizeResult? gis, CatalogOutcome? catalog) =>
      _stage('crossref', (stage) async {
        if (gis == null || catalog == null) {
          stage.sink.info(
            'XRF000',
            'Cruce omitido: falta el resultado del GIS o del catálogo.',
          );
          return;
        }
        stage.data.addAll(
          checkCrossReference(d, gis, catalog.keys, stage.sink),
        );
      });

  // --- pmtiles -------------------------------------------------------------

  Future<PmtilesMetadata?> pmtiles({required bool write}) async {
    PmtilesMetadata? metadata;
    await _stage('pmtiles', (stage) async {
      final config = d.pmtiles;
      if (config == null) {
        stage.sink.info('PMT000', 'La provincia no declara pmtiles.file.');
        return;
      }
      final file = File(config.file);
      if (!file.existsSync()) {
        stage.sink.warning(
          'PMT000',
          'Todavía no existe el PMTiles; se valida cuando se genere.',
          location: d.display(config.file),
        );
        return;
      }
      metadata = await PmtilesMetadata.read(file, layer: config.layer);
      final comparison = checkPmtiles(
        metadata: metadata!,
        assetPath: d.display(config.file),
        app: AppDeclarations.read(d.repoRoot),
        expectedAttributes: expectedArchiveAttributes(
          d.gis.mapping,
          d.gis.thresholds.fields,
        ),
        layer: config.layer,
        findings: stage.sink,
      );
      stage.data
        ..['metadata'] = {...metadata!.toJson(), 'file': d.display(config.file)}
        ..['app'] = comparison;
      if (write) {
        final out = File(d.pmtilesMetadataFile);
        out.parent.createSync(recursive: true);
        out.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(stage.data['metadata']),
        );
        stage.data['output'] = d.display(out.path);
      }
    });
    return metadata;
  }

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
      : warnings > 0
      ? '⚠'
      : '✓';
  return '$symbol ${stage.title.padRight(22)} ${formatDuration(stage.durationMs).padLeft(8)}'
      '   $errors errores · $warnings warnings';
}

String formatDuration(int milliseconds) => milliseconds < 1000
    ? '$milliseconds ms'
    : '${(milliseconds / 1000).toStringAsFixed(milliseconds < 10000 ? 2 : 1)} s';
