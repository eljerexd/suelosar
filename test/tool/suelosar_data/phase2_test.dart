import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/optimize_buenos_aires_pmtiles.dart' as wrapper;
import '../../../tool/suelosar_data/cli/pipeline.dart';
import '../../../tool/suelosar_data/cli/runner.dart';
import '../../../tool/suelosar_data/cli/stamps.dart';
import '../../../tool/suelosar_data/config/paths.dart';
import '../../../tool/suelosar_data/config/province_definition.dart';
import '../../../tool/suelosar_data/gis_build/docker_map.dart';
import '../../../tool/suelosar_data/gis_build/prepare.dart';
import '../../../tool/suelosar_data/normalize/field_mapping.dart';
import '../../../tool/suelosar_data/pmtiles/archive_check.dart';
import '../../../tool/suelosar_data/pmtiles/optimizer.dart';
import '../../../tool/suelosar_data/pmtiles/pmtiles_metadata.dart';
import '../../../tool/suelosar_data/schema/suelosar_schema.dart';
import '../../../tool/suelosar_data/validation/finding.dart';
import 'helpers.dart';
import 'pmtiles_fixture.dart';

/// Every schema field, plus attributes the optimizer must drop.
Map<String, Object?> _tileFeature({bool withExtras = false, List<String> omit = const []}) => {
  for (final field in SuelosArSchema.requiredFields)
    if (!omit.contains(field)) field: SuelosArSchema.isPercentage(field) ? 50 : 'v-$field',
  if (withExtras) 'FASE1': 'extra',
  if (withExtras) 'taxo_ppal': 'extra',
};

Map<(int, int, int), List<Map<String, Object?>>> _allZooms({
  bool withExtras = false,
  List<String> omit = const [],
  int minZoom = 4,
  int maxZoom = 14,
}) => {
  for (var z = minZoom; z <= maxZoom; z++)
    tileAt(z): [
      _tileFeature(withExtras: withExtras, omit: omit),
      _tileFeature(withExtras: withExtras, omit: omit)..['SIMBC'] = 'otro',
    ],
};

/// A synthetic province with a GeoJSON source, identity mapping (except
/// [mapping]) and a pmtiles section.
ProvinceDefinition _province(
  Directory root, {
  String id = 'mini',
  String? mapping,
  String pmtiles = 'pmtiles:\n  output: mini_soil_polygons.pmtiles',
  String format = 'geojson_lines',
  String source = 'gis.geojson',
}) {
  writeProvince(root, id, '''
id: $id
name: Mini
gis:
  source: $source
  format: $format
  mapping:
${mapping ?? identityMapping()}
$pmtiles
''');
  return ProvinceDefinition.load(id: id, provincesDir: root.path, repoRoot: repoRoot);
}

void main() {
  group('pmtiles configuration', () {
    test('defaults', () {
      final d = _province(tempDir('pm_defaults'), pmtiles: 'pmtiles: {}');
      final pm = d.pmtiles!;
      expect(pm.output, 'mini_soil_polygons.pmtiles');
      expect(pm.stem, 'mini_soil_polygons');
      expect(pm.reference, isNull);
      expect((pm.minZoom, pm.maxZoom), (4, 14));
      expect(pm.input, PmtilesInput.auto);
      expect(pm.optimize, OptimizeMode.auto);
      expect(d.fullPmtilesFile, endsWith(p.join('work', 'pmtiles', 'mini_soil_polygons.full.pmtiles')));
      expect(d.optimizedPmtilesFile, endsWith(p.join('work', 'pmtiles', 'mini_soil_polygons.pmtiles')));
      expect(d.publishedPmtilesFile, endsWith(p.join('output', 'mini_soil_polygons.pmtiles')));
    });

    test('every option', () {
      final d = _province(
        tempDir('pm_full'),
        pmtiles: 'pmtiles:\n'
            '  output: x.pmtiles\n'
            '  reference: \${REPO}/assets/maps/x.pmtiles\n'
            '  layer: capa\n'
            '  zooms: { min: 5, max: 15 }\n'
            '  input: normalized\n'
            '  optimize: never',
      );
      final pm = d.pmtiles!;
      expect(pm.output, 'x.pmtiles');
      expect(pm.reference, p.normalize(p.join(repoRoot, 'assets/maps/x.pmtiles')));
      expect(pm.layer, 'capa');
      expect((pm.minZoom, pm.maxZoom), (5, 15));
      expect(pm.input, PmtilesInput.normalized);
      expect(pm.optimize, OptimizeMode.never);
    });

    test('rejects the old key, bad names, zooms and values', () {
      expect(
        () => _province(
          tempDir('pm_bad'),
          pmtiles: 'pmtiles:\n'
              '  file: x.pmtiles\n'
              '  output: sub/x.mbtiles\n'
              '  zooms: { min: 7, max: 12 }\n'
              '  input: shapefile\n'
              '  otra: 1',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('se renombró a pmtiles.reference'),
              contains('pmtiles.output'),
              contains('pmtiles.zooms.min'),
              contains('pmtiles.zooms.max'),
              contains('pmtiles.input: "shapefile"'),
              contains('claves desconocidas otra'),
            ]),
          ),
        ),
      );
    });

    test('the versioned provinces declare their outputs and references', () {
      final provinces = p.join(repoRoot, 'data', 'provinces');
      final ba = ProvinceDefinition.load(id: 'buenos_aires', provincesDir: provinces, repoRoot: repoRoot);
      final sf = ProvinceDefinition.load(id: 'santa_fe', provincesDir: provinces, repoRoot: repoRoot);
      expect(ba.pmtiles!.output, 'soil_polygons.pmtiles');
      expect(ba.pmtiles!.reference, endsWith(p.join('assets', 'maps', 'soil_polygons.pmtiles')));
      expect(sf.pmtiles!.output, 'santa_fe_soil_polygons.pmtiles');
      expect(decideMapInput(ba).$1!.kind, MapInputKind.source);
      expect(decideMapInput(sf).$1!.kind, MapInputKind.normalized);
      expect(decideMapInput(sf).$1!.optionalAttributes, ['PAISAJE']);
    });
  });

  group('prepare-gis decision', () {
    test('direct shapefile -> source; otherwise normalized', () {
      final root = tempDir('decide');
      final shp = _province(root, id: 'shp', format: 'shapefile', source: 'a.shp');
      final (decision, problem) = decideMapInput(shp);
      expect(problem, isNull);
      expect(decision!.kind, MapInputKind.source);
      expect(decision.file, shp.gis.source);
      expect(decision.reason, contains('fuente original'));

      final geojson = _province(root, id: 'geo');
      expect(decideMapInput(geojson).$1!.kind, MapInputKind.normalized);
      expect(decideMapInput(geojson).$1!.reason, contains('no es shapefile'));

      final remapped = _province(
        root,
        id: 'remap',
        format: 'shapefile',
        source: 'a.shp',
        mapping: identityMapping().replaceFirst('TIPO: { from: TIPO }', 'TIPO: { from: tipo_ucar }'),
      );
      expect(decideMapInput(remapped).$1!.kind, MapInputKind.normalized);
      expect(decideMapInput(remapped).$1!.reason, contains('no es directo'));
    });

    test('pmtiles.input overrides, and source requires a direct mapping', () {
      final root = tempDir('decide_override');
      final forcedNormalized = _province(
        root,
        id: 'n',
        format: 'shapefile',
        source: 'a.shp',
        pmtiles: 'pmtiles:\n  input: normalized',
      );
      expect(decideMapInput(forcedNormalized).$1!.kind, MapInputKind.normalized);

      final forcedSource = _province(root, id: 's', pmtiles: 'pmtiles:\n  input: source');
      expect(decideMapInput(forcedSource).$1!.kind, MapInputKind.source);

      final impossible = _province(
        root,
        id: 'x',
        pmtiles: 'pmtiles:\n  input: source',
        mapping: identityMapping().replaceFirst('PAISAJE: { from: PAISAJE }', 'PAISAJE: { absent: "no hay" }'),
      );
      final (decision, problem) = decideMapInput(impossible);
      expect(decision, isNull);
      expect(problem, contains('pmtiles.input: source'));
    });

    test('isDirectMapping and absentFields', () {
      expect(isDirectMapping(FieldMapping.parse({for (final f in SuelosArSchema.requiredFields) f: f})), isTrue);
      expect(
        isDirectMapping(FieldMapping.parse({for (final f in SuelosArSchema.requiredFields) f: f, 'OBJECTID': 'OBJECTID'})),
        isTrue,
      );
      expect(
        isDirectMapping(FieldMapping.parse({for (final f in SuelosArSchema.requiredFields) f: f, 'OBJECTID': 'FID'})),
        isFalse,
      );
      final mapping = FieldMapping.parse({
        for (final f in SuelosArSchema.requiredFields) f: f,
        'PAISAJE': {'absent': 'no'},
      });
      expect(isDirectMapping(mapping), isFalse);
      expect(absentFields(mapping), ['PAISAJE']);
    });

    test('writeMapInput turns blank text into null, keeps geometry and measures the extent', () async {
      final dir = tempDir('map_input');
      final normalized = File(p.join(dir.path, 'normalized.geojson'))
        ..writeAsStringSync(
          '{"type":"FeatureCollection","features":[\n'
          '{"type":"Feature","properties":{"TIPO":"","PAISAJE":"  ","SIMBC":"A","PORC1":40,"SERIE1":null},'
          '"geometry":{"type":"Polygon","coordinates":[[[-61.5,-33.25],[-61.0,-33.0],[-60.75,-32.5],[-61.5,-33.25]]]}},\n'
          '{"type":"Feature","properties":{"TIPO":"Cp","PAISAJE":"","SIMBC":"B"},"geometry":null}\n'
          ']}\n',
        );
      final output = File(p.join(dir.path, 'map_input', 'map_input.geojson'));
      final stats = await writeMapInput(normalized, output);
      expect(stats.features, 2);
      expect(stats.emptiedValues, {'TIPO': 1, 'PAISAJE': 2});
      expect(stats.extent!.toJson(), {
        'minLongitude': -61.5,
        'minLatitude': -33.25,
        'maxLongitude': -60.75,
        'maxLatitude': -32.5,
      });
      final document = jsonDecode(output.readAsStringSync()) as Map;
      final features = document['features'] as List;
      expect((features[0] as Map)['properties'], {
        'TIPO': null,
        'PAISAJE': null,
        'SIMBC': 'A',
        'PORC1': 40,
        'SERIE1': null,
      });
      expect(output.readAsStringSync(), contains('"geometry":{"type":"Polygon","coordinates":[[[-61.5,-33.25]'));
      expect((features[1] as Map)['geometry'], isNull);
      expect(normalized.readAsStringSync(), contains('"TIPO":""'), reason: 'the normalized file is untouched');
      expect(File('${output.path}.tmp').existsSync(), isFalse);
    });

    test('shapefileExtent reads the header bounding box; inputFiles lists sidecars', () {
      final dir = tempDir('extent');
      final shp = File(p.join(dir.path, 'a.shp'))..writeAsBytesSync(buildShp([[square(-61, -36, 2)]]));
      final extent = shapefileExtent(shp);
      // buildShp leaves the header box at zero: the reader returns it as is.
      expect(extent, isNotNull);
      File(p.join(dir.path, 'a.dbf')).writeAsStringSync('');
      File(p.join(dir.path, 'a.prj')).writeAsStringSync(wgs84Prj);
      final decision = MapInputDecision(
        kind: MapInputKind.source,
        reason: 'r',
        file: shp.path,
        optionalAttributes: const [],
      );
      expect(decision.inputFiles.map(p.basename).toSet(), {'a.shp', 'a.dbf', 'a.prj'});
      expect(shapefileExtent(File(p.join(dir.path, 'missing.shp'))), isNull);
    });
  });

  group('stamps', () {
    test('reuse only when fingerprint, outputs and result still match', () async {
      final dir = tempDir('stamps');
      final hasher = FileHasher();
      final store = StampStore(p.join(dir.path, 'stamps'), hasher);
      final output = File(p.join(dir.path, 'out.txt'))..writeAsStringSync('uno');
      final fingerprint = {'input': 'abc', 'config': hashJson({'a': 1})};
      StageStamp stamp({List<Finding> findings = const []}) => StageStamp(
        stage: 'map',
        fingerprint: fingerprint,
        outputs: {output.path: '0e4aa9c2ec7b3a4b4f2e7f1c1f1d6a4d0f5e0c2b1a3d4e5f6a7b8c9d0e1f2a3b'},
        data: const {'x': 1},
        findings: findings,
        extra: const {'k': 'v'},
        durationMs: 1234,
        createdAt: DateTime(2026),
      );

      expect(await store.rejectReason(null, fingerprint), 'sin huella previa');

      final good = StageStamp(
        stage: 'map',
        fingerprint: fingerprint,
        outputs: {output.path: await hasher.sha256(output)},
        data: const {'x': 1},
        findings: const [],
        extra: const {'k': 'v'},
        durationMs: 1234,
        createdAt: DateTime(2026),
      );
      store.save(good);
      final loaded = store.load('map')!;
      expect(loaded.toJson(), good.toJson());
      expect(await store.rejectReason(loaded, fingerprint), isNull);
      expect(
        await store.rejectReason(loaded, {...fingerprint, 'input': 'otro'}),
        'cambió: input',
      );
      expect(await store.rejectReason(stamp(), fingerprint), contains('fue modificada'));
      expect(
        await store.rejectReason(
          stamp(findings: const [Finding(code: 'X', severity: Severity.error, message: 'm')]),
          fingerprint,
        ),
        'la corrida anterior tuvo errores',
      );
      output.deleteSync();
      expect(await store.rejectReason(loaded, fingerprint), contains('falta la salida'));

      File(p.join(dir.path, 'stamps', 'broken.json')).writeAsStringSync('{');
      expect(store.load('broken'), isNull);
      store.delete('map');
      expect(store.load('map'), isNull);
    });

    test('FileHasher hashes content and hashJson is stable', () async {
      final dir = tempDir('hasher');
      final file = File(p.join(dir.path, 'f'))..writeAsStringSync('abc');
      final hasher = FileHasher();
      expect(
        await hasher.sha256(file),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(await hasher.sha256OrNull(File(p.join(dir.path, 'nope'))), isNull);
      expect(hashJson({'a': [1, 2]}), hashJson({'a': [1, 2]}));
      expect(hashJson({'a': [1, 2]}), isNot(hashJson({'a': [2, 1]})));
    });
  });

  group('generic optimizer', () {
    test('removes attributes outside the schema and verifies every tile', () async {
      final dir = tempDir('opt_rewrite');
      final input = writePmtiles(File(p.join(dir.path, 'full.pmtiles')), tiles: _allZooms(withExtras: true));
      final output = File(p.join(dir.path, 'out.pmtiles'));
      final report = await PmtilesOptimizer().run(input, output);
      expect(report.rewritten, isTrue);
      expect(report.attributesRemoved, {'FASE1', 'taxo_ppal'});
      expect(report.attributesKept, SuelosArSchema.requiredFields.toSet());
      expect(report.uniqueTiles, 11);
      expect(report.tilesByZoom.keys, [for (var z = 4; z <= 14; z++) z]);
      expect(report.attributesByZoom[14], SuelosArSchema.requiredFields.toSet());
      expect(report.attributeTileCounts['TIPO'], 11);
      expect(report.sizeAfter, lessThan(report.sizeBefore));
      expect(File('${output.path}.sha256').readAsStringSync(), '${report.sha256After}\n');
      expect(await sha256OfFile(output), report.sha256After);
      expect(File('${output.path}.tmp').existsSync(), isFalse);

      // The result is itself clean: optimizing it again removes nothing.
      final again = await PmtilesOptimizer().run(output, File(p.join(dir.path, 'again.pmtiles')));
      expect(again.rewritten, isFalse);
      expect(again.attributesFound, SuelosArSchema.requiredFields.toSet());

      final metadata = await PmtilesMetadata.read(output);
      expect(metadata.attributesSeen.toSet(), SuelosArSchema.requiredFields.toSet());
      expect((metadata.minZoom, metadata.maxZoom), (4, 14));
    });

    test('auto copies byte-for-byte when nothing needs removing; modes override', () async {
      final dir = tempDir('opt_copy');
      final clean = writePmtiles(File(p.join(dir.path, 'clean.pmtiles')), tiles: _allZooms());
      final copied = File(p.join(dir.path, 'copied.pmtiles'));
      final report = await PmtilesOptimizer().run(clean, copied);
      expect(report.rewritten, isFalse);
      expect(copied.readAsBytesSync(), clean.readAsBytesSync());
      expect(report.sha256After, report.sha256Before);
      expect(report.attributesRemoved, isEmpty);

      final forced = await PmtilesOptimizer().run(
        clean,
        File(p.join(dir.path, 'forced.pmtiles')),
        mode: OptimizeMode.always,
      );
      expect(forced.rewritten, isTrue);

      final dirty = writePmtiles(File(p.join(dir.path, 'dirty.pmtiles')), tiles: _allZooms(withExtras: true));
      final kept = await PmtilesOptimizer().run(
        dirty,
        File(p.join(dir.path, 'kept.pmtiles')),
        mode: OptimizeMode.never,
      );
      expect(kept.rewritten, isFalse);
      expect(kept.attributesFound, containsAll(['FASE1', 'taxo_ppal']));
    });

    test('custom keep-list, report round-trip and structural failures', () async {
      final dir = tempDir('opt_misc');
      final input = writePmtiles(File(p.join(dir.path, 'in.pmtiles')), tiles: _allZooms(withExtras: true));
      final report = await PmtilesOptimizer(keep: {'SIMBC'}).run(input, File(p.join(dir.path, 'o.pmtiles')));
      expect(report.attributesKept, {'SIMBC'});
      expect(OptimizeReport.fromJson(jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>).toJson(), report.toJson());

      final brotli = writePmtiles(File(p.join(dir.path, 'b.pmtiles')), tiles: _allZooms(), tileCompression: 3);
      expect(
        () => PmtilesOptimizer().run(brotli, File(p.join(dir.path, 'b2.pmtiles'))),
        throwsA(isA<PmtilesStructureException>()),
      );
      expect(File(p.join(dir.path, 'b2.pmtiles')).existsSync(), isFalse);
      expect(
        () => PmtilesOptimizer().run(input, input),
        throwsA(isA<PmtilesStructureException>()),
      );
    });

    test('the Buenos Aires wrapper keeps the central schema', () {
      expect(wrapper.keptAttributes, SuelosArSchema.appAttributes);
      expect(wrapper.keptAttributes.intersection(wrapper.droppedAttributes), isEmpty);
    });
  });

  group('archive checks and attribute protection', () {
    Future<(PmtilesMetadata, OptimizeReport)> archive(
      Directory dir, {
      List<String> omit = const [],
      int maxZoom = 14,
      (double, double, double, double) bounds = (-61, -36, -59, -34),
    }) async {
      final file = writePmtiles(
        File(p.join(dir.path, 'a.pmtiles')),
        tiles: _allZooms(omit: omit, maxZoom: maxZoom),
        bounds: bounds,
      );
      final out = File(p.join(dir.path, 'b.pmtiles'));
      final report = await PmtilesOptimizer().run(file, out);
      return (await PmtilesMetadata.read(out), report);
    }

    const config = PmtilesConfig(
      output: 'x.pmtiles',
      reference: null,
      layer: 'soil_polygons',
      minZoom: 4,
      maxZoom: 14,
      input: PmtilesInput.auto,
      optimize: OptimizeMode.auto,
    );

    test('a complete archive passes', () async {
      final (metadata, report) = await archive(tempDir('check_ok'));
      final findings = FindingSink();
      checkGeneratedArchive(
        metadata: metadata,
        report: report,
        config: config,
        absent: const [],
        sourceExtent: const Extent(-61, -36, -59, -34),
        findings: findings,
        location: 'x',
      );
      expect(findings.findings.map((f) => '${f.severity.label} ${f.code}'), ['INFO OPT003']);
    });

    test('a missing required field is an error unless declared absent', () async {
      final (metadata, report) = await archive(tempDir('check_missing'), omit: ['TIPO', 'PAISAJE']);
      final strict = FindingSink();
      checkGeneratedArchive(
        metadata: metadata,
        report: report,
        config: config,
        absent: const ['PAISAJE'],
        sourceExtent: null,
        findings: strict,
        location: 'x',
      );
      final opt001 = strict.findings.singleWhere((f) => f.code == 'OPT001');
      expect(opt001.severity, Severity.error);
      expect(opt001.examples, ['TIPO']);
      expect(requiredArchiveFields(['PAISAJE']), isNot(contains('PAISAJE')));
    });

    test('wrong zooms, empty zooms and bounds outside the source', () async {
      final (metadata, report) = await archive(
        tempDir('check_zooms'),
        maxZoom: 12,
        bounds: (-65, -36, -59, -30),
      );
      final findings = FindingSink();
      checkGeneratedArchive(
        metadata: metadata,
        report: report,
        config: config,
        absent: const [],
        sourceExtent: const Extent(-61, -36, -59, -34),
        findings: findings,
        location: 'x',
      );
      final codes = {for (final f in findings.findings) f.code: f};
      expect(codes['MAP001']!.examples.single, contains('zooms 4-12'));
      expect(codes['MAP002']!.examples, ['z13', 'z14']);
      expect(codes['MAP003']!.severity, Severity.warning);
      expect(codes['MAP003']!.examples, hasLength(2));
    });

    test('reference comparison and manual steps', () {
      final same = FindingSink();
      final identical = compareWithReference(
        sha256: 'a',
        sizeBytes: 1,
        referenceSha256: 'a',
        referenceSize: 1,
        referenceLocation: 'assets/x.pmtiles',
        findings: same,
      );
      expect(identical['identical'], isTrue);
      expect(same.findings.single.severity, Severity.info);

      final different = FindingSink();
      final changed = compareWithReference(
        sha256: 'a',
        sizeBytes: 1,
        referenceSha256: 'b',
        referenceSize: 2,
        referenceLocation: 'assets/x.pmtiles',
        findings: different,
      );
      expect(different.findings.single.severity, Severity.warning);
      expect(compareWithReference(sha256: 'a', sizeBytes: 1, referenceSha256: null, referenceSize: null, referenceLocation: null, findings: FindingSink()), {'declared': false});

      final d = _province(tempDir('steps'));
      expect(
        manualSteps(
          definition: d,
          publishedFile: 'output/x.pmtiles',
          reference: changed,
          app: const {'declaredByApp': true, 'appField': 'ProvinceConfig.x', 'sizeMatches': false, 'boundsMatch': true},
          sizeBytes: 99,
        ),
        [
          'Revisar y copiar `output/x.pmtiles` (y su `.sha256`) a `assets/x.pmtiles` — no se hace automáticamente.',
          'Actualizar ProvinceConfig.x.pmtilesDownloadSizeBytes a 99.',
        ],
      );
      expect(
        manualSteps(
          definition: d,
          publishedFile: 'output/x.pmtiles',
          reference: identical,
          app: const {'declaredByApp': false},
          sizeBytes: 1,
        ),
        [
          'Nada que copiar: `output/x.pmtiles` es idéntico a `assets/x.pmtiles`.',
          'Registrar la provincia en la app (ProvinceConfig / MapCoverage, Android, Windows).',
        ],
      );
    });
  });

  group('publication', () {
    Future<ProvincePipeline> prepared(Directory root, {List<String> omit = const [], String? mapping}) async {
      final d = _province(root, mapping: mapping);
      writePmtiles(File(d.fullPmtilesFile!), tiles: _allZooms(withExtras: true, omit: omit));
      final pipeline = ProvincePipeline(d, log: (_) {});
      pipeline.results.add(StageResult('map', 'map'));
      await pipeline.optimize();
      return pipeline;
    }

    test('a valid archive is published with its sidecar and metadata', () async {
      final pipeline = await prepared(tempDir('publish_ok'));
      final d = pipeline.definition;
      expect(pipeline.succeeded('optimize'), isTrue);
      await pipeline.publishMetadata();
      final stage = pipeline.result('metadata')!;
      expect(stage.hasErrors, isFalse, reason: '${stage.findings}');
      expect(stage.data['published'], isTrue);
      final published = File(d.publishedPmtilesFile!);
      expect(published.readAsBytesSync(), File(d.optimizedPmtilesFile!).readAsBytesSync());
      final sha = await sha256OfFile(published);
      expect(File('${published.path}.sha256').readAsStringSync(), '$sha\n');
      final metadata = jsonDecode(File(d.pmtilesMetadataFile).readAsStringSync()) as Map;
      expect(metadata['sha256'], sha);
      expect(metadata['sizeBytes'], published.lengthSync());
      expect(metadata['role'], 'published');
      expect(metadata['layer'], 'soil_polygons');
      expect(metadata['attributes'], SuelosArSchema.requiredFields.toList()..sort());
      expect((metadata['optimization'] as Map)['removed'], ['FASE1', 'taxo_ppal']);
      expect(stage.data['manualSteps'], contains(startsWith('Registrar la provincia')));
    });

    test('a missing required attribute blocks publication and removes stale outputs', () async {
      final pipeline = await prepared(tempDir('publish_missing'), omit: ['TIPO']);
      final d = pipeline.definition;
      File(d.publishedPmtilesFile!)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('viejo');
      File(d.pmtilesMetadataFile).writeAsStringSync('{}');
      await pipeline.publishMetadata();
      final stage = pipeline.result('metadata')!;
      expect(stage.findings.map((f) => f.code), containsAll(['OPT001', 'PUB001']));
      expect(stage.data['published'], isFalse);
      expect(File(d.publishedPmtilesFile!).existsSync(), isFalse);
      expect(File(d.pmtilesMetadataFile).existsSync(), isFalse);
    });

    test('a declared absent field does not block publication', () async {
      final pipeline = await prepared(
        tempDir('publish_absent'),
        omit: ['PAISAJE'],
        mapping: identityMapping().replaceFirst('PAISAJE: { from: PAISAJE }', 'PAISAJE: { absent: "sin datos" }'),
      );
      await pipeline.publishMetadata();
      expect(pipeline.result('metadata')!.data['published'], isTrue);
    });

    test('a failed earlier stage blocks publication', () async {
      final d = _province(tempDir('publish_failed'));
      final pipeline = ProvincePipeline(d, log: (_) {});
      File(d.publishedPmtilesFile!)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('viejo');
      pipeline.results.add(StageResult('map', 'map')..sink.error('DKR002', 'falló'));
      await pipeline.optimize();
      expect(pipeline.result('optimize')!.skipped, isTrue);
      await pipeline.publishMetadata();
      final stage = pipeline.result('metadata')!;
      expect(stage.data['published'], isFalse);
      expect(stage.data['notPublishedBecause'], contains('PMTiles (Docker)'));
      expect(File(d.publishedPmtilesFile!).existsSync(), isFalse);
    });
  });

  group('resumable stages (without Docker)', () {
    test('normalize and prepare are reused until an input changes; --force re-runs', () async {
      final root = tempDir('resume');
      final d = _province(root);
      writeGeoJsonLines(Directory(d.directory), 'gis.geojson', [
        fullProperties(series: ['Alfa'], paisaje: ''),
        fullProperties(simbc: 'U2', series: ['Beta']),
      ]);
      Future<ProvincePipeline> run({RunOptions options = const RunOptions(until: 'prepare')}) async {
        final pipeline = ProvincePipeline(d, options: options, log: (_) {});
        await pipeline.runBuild();
        return pipeline;
      }

      final first = await run();
      expect(first.result('normalize')!.reused, isFalse);
      expect(first.result('prepare')!.reused, isFalse);
      expect(first.result('prepare')!.data['route'], 'normalized');
      expect(first.result('prepare')!.data['emptiedValues'], {'PAISAJE': 1});
      expect(File(d.mapInputFile).existsSync(), isTrue);
      expect(first.result('map'), isNull, reason: '--until prepare');

      final second = await run();
      expect(second.result('normalize')!.reused, isTrue);
      expect(second.result('prepare')!.reused, isTrue);
      expect(second.mapInput!.kind, MapInputKind.normalized);
      expect(second.sourceExtent, isNotNull);
      expect(second.normalizeResult!.featureCount, 2);

      File(d.mapInputFile).writeAsStringSync('modificado');
      final third = await run();
      expect(third.result('normalize')!.reused, isTrue);
      expect(third.result('prepare')!.reused, isFalse);
      expect(third.result('prepare')!.data['runReason'], contains('fue modificada'));

      final forced = await run(options: const RunOptions(force: true, until: 'prepare'));
      expect(forced.result('normalize')!.reused, isFalse);
      expect(forced.result('normalize')!.data['runReason'], contains('--force'));

      final from = await run(options: const RunOptions(from: 'prepare', until: 'prepare'));
      expect(from.result('normalize')!.reused, isTrue);
      expect(from.result('prepare')!.reused, isFalse);

      writeGeoJsonLines(Directory(d.directory), 'gis.geojson', [fullProperties(series: ['Alfa'])]);
      final changed = await run();
      expect(changed.result('normalize')!.reused, isFalse);
      expect(changed.result('normalize')!.data['runReason'], contains('sources'));
      expect(changed.result('prepare')!.reused, isFalse);
    });
  });

  group('docker interface (no Docker needed)', () {
    test('runArguments mounts the input read-only and writes only to the output dir', () {
      final builder = DockerMapBuilder(repoRoot: repoRoot, image: 'img:tag');
      final args = builder.runArguments(
        inputFile: p.join(repoRoot, 'data', 'x', 'work', 'map_input', 'map_input.geojson'),
        outputDir: p.join(repoRoot, 'data', 'x', 'work', 'pmtiles'),
        outputName: 'x.full.pmtiles',
        environment: const {'MIN_ZOOM': '4', 'OPTIONAL_ATTRIBUTES': 'PAISAJE'},
      );
      expect(args.first, 'run');
      expect(args.last, 'img:tag');
      expect(args, contains('type=bind,source=${p.join(repoRoot, 'data', 'x', 'work', 'map_input')},target=/data/input,readonly'));
      expect(args, contains('type=bind,source=${p.join(repoRoot, 'data', 'x', 'work', 'pmtiles')},target=/data/output'));
      expect(args, containsAll(['SOURCE_SHAPEFILE=map_input.geojson', 'OUTPUT_NAME=x.full.pmtiles', 'MIN_ZOOM=4', 'OPTIONAL_ATTRIBUTES=PAISAJE']));
      expect(args.join(' '), isNot(contains('compose')));
      expect(args.join(' '), isNot(contains('assets')));
    });

    test('the scripts hash ignores line endings and changes with content', () {
      final root = tempDir('scripts');
      Directory(p.join(root.path, 'docker')).createSync();
      File(p.join(root.path, 'tool', 'suelosar_data.dart'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
      for (final name in dockerScriptFiles) {
        File(p.join(root.path, 'docker', name)).writeAsStringSync('a\nb\n');
      }
      final lf = dockerScriptsHash(root.path);
      File(p.join(root.path, 'docker', 'build_map.sh')).writeAsStringSync('a\r\nb\r\n');
      expect(dockerScriptsHash(root.path), lf);
      File(p.join(root.path, 'docker', 'validate_map.py')).writeAsStringSync('c\n');
      expect(dockerScriptsHash(root.path), isNot(lf));
      expect(dockerScriptsHash(repoRoot), hasLength(64));
    });
  });

  group('CLI (Phase 2)', () {
    test('build flags, map --dry-run and standalone optimize', () async {
      final root = tempDir('cli2');
      final d = _province(root);
      writeGeoJsonLines(Directory(d.directory), 'gis.geojson', [fullProperties(series: ['Alfa'])]);
      final args = ['--provinces-dir', root.path];

      expect(await runSuelosArData([...args, 'build', 'mini', '--from', 'map', '--until', 'prepare']), 2);
      expect(await runSuelosArData([...args, 'build', 'mini', '--from', 'nada']), 2);
      expect(await runSuelosArData([...args, 'build', 'mini', '--until', 'prepare']), 0);
      expect(await runSuelosArData([...args, 'prepare-gis', 'mini']), 0);

      expect(await runSuelosArData([...args, 'map', 'mini', '--dry-run']), 0);
      final stages = jsonDecode(File(p.join(d.outputDir, 'report.json')).readAsStringSync()) as Map;
      final mapTiming = ((stages['timings'] as Map)['stages'] as List).cast<Map>().where((s) => s['stage'] == 'map');
      expect(mapTiming, isEmpty, reason: 'the dry run is not persisted');
      expect(File(d.fullPmtilesFile!).existsSync(), isFalse);

      final input = writePmtiles(File(p.join(root.path, 'in.pmtiles')), tiles: _allZooms(withExtras: true));
      final out = p.join(root.path, 'out', 'o.pmtiles');
      expect(await runSuelosArData(['optimize', '--input', input.path, '--output', out]), 0);
      expect(File('$out.sha256').existsSync(), isTrue);
      expect(await runSuelosArData(['optimize', '--input', input.path]), 2);
      expect(await runSuelosArData(['optimize', '--input', p.join(root.path, 'x.pmtiles'), '--output', out]), 2);
    });
  });
}
