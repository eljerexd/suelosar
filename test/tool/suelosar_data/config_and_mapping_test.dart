import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/suelosar_data/config/paths.dart';
import '../../../tool/suelosar_data/config/province_definition.dart';
import '../../../tool/suelosar_data/normalize/field_mapping.dart';
import 'helpers.dart';

void main() {
  group('FieldMapping.parse', () {
    test(
      'expands patterns, keeps declaration order and reads empty values',
      () {
        final mapping = FieldMapping.parse({
          'TIPO': {'from': 'tipo_ucar', 'empty': ''},
          'SIMBC': 'ucar',
          'PAISAJE': {'absent': 'sin fuente'},
          'Nombre_UC': {'derive': 'dominant_series_name'},
          'SERIE{n}': {
            'from': 'comp{n}',
            'n': [1, 2],
          },
        });
        expect(mapping.targets, [
          'TIPO',
          'SIMBC',
          'PAISAJE',
          'Nombre_UC',
          'SERIE1',
          'SERIE2',
        ]);
        final tipo = mapping.ruleFor('TIPO')! as CopyRule;
        expect(tipo.source, 'tipo_ucar');
        expect(tipo.emptyValue, '');
        expect((mapping.ruleFor('SIMBC')! as CopyRule).emptyValue, isNull);
        expect((mapping.ruleFor('PAISAJE')! as AbsentRule).value, '');
        expect((mapping.ruleFor('SERIE2')! as CopyRule).source, 'comp2');
        expect(
          mapping.sourceColumns.keys,
          containsAll(['tipo_ucar', 'ucar', 'comp1', 'comp2']),
        );
        expect(mapping.usesDerivations, isTrue);
        expect(
          mapping.missingRequiredTargets,
          containsAll(['CAP_USO', 'SERIE3', 'PORC1']),
        );
      },
    );

    for (final (label, node, fragment)
        in <(String, Map<String, Object?>, String)>[
          ('unknown target', {'FOO': 'bar'}, 'no es un campo del esquema'),
          (
            'two rule kinds',
            {
              'TIPO': {'from': 'a', 'absent': 'b'},
            },
            'exactamente una',
          ),
          (
            'pattern without n',
            {
              'SERIE{n}': {'from': 'c{n}'},
            },
            '{n}',
          ),
          (
            'n without pattern',
            {
              'TIPO': {
                'from': 'a',
                'n': [1, 2],
              },
            },
            '{n}',
          ),
          (
            'source without {n}',
            {
              'SERIE{n}': {
                'from': 'c',
                'n': [1, 2],
              },
            },
            'debe usar {n}',
          ),
          (
            'bad range',
            {
              'SERIE{n}': {
                'from': 'c{n}',
                'n': [3, 1],
              },
            },
            '"n"',
          ),
          (
            'absent without reason',
            {
              'PAISAJE': {'absent': ''},
            },
            'motivo',
          ),
          (
            'unknown derivation',
            {
              'Nombre_UC': {'derive': 'magic'},
            },
            'derivación desconocida',
          ),
          (
            'unknown key',
            {
              'TIPO': {'from': 'a', 'defualt': ''},
            },
            'claves desconocidas',
          ),
          (
            'duplicate target',
            {
              'SERIE1': 'x',
              'SERIE{n}': {
                'from': 'c{n}',
                'n': [1, 2],
              },
            },
            'más de una vez',
          ),
        ]) {
      test('rejects $label', () {
        expect(
          () => FieldMapping.parse(node),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(fragment),
            ),
          ),
        );
      });
    }
  });

  group('resolveConfigPath', () {
    test('expands REPO, PROVINCE and environment variables', () {
      final base = p.join('C:', 'data', 'x');
      expect(
        resolveConfigPath(
          r'${REPO}/assets/a.json',
          baseDir: base,
          repoRoot: '/repo',
          environment: {},
        ),
        p.normalize('/repo/assets/a.json'),
      );
      expect(
        resolveConfigPath(
          r'${HOME_DIR}/f.shp',
          baseDir: base,
          repoRoot: '/r',
          environment: {'home_dir': '/h'},
        ),
        p.normalize('/h/f.shp'),
      );
      expect(
        resolveConfigPath(
          'source/gis/a.shp',
          baseDir: base,
          repoRoot: '/r',
          environment: {},
        ),
        p.normalize(p.join(base, 'source/gis/a.shp')),
      );
      expect(
        () => resolveConfigPath(
          r'${MISSING}/a',
          baseDir: base,
          repoRoot: '/r',
          environment: {},
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('ProvinceDefinition.load', () {
    test('loads a complete definition', () {
      final root = tempDir('config');
      writeProvince(root, 'test_prov', '''
id: test_prov
name: Provincia de Prueba
gis:
  source: source/gis/a.geojson
  format: geojson_lines
  mapping:
${identityMapping()}
  series: { code_rule: first_token, match: case_insensitive, aliases: { AVE1: ave } }
  thresholds: { warn_below: 80, error_below: 40, fields: [SIMBC] }
pdf:
  model: consolidated
  file: \${DATA_HOME}/doc.pdf
  asset_path: assets/pdfs_x/doc.pdf
  toc:
    pages: [1, 3]
    series_pattern: '^Serie: (?<name>.+) \\((?<code>[^)]+)\\) \\.+ (?<page>\\d+)\$'
    entry_pattern: '^(?<title>.+?) \\.{3,} (?<page>\\d+)\$'
    heading_pattern: '^Serie: {name}'
    page_offset: 4
catalog:
  output: index.json
  province_label: Prueba
pmtiles:
  reference: \${REPO}/assets/maps/x.pmtiles
xref: { error_above_percent: 10 }
''');
      final definition = ProvinceDefinition.load(
        id: 'test_prov',
        provincesDir: root.path,
        repoRoot: repoRoot,
        environment: {'DATA_HOME': '/data'},
      );
      expect(definition.name, 'Provincia de Prueba');
      expect(definition.gis.format, GisFormat.geojsonLines);
      expect(definition.gis.series.aliases, {'AVE1': 'ave'});
      expect(definition.gis.thresholds.warnBelow, 80);
      expect(definition.gis.thresholds.fields, ['SIMBC']);
      expect(definition.pdf!.model, PdfModel.consolidated);
      expect(definition.pdf!.toc!.pageOffset, 4);
      expect(definition.pdf!.file, p.normalize('/data/doc.pdf'));
      expect(definition.catalog!.provinceLabel, 'Prueba');
      expect(definition.catalog!.jsonStyle, JsonStyle.standard);
      expect(
        definition.pmtiles!.reference,
        p.normalize(p.join(repoRoot, 'assets/maps/x.pmtiles')),
      );
      expect(definition.xrefErrorAbovePercent, 10);
      expect(
        definition.gis.source,
        p.normalize(p.join(root.path, 'test_prov', 'source/gis/a.geojson')),
      );
    });

    test('lists every problem of an invalid definition', () {
      final root = tempDir('config_bad');
      writeProvince(root, 'bad', '''
id: other
gis:
  source: a.shp
  format: kml
  mapping:
    FOO: bar
pdf:
  model: consolidated
  file: a.pdf
  toc:
    pages: [5]
    series_pattern: '^(?<name>.+)\$'
    entry_pattern: '('
''');
      expect(
        () => ProvinceDefinition.load(
          id: 'bad',
          provincesDir: root.path,
          repoRoot: repoRoot,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('CFG001'),
              contains('no coincide con la carpeta'),
              contains('name: falta'),
              contains('gis.format: "kml" no es válido'),
              contains('FOO: no es un campo'),
              contains('pdf.asset_path: falta'),
              contains('pdf.toc.pages'),
              contains('(?<code>'),
              contains('expresión regular inválida'),
            ]),
          ),
        ),
      );
    });

    test('a missing province is a configuration error', () {
      expect(
        () => ProvinceDefinition.load(
          id: 'nope',
          provincesDir: tempDir('none').path,
          repoRoot: repoRoot,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('init nope'),
          ),
        ),
      );
    });

    test('the versioned Buenos Aires and Santa Fe definitions load', () {
      final provinces = p.join(repoRoot, 'data', 'provinces');
      final ba = ProvinceDefinition.load(
        id: 'buenos_aires',
        provincesDir: provinces,
        repoRoot: repoRoot,
      );
      expect(ba.pdf!.model, PdfModel.perSeries);
      expect(ba.catalog!.jsonStyle, JsonStyle.powershell);
      expect(ba.gis.mapping.missingRequiredTargets, isEmpty);
      final sf = ProvinceDefinition.load(
        id: 'santa_fe',
        provincesDir: provinces,
        repoRoot: repoRoot,
        // No machine-specific variables: the definition must be portable.
        environment: const {},
      );
      expect(sf.pdf!.model, PdfModel.consolidated);
      final sfDir = p.join(provinces, 'santa_fe');
      expect(p.isWithin(sfDir, sf.gis.source), isTrue);
      expect(p.isWithin(sfDir, sf.pdf!.file!), isTrue);
      expect(sf.gis.mapping.missingRequiredTargets, isEmpty);
      expect(sf.gis.mapping.ruleFor('PAISAJE'), isA<AbsentRule>());
    });
  });
}
