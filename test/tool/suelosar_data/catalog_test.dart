import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/suelosar_data/catalog/catalog_diff.dart';
import '../../../tool/suelosar_data/catalog/consolidated_index.dart';
import '../../../tool/suelosar_data/catalog/json_style.dart';
import '../../../tool/suelosar_data/catalog/per_series_catalog.dart';
import '../../../tool/suelosar_data/config/province_definition.dart';
import '../../../tool/suelosar_data/sources/pdf_text.dart';
import '../../../tool/suelosar_data/validation/finding.dart';
import 'helpers.dart';

TocConfig _toc({int? offset, int lastPage = 1}) => TocConfig(
  firstPage: 1,
  lastPage: lastPage,
  seriesPattern: RegExp(
    r'^\s*Serie: (?<name>.+) \((?<code>[^)]+)\)\s*\.+\s*(?<page>\d+)\s*$',
  ),
  entryPattern: RegExp(r'^\s*(?<title>.+?)\s*\.{3,}\s*(?<page>\d+)\s*$'),
  headingPattern: r'^\s*Serie: {name} \({code}\)',
  pageOffset: offset,
);

List<String> _pages({bool breakSecondHeading = false}) => [
  // Physical page 1: table of contents (printed page numbers).
  'Contenido\n'
      'Resumen ............. 1\n'
      'Serie: Alfa (AL) ........ 2\n'
      'Serie: Beta Dos (BD) .... 4\n'
      'Serie: Gamma (GA) ....... 5\n'
      'BIBLIOGRAFÍA ............ 7\n',
  'Resumen\n', // physical 2 = printed 1
  '  Serie: Alfa (AL)\ntexto', // 3 = printed 2
  'sigue Alfa',
  breakSecondHeading ? 'otra cosa' : 'Serie: Beta Dos (BD)\n', // 5 = printed 4
  'Serie: Gamma (GA)\n', // 6 = printed 5
  'Gamma 2',
  'Bibliografía', // 8 = printed 7
  'Anexo',
];

void main() {
  group('encodeCatalogJson', () {
    test('powershell layout and escaping', () {
      final text = encodeCatalogJson([
        {
          'id': 0,
          'name': "O'Brien <x> & \"y\"",
          'memory': null,
          'n': 1.5,
          'ok': true,
        },
        {'id': 1, 'name': 'Ñandú\ttab', 'memory': null, 'n': 2, 'ok': false},
      ], JsonStyle.powershell);
      expect(
        text,
        '[\n'
        '    {\n'
        '        "id":  0,\n'
        '        "name":  "O\\u0027Brien \\u003cx\\u003e \\u0026 \\"y\\"",\n'
        '        "memory":  null,\n'
        '        "n":  1.5,\n'
        '        "ok":  true\n'
        '    },\n'
        '    {\n'
        '        "id":  1,\n'
        '        "name":  "Ñandú\\ttab",\n'
        '        "memory":  null,\n'
        '        "n":  2,\n'
        '        "ok":  false\n'
        '    }\n'
        ']',
      );
      expect(jsonDecode(text), hasLength(2));
      expect(
        () => encodeCatalogJson([
          {
            'a': [1],
          },
        ], JsonStyle.powershell),
        throwsUnsupportedError,
      );
    });

    test('standard layout: two spaces, no trailing newline', () {
      expect(
        encodeCatalogJson({
          'a': {'b': 1},
        }, JsonStyle.standard),
        '{\n  "a": {\n    "b": 1\n  }\n}',
      );
    });

    test('reproduces assets/data/soil_maps.json byte for byte', () {
      final text = File(
        'assets/data/soil_maps.json',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(encodeCatalogJson(jsonDecode(text), JsonStyle.powershell), text);
    });

    test('reproduces assets/data/santa_fe_series_index.json byte for byte', () {
      final text = File(
        'assets/data/santa_fe_series_index.json',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(encodeCatalogJson(jsonDecode(text), JsonStyle.standard), text);
    });
  });

  group('PerSeriesCatalog', () {
    Directory pdfDir(Map<String, String> files) {
      final dir = tempDir('pdfs');
      files.forEach(
        (name, content) =>
            File(p.join(dir.path, name)).writeAsStringSync(content),
      );
      return dir;
    }

    test(
      'builds records named after files, preserving reference ids and data',
      () {
        final dir = pdfDir({
          'Villa_Nueva.pdf': '%PDF-1.4',
          'Aarón_Castellanos.pdf': '%PDF-1.4',
          'Zeta.pdf': '%PDF-1.7',
          'notas.txt': 'x',
        });
        final findings = FindingSink();
        final catalog = PerSeriesCatalog.build(
          directory: dir,
          wordSeparator: '_',
          reference: [
            {
              'id': 7,
              'name': 'Villa Nueva',
              'province': 'X',
              'department': '',
              'scale': '1:50000',
              'pdf': 'Villa_Nueva.pdf',
              'memory': 'm',
              'map': null,
              'notes': 'n',
            },
          ],
          findings: findings,
        );
        expect(catalog.pdfFiles, [
          'Aarón_Castellanos.pdf',
          'Villa_Nueva.pdf',
          'Zeta.pdf',
        ]);
        expect([for (final r in catalog.records) r['id']], [7, 8, 9]);
        expect(catalog.records.first, {
          'id': 7,
          'name': 'Villa Nueva',
          'province': 'X',
          'department': '',
          'scale': '1:50000',
          'pdf': 'Villa_Nueva.pdf',
          'memory': 'm',
          'map': null,
          'notes': 'n',
        });
        expect(catalog.records[1]['name'], 'Aarón Castellanos');
        expect(catalog.records[1].keys, [
          'id',
          'name',
          'province',
          'department',
          'scale',
          'pdf',
          'memory',
          'map',
          'notes',
        ]);
        expect(catalog.seriesKeys, {
          'aaron_castellanos',
          'villa_nueva',
          'zeta',
        });
        expect(findings.findings, isEmpty);
      },
    );

    test('reports duplicates, naming, bad headers and reference problems', () {
      final dir = pdfDir({
        'Cañada Seca.pdf': '%PDF-1.4',
        'Cañada_Seca.pdf': '%PDF-1.4',
        'Roto.pdf': 'no soy un pdf',
      });
      final findings = FindingSink();
      PerSeriesCatalog.build(
        directory: dir,
        wordSeparator: '_',
        reference: [
          {'id': 0, 'name': 'Otro nombre', 'pdf': 'Roto.pdf'},
          {'id': 0, 'name': 'Falta', 'pdf': 'Falta.pdf'},
        ],
        findings: findings,
      );
      final codes = findings.findings
          .map((f) => '${f.severity.label} ${f.code}')
          .toList();
      expect(
        codes,
        containsAll([
          'ERROR PDF001',
          'WARNING PDF002',
          'ERROR PDF003',
          'ERROR CAT001',
          'WARNING CAT004',
          'ERROR SRC001',
        ]),
      );
      expect(findings.findings.firstWhere((f) => f.code == 'PDF001').examples, [
        'Cañada Seca.pdf',
        'Cañada_Seca.pdf',
      ]);
    });

    test('an empty directory is an error', () {
      final findings = FindingSink();
      PerSeriesCatalog.build(
        directory: tempDir('empty'),
        wordSeparator: '_',
        findings: findings,
      );
      expect(findings.findings.single.code, 'SRC001');
    });
  });

  group('ConsolidatedIndex', () {
    test('builds ranges that end before the next table-of-contents entry', () {
      final findings = FindingSink();
      final index = ConsolidatedIndex.build(
        text: PdfText.fromPages(_pages()),
        toc: _toc(),
        generatedFrom: 'fuente.pdf',
        pdfAsset: 'assets/x.pdf',
        provinceLabel: 'Prueba',
        findings: findings,
      );
      expect(findings.findings, isEmpty);
      expect(index.pageOffset, 1);
      expect(index.pageOffsetDetected, isTrue);
      expect(index.entries, hasLength(5));
      expect(
        jsonEncode(index.json),
        jsonEncode({
          'province': 'Prueba',
          'pdfAsset': 'assets/x.pdf',
          'generatedFrom': 'fuente.pdf',
          'pageOffset': 1,
          'series': {
            'AL': {'name': 'Alfa', 'startPage': 3, 'endPage': 4},
            'BD': {'name': 'Beta Dos', 'startPage': 5, 'endPage': 5},
            'GA': {'name': 'Gamma', 'startPage': 6, 'endPage': 7},
          },
        }),
      );
      expect(index.seriesKeys, {'al', 'bd', 'ga'});
      expect(index.namesByKey['bd'], 'Beta Dos');
    });

    test('warns when a series title is not where its range starts', () {
      final findings = FindingSink();
      ConsolidatedIndex.build(
        text: PdfText.fromPages(_pages(breakSecondHeading: true)),
        toc: _toc(offset: 1),
        generatedFrom: 'f.pdf',
        pdfAsset: 'a.pdf',
        provinceLabel: 'P',
        findings: findings,
      );
      final warning = findings.findings.single;
      expect(warning.code, 'CAT005');
      expect(warning.examples.single, contains('BD'));
    });

    test('fails clearly when the offset cannot be detected or confirmed', () {
      final findings = FindingSink();
      final pages = _pages()..[2] = 'sin título';
      final index = ConsolidatedIndex.build(
        text: PdfText.fromPages(pages),
        toc: _toc(),
        generatedFrom: 'f.pdf',
        pdfAsset: 'a.pdf',
        provinceLabel: 'P',
        findings: findings,
      );
      expect(index.json, isNull);
      expect(findings.findings.single.code, 'CAT003');

      final confirm = FindingSink();
      final shifted = _pages()..[5] = 'no';
      final unconfirmed = ConsolidatedIndex.build(
        text: PdfText.fromPages(shifted),
        toc: _toc(),
        generatedFrom: 'f.pdf',
        pdfAsset: 'a.pdf',
        provinceLabel: 'P',
        findings: confirm,
      );
      expect(unconfirmed.json, isNull);
      expect(confirm.findings.single.message, contains('no se confirma'));
    });

    test('rejects codes that collide ignoring case, and unrecognized lines', () {
      final findings = FindingSink();
      final pages = _pages();
      pages[0] =
          '${pages[0]}Serie: Otra (al) ........ 6\nSerie sin formato ............\n';
      pages[6] = 'Serie: Otra (al)\n';
      ConsolidatedIndex.build(
        text: PdfText.fromPages(pages),
        toc: _toc(),
        generatedFrom: 'f.pdf',
        pdfAsset: 'a.pdf',
        provinceLabel: 'P',
        findings: findings,
      );
      final codes = findings.findings.map((f) => f.code).toSet();
      expect(codes, containsAll(['CAT001', 'CAT002', 'CAT009']));
    });

    test('regenerates the Santa Fe index exactly from the shipped PDF', () async {
      final pdf = File('assets/pdfs_santa_fe/mapa_suelos_santa_fe.pdf');
      final String executable;
      try {
        executable = await resolvePdftotext();
      } on Object {
        markTestSkipped('pdftotext no disponible');
        return;
      }
      final findings = FindingSink();
      final index = ConsolidatedIndex.build(
        text: await PdfText.extract(pdf, executable: executable),
        toc: TocConfig(
          firstPage: 1,
          lastPage: 13,
          seriesPattern: _toc().seriesPattern,
          entryPattern: _toc().entryPattern,
          headingPattern: _toc().headingPattern,
          pageOffset: null,
        ),
        generatedFrom:
            'INTA_CRsantafe_EEARafaela_Tosolini_R_Mapa_suelos_provincia_SantaFe-Descripcion_de_las_series.pdf',
        pdfAsset: 'assets/pdfs_santa_fe/mapa_suelos_santa_fe.pdf',
        provinceLabel: 'Santa Fe',
        findings: findings,
      );
      expect(findings.findings, isEmpty);
      final shipped = File(
        'assets/data/santa_fe_series_index.json',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(encodeCatalogJson(index.json, JsonStyle.standard), shipped);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('CatalogDiff', () {
    Map<String, Map<String, Object?>> byCode(Object? doc) => {
      for (final r in doc! as List)
        (r as Map)['code'].toString(): r.cast<String, Object?>(),
    };

    test('identical apart from line endings', () {
      const reference = '[\r\n  {"code": "A", "v": 1}\r\n]';
      final generated = [
        {'code': 'A', 'v': 1},
      ];
      final diff = CatalogDiff.compare(
        generated: generated,
        generatedText: '[\n  {"code": "A", "v": 1}\n]',
        referenceText: reference,
        recordsOf: byCode,
      );
      expect(diff.textEqual, isTrue);
      expect(diff.contentEqual, isTrue);
      final findings = FindingSink();
      diff.report(findings, 'ref.json');
      expect(findings.findings.single.code, 'CAT007');
    });

    test('added, removed, changed and reordered records', () {
      final diff = CatalogDiff.compare(
        generated: [
          {'code': 'C', 'v': 1},
          {'code': 'A', 'v': 2},
          {'code': 'D', 'v': 0},
        ],
        generatedText: 'x',
        referenceText: jsonEncode([
          {'code': 'A', 'v': 1},
          {'code': 'B', 'v': 1},
          {'code': 'C', 'v': 1},
        ]),
        recordsOf: byCode,
      );
      expect(diff.added, ['D']);
      expect(diff.removed, ['B']);
      expect(diff.changed, ['A.v: 1 -> 2']);
      expect(diff.orderDiffers, isTrue);
      expect(diff.firstTextDifferenceLine, 1);
      final findings = FindingSink();
      diff.report(findings, 'ref.json');
      expect(findings.findings.single.severity, Severity.warning);
      expect(findings.findings.single.examples, [
        '+ D',
        '- B',
        '~ A.v: 1 -> 2',
      ]);
    });

    test('same data in another format', () {
      final diff = CatalogDiff.compare(
        generated: [
          {'code': 'A'},
        ],
        generatedText: '[{"code":"A"}]',
        referenceText: '[ {"code": "A"} ]',
        recordsOf: byCode,
      );
      final findings = FindingSink();
      diff.report(findings, 'ref.json');
      expect(diff.contentEqual, isTrue);
      expect(findings.findings.single.message, contains('distinto formato'));
    });
  });
}
