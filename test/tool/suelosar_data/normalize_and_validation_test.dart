import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/suelosar_data/config/province_definition.dart';
import '../../../tool/suelosar_data/normalize/normalizer.dart';
import '../../../tool/suelosar_data/validation/cross_reference.dart';
import '../../../tool/suelosar_data/validation/finding.dart';
import '../../../tool/suelosar_data/validation/gis_checks.dart';
import 'helpers.dart';

/// A Santa-Fe-shaped province over a synthetic GeoJSON source.
ProvinceDefinition _province(
  Directory root, {
  String extraMapping = '',
  String series = '',
  String thresholds = '',
}) {
  writeProvince(root, 'sf_like', '''
id: sf_like
name: Parecida a Santa Fe
gis:
  source: source/data.geojson
  format: geojson_lines
  mapping:
    TIPO:      { from: tipo_ucar, empty: "" }
    Nombre_UC: { derive: dominant_series_name, empty: "" }
    SIMBC:     { from: ucar, empty: "" }
    CAP_USO:   { from: gat, empty: "" }
    PAISAJE:   { absent: "no existe", value: "" }
    "SERIE{n}": { from: "comp{n}", n: [1, 6] }
    "PORC{n}":  { from: "comp{n}_porc", n: [1, 6] }
$extraMapping
  series:
    code_rule: first_token
    match: case_insensitive
    $series
  thresholds:
    warn_below: 90
    error_below: 50
    $thresholds
''');
  return ProvinceDefinition.load(
    id: 'sf_like',
    provincesDir: root.path,
    repoRoot: repoRoot,
  );
}

Map<String, Object?> _sf({
  String? ucar = 'MLA-04',
  String? tipo = 'Cp',
  String? gat = '3ws',
  List<Object?> comps = const [],
}) => {
  'ucar': ucar,
  'tipo_ucar': tipo,
  'gat': gat,
  for (var i = 0; i < comps.length; i += 2) ...{
    'comp${i ~/ 2 + 1}': comps[i],
    'comp${i ~/ 2 + 1}_porc': comps[i + 1],
  },
};

void main() {
  group('Normalizer', () {
    test('maps like remap_santa_fe.mjs and preserves geometry text', () async {
      final root = tempDir('normalize');
      final definition = _province(root);
      Directory(p.join(definition.directory, 'source')).createSync();
      final source = writeGeoJsonLines(
        Directory(p.join(definition.directory, 'source')),
        'data.geojson',
        [
          _sf(comps: ['MLA cc', 40, 'PEA cc', 60]),
          _sf(
            ucar: null,
            tipo: null,
            gat: null,
            comps: ['ZZZ cc', null, 'mla As', null],
          ),
          _sf(tipo: '  ', comps: []),
        ],
      );
      expect(source.existsSync(), isTrue);
      final normalizer = Normalizer(
        definition,
        seriesNames: {'mla': 'María Luisa', 'pea': 'Pearson'},
        catalogKeys: {'mla', 'pea'},
      );
      final output = File(definition.normalizedGisFile);
      final result = await normalizer.run(output: output);

      final lines = output
          .readAsLinesSync()
          .where((l) => l.contains('"type":"Feature"'))
          .toList();
      final features = [
        for (final l in lines)
          jsonDecode(l.replaceFirst(RegExp(r',$'), '')) as Map,
      ];
      expect(features[0]['properties'], {
        'TIPO': 'Cp',
        'Nombre_UC': 'Pearson',
        'SIMBC': 'MLA-04',
        'CAP_USO': '3ws',
        'PAISAJE': '',
        'SERIE1': 'MLA cc',
        'SERIE2': 'PEA cc',
        'SERIE3': null,
        'SERIE4': null,
        'SERIE5': null,
        'SERIE6': null,
        'PORC1': 40,
        'PORC2': 60,
        'PORC3': null,
        'PORC4': null,
        'PORC5': null,
        'PORC6': null,
      });
      // No percentages: first component wins; its code is looked up ignoring case.
      expect((features[1]['properties'] as Map)['Nombre_UC'], '');
      expect((features[1]['properties'] as Map)['TIPO'], '');
      expect((features[2]['properties'] as Map)['TIPO'], '  ');
      expect(
        lines[0],
        endsWith(
          '"geometry":{"type":"Polygon","coordinates":[[[-60.0,-35.5],[-60.0,-35.0],[-59.5,-35.0],[-60.0,-35.5]]]}},',
        ),
      );
      expect(jsonDecode(output.readAsStringSync())['features'], hasLength(3));

      expect(result.featureCount, 3);
      expect(result.nullGeometries, 0);
      expect(result.targetProfiles['TIPO']!.filled, 1);
      expect(result.targetProfiles['TIPO']!.whitespaceOnly, 1);
      expect(result.targetProfiles['Nombre_UC']!.filled, 1);
      expect(result.seriesFeatureCounts, {'mla': 2, 'pea': 1, 'zzz': 1});
      expect(result.seriesVariants['mla'], {'MLA', 'mla'});
      expect(result.featuresWithSeries, 2);
      expect(result.featuresWithUncataloguedSeries, 1);
      expect(result.sourceProfiles['comp3'], isNull);
      expect(result.sourceProfiles['ucar']!.empty, 1);
    });

    test('applies aliases before looking a series up', () {
      final definition = _province(
        tempDir('alias'),
        series: 'aliases: { ZZZ: mla }',
      );
      final normalizer = Normalizer(
        definition,
        seriesNames: {'mla': 'María Luisa'},
      );
      expect(
        normalizer.apply(_sf(comps: ['ZZZ cc', 10]))['Nombre_UC'],
        'María Luisa',
      );
      expect(normalizer.seriesKey('ZZZ'), 'mla');
      expect(normalizer.matchKey('ZZZ'), 'zzz');
    });

    test('detects undecodable and double-encoded text', () async {
      final root = tempDir('encoding');
      final definition = _province(root);
      final dir = Directory(p.join(definition.directory, 'source'))
        ..createSync();
      writeGeoJsonLines(dir, 'data.geojson', [
        _sf(ucar: 'CaÃ±ada'),
        _sf(tipo: 'bad \uFFFD'),
      ]);
      final result = await Normalizer(definition).run();
      expect(result.encodingIssues.map((i) => (i.field, i.suspected)), [
        ('ucar', true),
        ('tipo_ucar', false),
      ]);
      final findings = FindingSink();
      checkGis(definition, result, findings);
      final src = findings.findings.where((f) => f.code == 'SRC003').toList();
      expect(
        src.map((f) => f.severity),
        containsAll([Severity.error, Severity.warning]),
      );
    });
  });

  group('checkGis', () {
    test(
      'missing columns, thresholds, absent-with-data and non-numeric percentages',
      () async {
        final root = tempDir('checks');
        final definition = _province(root, extraMapping: '');
        final dir = Directory(p.join(definition.directory, 'source'))
          ..createSync();
        writeGeoJsonLines(dir, 'data.geojson', [
          {
            'ucar': 'A',
            'TIPO_UCAR': 'x',
            'gat': null,
            'PAISAJE': 'Lomas',
            'comp1': 'AA cc',
            'comp1_porc': 'cuarenta',
          },
          {'ucar': 'B', 'gat': '2w', 'comp1': 'AA cc', 'comp1_porc': 10},
          {'ucar': 'C', 'gat': null},
        ]);
        final result = await Normalizer(
          definition,
          seriesNames: {'aa': 'Alfa'},
        ).run();
        final findings = FindingSink();
        checkGis(definition, result, findings);
        String message(String code, Severity severity) => [
          for (final f in findings.findings)
            if (f.code == code && f.severity == severity) f.message,
        ].join(' | ');
        expect(
          message('GIS001', Severity.error),
          contains('¿quisiste decir "TIPO_UCAR"?'),
        );
        expect(message('GIS002', Severity.error), contains('CAP_USO'));
        expect(message('GIS002', Severity.warning), contains('SERIE1'));
        expect(message('GIS007', Severity.warning), contains('PAISAJE'));
        expect(message('GIS004', Severity.warning), contains('PORC1'));
        expect(
          findings.findings.where(
            (f) => f.code == 'GIS002' && f.message.startsWith('TIPO'),
          ),
          isEmpty,
          reason: 'a missing column is reported once, as GIS001',
        );
      },
    );

    test(
      'CFG002 for undeclared schema fields and GIS005 for an empty source',
      () async {
        final root = tempDir('cfg002');
        writeProvince(root, 'tiny', '''
id: tiny
name: Tiny
gis:
  source: data.geojson
  format: geojson_lines
  mapping:
    SIMBC: ucar
''');
        final definition = ProvinceDefinition.load(
          id: 'tiny',
          provincesDir: root.path,
          repoRoot: repoRoot,
        );
        writeGeoJsonLines(Directory(definition.directory), 'data.geojson', []);
        final result = await Normalizer(definition).run();
        final findings = FindingSink();
        checkGis(definition, result, findings);
        expect(findings.findings.map((f) => f.code), ['CFG002', 'GIS005']);
        expect(findings.findings.first.count, 16);
        expect(findings.findings.first.examples, hasLength(12));
      },
    );
  });

  group('checkCrossReference', () {
    Future<NormalizeResult> run(
      ProvinceDefinition definition,
      Set<String> catalog,
    ) async {
      final dir = Directory(p.join(definition.directory, 'source'))
        ..createSync();
      writeGeoJsonLines(dir, 'data.geojson', [
        _sf(comps: ['AA cc', 50, 'BB cc', 50]),
        _sf(comps: ['bb cc', 50]),
        _sf(comps: ['CC cc', 50]),
        _sf(comps: ['CC cc', 50]),
      ]);
      return Normalizer(definition, catalogKeys: catalog).run();
    }

    test(
      'XRF001 is a warning up to the threshold and an error above it',
      () async {
        final definition = _province(tempDir('xref_warn'));
        final gis = await run(definition, {'aa', 'bb'});
        expect(gis.featuresWithUncataloguedSeries, 2);
        const catalog = CatalogKeys(
          keys: {'aa', 'bb', 'dd'},
          labels: {'aa': 'AA', 'bb': 'BB', 'dd': 'DD'},
          kind: 'series del índice',
        );

        final atThreshold = FindingSink();
        final data = checkCrossReference(definition, gis, catalog, atThreshold);
        final xrf001 = atThreshold.findings.firstWhere(
          (f) => f.code == 'XRF001',
        );
        expect(
          xrf001.severity,
          Severity.warning,
          reason: '2 of 4 features = 50 %, not above 50 %',
        );
        expect(xrf001.examples, ['CC (2 features)']);
        expect(data['gisSeriesWithoutCatalog'], 1);
        expect(data['featuresWithUncataloguedSeriesPercent'], 50.0);
        expect(
          atThreshold.findings.firstWhere((f) => f.code == 'XRF002').examples,
          ['DD'],
        );
        expect(
          atThreshold.findings
              .firstWhere((f) => f.code == 'XRF003')
              .examples
              .single,
          'bb (GIS) = BB (catálogo)',
        );

        final strictRoot = tempDir('xref_error');
        writeProvince(
          strictRoot,
          'sf_like',
          File(definition.configFile).readAsStringSync().replaceFirst(
            'name: Parecida a Santa Fe',
            'name: Parecida a Santa Fe\nxref: { error_above_percent: 40 }',
          ),
        );
        final strict = ProvinceDefinition.load(
          id: 'sf_like',
          provincesDir: strictRoot.path,
          repoRoot: repoRoot,
        );
        final above = FindingSink();
        checkCrossReference(strict, gis, catalog, above);
        expect(
          above.findings.firstWhere((f) => f.code == 'XRF001').severity,
          Severity.error,
        );
      },
    );
  });
}
