import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/suelosar_data/cli/pipeline.dart';
import '../../../tool/suelosar_data/cli/runner.dart';
import '../../../tool/suelosar_data/config/province_definition.dart';
import '../../../tool/suelosar_data/normalize/field_mapping.dart';
import '../../../tool/suelosar_data/pmtiles/app_declarations.dart';
import '../../../tool/suelosar_data/pmtiles/pmtiles_checks.dart';
import '../../../tool/suelosar_data/pmtiles/pmtiles_metadata.dart';
import '../../../tool/suelosar_data/report/report_writer.dart';
import '../../../tool/suelosar_data/validation/finding.dart';
import 'helpers.dart';

PmtilesMetadata _metadata({
  int size = 100,
  String sha = 'aa',
  String? sidecar = 'aa',
  List<String> attributes = const [],
}) => PmtilesMetadata(
  file: 'x.pmtiles',
  sizeBytes: size,
  sha256: sha,
  sidecarSha256: sidecar,
  version: 3,
  tileType: 'mvt',
  minZoom: 4,
  maxZoom: 14,
  bounds: const GeoBoundsValue(
    minLatitude: -39,
    maxLatitude: -33,
    minLongitude: -63,
    maxLongitude: -56,
  ),
  centerLatitude: -36,
  centerLongitude: -60,
  centerZoom: 14,
  layers: const ['soil_polygons'],
  attributesSeen: attributes,
  sampledTiles: 10,
);

const _assetPaths = """
class AssetPaths {
  static const String gisPmTiles = 'assets/maps/soil_polygons.pmtiles';
  static const String otherPmTiles =
      'assets/maps/other.pmtiles';
}
""";

const _provinceConfig = """
class ProvinceConfig {
  static final ProvinceConfig first = ProvinceConfig(
    id: 'first',
    pmtilesAsset: AssetPaths.gisPmTiles,
    // a comment with (parentheses) and 'quotes'
    pmtilesDownloadSizeBytes: 158_646_380,
  );
  static final ProvinceConfig second = _buildSecond();
  static ProvinceConfig _buildSecond() {
    final x = Something();
    return ProvinceConfig(
      id: 'second',
      pmtilesAsset: AssetPaths.otherPmTiles,
    );
  }
}
""";

const _mapCoverage = """
class MapCoverage {
  static final MapCoverage first = MapCoverage(
    config: ProvinceConfig.first,
    bounds: const GeoBounds(
      minLatitude: -39,
      maxLatitude: -33,
      minLongitude: -63.5,
      maxLongitude: -56,
    ),
  );
}
""";

void main() {
  group('AppDeclarations', () {
    test('parses direct and builder-based province configs', () {
      final app = AppDeclarations.parse(
        assetPaths: stripDartComments(_assetPaths),
        provinceConfig: stripDartComments(_provinceConfig),
        mapCoverage: stripDartComments(_mapCoverage),
      );
      final first = app.forAsset('assets/maps/soil_polygons.pmtiles')!;
      expect(first.field, 'first');
      expect(first.id, 'first');
      expect(first.downloadSizeBytes, 158646380);
      expect(first.bounds!.minLongitude, -63.5);
      final second = app.forAsset('assets/maps/other.pmtiles')!;
      expect(second.id, 'second');
      expect(second.downloadSizeBytes, isNull);
      expect(second.bounds, isNull);
      expect(app.forAsset('nope'), isNull);
    });

    test('reads the real app sources', () {
      final app = AppDeclarations.read(repoRoot);
      final ba = app.forAsset('assets/maps/soil_polygons.pmtiles')!;
      expect(ba.id, 'buenos_aires');
      expect(ba.downloadSizeBytes, isNotNull);
      expect(ba.bounds, isNotNull);
      final sf = app.forAsset('assets/maps/santa_fe_soil_polygons.pmtiles')!;
      expect(sf.id, 'santa_fe');
      expect(sf.bounds!.maxLatitude, closeTo(-27.994401, 1e-9));
    });

    test('stripDartComments keeps strings that look like comments', () {
      expect(
        stripDartComments("a('//x') // y\nb /* c */ d"),
        "a('//x') \nb  d",
      );
    });
  });

  group('checkPmtiles', () {
    final app = AppDeclarations.parse(
      assetPaths: _assetPaths,
      provinceConfig: stripDartComments(_provinceConfig),
      mapCoverage: _mapCoverage,
    );

    test(
      'size drift, bounds drift, sidecar mismatch and missing attributes',
      () {
        final findings = FindingSink();
        final comparison = checkPmtiles(
          metadata: _metadata(
            size: 171770615,
            sidecar: 'bb',
            attributes: ['SIMBC'],
          ),
          assetPath: 'assets/maps/soil_polygons.pmtiles',
          app: app,
          expectedAttributes: ['SIMBC', 'TIPO'],
          layer: 'soil_polygons',
          findings: findings,
        );
        final byCode = {
          for (final f in findings.findings)
            '${f.code}:${f.severity.label}:${f.message.substring(0, 12)}': f,
        };
        expect(
          byCode.keys.where((k) => k.startsWith('PMT001:ERROR')),
          hasLength(1),
        );
        expect(
          byCode.keys.where((k) => k.startsWith('PMT003:ERROR')),
          hasLength(1),
        );
        expect(
          findings.findings
              .where((f) => f.code == 'PMT002')
              .map((f) => f.message)
              .join(),
          allOf(
            contains('desactualizado'),
            contains('158646380'),
            contains('171770615'),
            contains('bounds distintos'),
          ),
        );
        expect(comparison['sizeMatches'], isFalse);
        expect(comparison['boundsMatch'], isFalse);
      },
    );

    test('everything consistent, or an archive the app does not use yet', () {
      final ok = FindingSink();
      checkPmtiles(
        metadata: _metadata(size: 158646380, attributes: ['SIMBC']),
        assetPath: 'assets/maps/soil_polygons.pmtiles',
        app: AppDeclarations.parse(
          assetPaths: _assetPaths,
          provinceConfig: stripDartComments(_provinceConfig),
          mapCoverage: _mapCoverage.replaceFirst('-63.5', '-63'),
        ),
        expectedAttributes: ['SIMBC'],
        layer: 'soil_polygons',
        findings: ok,
      );
      expect(ok.findings, isEmpty);

      final unused = FindingSink();
      checkPmtiles(
        metadata: _metadata(sidecar: null),
        assetPath: 'assets/maps/nueva.pmtiles',
        app: app,
        expectedAttributes: const [],
        layer: 'otra_capa',
        findings: unused,
      );
      expect(unused.findings.map((f) => '${f.code} ${f.severity.label}'), [
        'PMT001 WARNING',
        'PMT003 ERROR',
        'PMT002 INFO',
      ]);
    });

    test('expectedArchiveAttributes skips absent fields', () {
      final mapping = FieldMapping.parse({
        'SIMBC': 'a',
        'PAISAJE': {'absent': 'no'},
        'TIPO': 'b',
      });
      expect(
        expectedArchiveAttributes(mapping, [
          'SIMBC',
          'PAISAJE',
          'TIPO',
          'CAP_USO',
        ]),
        ['SIMBC', 'TIPO'],
      );
    });

    test('reads the real Buenos Aires archive', () async {
      final file = File('assets/maps/soil_polygons.pmtiles');
      if (!file.existsSync()) {
        markTestSkipped(
          'PMTiles de Buenos Aires no disponible (está en .gitignore)',
        );
        return;
      }
      final metadata = await PmtilesMetadata.read(file);
      expect(metadata.sizeBytes, file.lengthSync());
      expect(
        metadata.sha256,
        File('${file.path}.sha256').readAsStringSync().trim(),
      );
      expect(metadata.sidecarMatches, isTrue);
      expect(metadata.minZoom, 4);
      expect(metadata.maxZoom, 14);
      expect(metadata.bounds.minLatitude, closeTo(-39.000509, 1e-6));
      expect(metadata.bounds.maxLongitude, closeTo(-56.656494, 1e-6));
      expect(metadata.centerLatitude, closeTo(-38.865374, 1e-6));
      expect(
        metadata.attributesSeen,
        containsAll(['TIPO', 'PAISAJE', 'SIMBC']),
      );
      expect(
        metadata.toJson()['sizeMiB'],
        closeTo(metadata.sizeBytes / 1048576, 0.01),
      );
    });
  });

  group('report', () {
    test('writes report.md and report.json from persisted stages', () {
      final root = tempDir('report');
      writeProvince(root, 'r', '''
id: r
name: Reporte
gis:
  source: a.geojson
  format: geojson_lines
  mapping:
${identityMapping()}
''');
      final definition = ProvinceDefinition.load(
        id: 'r',
        provincesDir: root.path,
        repoRoot: repoRoot,
      );
      final stage = StageResult('pmtiles', 'PMTiles')
        ..durationMs = 1234
        ..sink.warning(
          'PMT002',
          'desactualizado',
          examples: ['a', 'b'],
          count: 5,
        )
        ..sink.info('PMT000', 'info');
      Directory(definition.stagesDir).createSync(recursive: true);
      File(
        p.join(definition.stagesDir, 'pmtiles.json'),
      ).writeAsStringSync(jsonEncode(stage.toJson()));

      final report = writeReport(definition, totalMs: 2000);
      expect(report.summary.status, ReportStatus.readyWithWarnings);
      final json = jsonDecode(File(report.json).readAsStringSync()) as Map;
      expect(json['result'], containsPair('warnings', 1));
      expect(json['timings'], containsPair('stagesTotalMs', 1234));
      expect(json['timings'], containsPair('commandTotalMs', 2000));
      expect(
        (json['findings'] as List).first,
        containsPair('stage', 'pmtiles'),
      );
      final md = File(report.markdown).readAsStringSync();
      expect(md, contains('INTEGRABLE CON ADVERTENCIAS'));
      expect(md, contains('**WARNING PMT002**'));
      expect(md, contains('… y 3 más'));
      expect(md, contains('| PMTiles | 1.23 s |'));
      expect(md, contains('**Total del comando** | **2.00 s**'));

      expect(
        writeReport(definition, strict: true).summary.status,
        ReportStatus.notReady,
      );
    });

    test('summarize maps severities to a status', () {
      Finding f(Severity s) => Finding(code: 'X', severity: s, message: 'm');
      expect(summarize([f(Severity.info)]).status, ReportStatus.ready);
      expect(
        summarize([f(Severity.warning)]).status,
        ReportStatus.readyWithWarnings,
      );
      expect(
        summarize([f(Severity.error), f(Severity.warning)]).status,
        ReportStatus.notReady,
      );
    });
  });

  group('CLI exit codes', () {
    Future<int> cli(List<String> args) => runSuelosArData(args);

    test('usage and configuration problems exit with 2', () async {
      final root = tempDir('cli_usage').path;
      expect(await cli(['nope']), 2);
      expect(await cli(['validate']), 2);
      expect(await cli(['validate', 'Bad-Id']), 2);
      expect(await cli(['--provinces-dir', root, 'validate', 'missing']), 2);
      expect(await cli(['--provinces-dir', root, 'report', 'missing']), 2);
      expect(await cli(['metadata']), 2);
      expect(await cli(['metadata', 'no/existe.pmtiles']), 2);
    });

    test(
      'init creates a province once; its template does not pass validation',
      () async {
        final root = tempDir('cli_init').path;
        expect(await cli(['--provinces-dir', root, 'init', 'cordoba']), 0);
        final dir = p.join(root, 'cordoba');
        for (final sub in ['source/gis', 'source/pdf', 'work', 'output']) {
          expect(Directory(p.join(dir, sub)).existsSync(), isTrue, reason: sub);
        }
        expect(
          File(p.join(dir, 'province.yaml')).readAsStringSync(),
          contains('id: cordoba'),
        );
        expect(await cli(['--provinces-dir', root, 'init', 'cordoba']), 2);
        // The template is valid YAML, but its placeholders point at data that
        // does not exist yet, so validation reports errors.
        expect(await cli(['--provinces-dir', root, 'validate', 'cordoba']), 1);
      },
    );

    test(
      'a clean synthetic province exits 0; errors exit 1; --strict turns warnings into failures',
      () async {
        final root = tempDir('cli_run');
        final province = Directory(p.join(root.path, 'mini'))..createSync();
        writeGeoJsonLines(province, 'gis.geojson', [
          fullProperties(series: ['Alfa']),
          fullProperties(simbc: 'U2', series: ['Beta'], paisaje: null),
        ]);
        final pdfs = Directory(p.join(province.path, 'pdf'))..createSync();
        File(p.join(pdfs.path, 'Alfa.pdf')).writeAsStringSync('%PDF-1.4');
        File(p.join(pdfs.path, 'Beta.pdf')).writeAsStringSync('%PDF-1.4');
        String yaml({String warn = '40'}) =>
            '''
id: mini
name: Mini
gis:
  source: gis.geojson
  format: geojson_lines
  mapping:
${identityMapping()}
  thresholds: { warn_below: $warn, error_below: 10 }
pdf:
  model: per_series
  directory: pdf
catalog:
  output: catalog.json
''';
        File(p.join(province.path, 'province.yaml')).writeAsStringSync(yaml());
        final args = ['--provinces-dir', root.path];

        expect(await cli([...args, 'validate', 'mini']), 0);
        expect(
          File(p.join(province.path, 'output', 'report.md')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(province.path, 'output', 'report.json')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(province.path, 'output', 'catalog.json')).existsSync(),
          isFalse,
          reason: 'validate writes no artifacts',
        );

        expect(await cli([...args, 'build', 'mini']), 0);
        expect(
          jsonDecode(
            File(
              p.join(province.path, 'output', 'catalog.json'),
            ).readAsStringSync(),
          ),
          hasLength(2),
        );
        expect(
          File(
            p.join(province.path, 'work', 'normalized.geojson'),
          ).existsSync(),
          isTrue,
        );
        final report =
            jsonDecode(
                  File(
                    p.join(province.path, 'output', 'report.json'),
                  ).readAsStringSync(),
                )
                as Map;
        expect((report['timings'] as Map)['stages'], hasLength(5));
        expect(await cli([...args, 'report', 'mini']), 0);

        // PAISAJE is 50 % filled: a warning at 90 %, fine by default...
        File(
          p.join(province.path, 'province.yaml'),
        ).writeAsStringSync(yaml(warn: '90'));
        expect(await cli([...args, 'validate', 'mini']), 0);
        // ...but not in strict mode.
        expect(await cli([...args, 'validate', 'mini', '--strict']), 1);

        // A duplicate PDF (same series once normalized) is an error. Windows
        // file names ignore case, so the duplicate differs by an accent.
        File(p.join(pdfs.path, 'Álfa.pdf')).writeAsStringSync('%PDF-1.4');
        expect(await cli([...args, 'validate', 'mini']), 1);
        expect(await cli([...args, 'catalog', 'mini']), 1);
        expect(await cli([...args, 'normalize', 'mini']), 0);
      },
    );
  });
}
