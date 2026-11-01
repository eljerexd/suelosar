import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:suelosar/repositories/pdf_series_repository.dart';
import 'package:suelosar/repositories/santa_fe_series_repository.dart';

import '../../../tool/optimize_buenos_aires_pmtiles.dart' as optimizer;
import '../../../tool/suelosar_data/schema/suelosar_schema.dart';
import '../../../tool/suelosar_data/sources/dbf_reader.dart';
import '../../../tool/suelosar_data/sources/series_rules.dart';
import 'helpers.dart';

Set<String> _quotedAttributes(String text) => {
  for (final m in RegExp(r'"([A-Za-z_]+)"').allMatches(text)) m.group(1)!,
};

void main() {
  group('SuelosArSchema matches every place that lists the fields', () {
    final required = SuelosArSchema.requiredFields.toSet();

    test('17 required + OBJECTID + SERIE7/SERIE8 (Parte 12B) + '
        'SUBGRUPO1-5/POSICION1-5/IP, CLASE/SUBCLASE and FASE1-4 '
        '(all optional) = the 37 '
        'attributes the app can read', () {
      expect(required, hasLength(17));
      expect(SuelosArSchema.appAttributes, hasLength(37));
    });

    test('docker/build_map.sh', () {
      final source = File('docker/build_map.sh').readAsStringSync();
      final block = RegExp(
        r'required_attributes = \{(.*?)\n\}',
        dotAll: true,
      ).firstMatch(source)!.group(1)!;
      final declared = {
        ..._quotedAttributes(block),
        if (block.contains('f"SERIE{index}"')) ...SuelosArSchema.seriesFields,
        if (block.contains('f"PORC{index}"'))
          ...SuelosArSchema.percentageFields,
      };
      expect(declared, required);
    });

    test('docker/validate_map.py', () {
      final source = File('docker/validate_map.py').readAsStringSync();
      final block = RegExp(
        r'REQUIRED_ATTRIBUTES = \{(.*?)\n\}',
        dotAll: true,
      ).firstMatch(source)!.group(1)!;
      final declared = {
        ..._quotedAttributes(block),
        if (block.contains('f"SERIE{index}"')) ...SuelosArSchema.seriesFields,
        if (block.contains('f"PORC{index}"'))
          ...SuelosArSchema.percentageFields,
      };
      expect(declared, required);
    });

    test(
      'tool/optimize_buenos_aires_pmtiles.dart keeps exactly the app attributes',
      () {
        expect(optimizer.keptAttributes, SuelosArSchema.appAttributes);
      },
    );

    test('lib/gis/gis_map_screen.dart reads only schema attributes', () {
      // Same scan as test/gis_attribute_contract_test.dart.
      final source = File('lib/gis/gis_map_screen.dart').readAsStringSync();
      final read = {
        for (final m in RegExp(
          r"(?:_readAttribute|_optionalAttribute|_featureValue|_propertyValue)\(\s*\w+\s*,\s*'([^']+)'\s*\)"
          r"|properties\['([^']+)'\]",
        ).allMatches(source))
          (m.group(1) ?? m.group(2))!,
      };
      expect(read, isNotEmpty);
      expect(read.difference(SuelosArSchema.appAttributes), isEmpty);
    });
  });

  group('series rules match the app originals', () {
    test(
      'normalizeSeriesName == PdfSeriesRepository.normalizeName on every PDF name',
      () {
        final names = [
          for (final f in Directory('assets/pdfs').listSync().whereType<File>())
            p.basename(f.path),
          'Cañada Seca',
          'O´ Brien',
          '  Suelos   Indiferenciados_de Bajos ',
          'Ÿÿ Æther Œuvre.PDF',
          'Ñandú',
          'Córdoba',
        ];
        for (final name in names) {
          expect(
            normalizeSeriesName(name),
            PdfSeriesRepository.normalizeName(name),
            reason: name,
          );
        }
      },
    );

    test(
      'normalizeSeriesName == PdfSeriesRepository.normalizeName on the Buenos Aires GIS',
      () {
        final dbf = File('docker/input/Suelos_BA_50mil_V2.dbf');
        if (!dbf.existsSync()) {
          markTestSkipped('Shapefile de Buenos Aires no disponible');
          return;
        }
        final table = DbfTable.open(dbf);
        var checked = 0;
        for (final (_, record) in table.records()) {
          for (var i = 1; i <= 6; i++) {
            final value = record['SERIE$i'];
            if (value is String) {
              checked++;
              expect(
                normalizeSeriesName(value),
                PdfSeriesRepository.normalizeName(value),
              );
            }
          }
        }
        expect(checked, greaterThan(1000));
      },
    );

    test('firstTokenCode / normalizeCode == SantaFeSeriesRepository', () {
      for (final raw in <Object?>[
        'CER cc',
        ' MLA  As',
        'ALd',
        '',
        '   ',
        null,
        0,
        'Nqv-RTA cc',
      ]) {
        expect(
          firstTokenCode(raw),
          SantaFeSeriesRepository.extractSeriesCode(raw),
          reason: '$raw',
        );
      }
      for (final code in ['ALd', ' Ald ', 'AVE1']) {
        expect(
          normalizeCode(code),
          SantaFeSeriesRepository.normalizeCode(code),
        );
      }
    });

    test(
      'dominantSeriesCode == SantaFeSeriesRepository.dominantSeriesCode for numeric data',
      () {
        final cases = <Map<String, dynamic>>[
          {
            'comp1': 'AAA cc',
            'comp1_porc': 30,
            'comp2': 'BBB cc',
            'comp2_porc': 70,
          },
          {
            'comp1': 'AAA cc',
            'comp1_porc': 50,
            'comp2': 'BBB cc',
            'comp2_porc': 50,
          },
          {
            'comp1': 'AAA cc',
            'comp1_porc': null,
            'comp2': 'BBB cc',
            'comp2_porc': null,
          },
          {'comp1': null, 'comp2': '  ', 'comp3': 'CCC', 'comp3_porc': 10.5},
          {'comp1': null},
          {
            'comp1': 'AAA',
            'comp1_porc': '40',
            'comp2': 'BBB',
            'comp2_porc': 20,
          },
        ];
        for (final properties in cases) {
          final ours = dominantSeriesCode(
            [for (var i = 1; i <= 6; i++) properties['comp$i']],
            [for (var i = 1; i <= 6; i++) properties['comp${i}_porc']],
            firstTokenCode,
          );
          expect(
            ours,
            SantaFeSeriesRepository.dominantSeriesCode(properties),
            reason: '$properties',
          );
        }
      },
    );

    test('jsParseFloat follows JavaScript parseFloat', () {
      expect(jsParseFloat('40'), 40);
      expect(jsParseFloat(' 12.5%'), 12.5);
      expect(jsParseFloat('3e2x'), 300);
      expect(jsParseFloat('1.'), 1);
      expect(jsParseFloat('.5'), 0.5);
      expect(jsParseFloat('-Infinity'), double.negativeInfinity);
      expect(jsParseFloat('abc'), isNull);
      expect(jsParseFloat(''), isNull);
      expect(jsParseFloat(null), isNull);
    });
  });

  test('helpers produce shapefile rings with the expected orientation', () {
    // Sanity check of the test fixtures themselves.
    expect(square(0, 0, 1).first, [0.0, 0.0]);
    expect(hole(0, 0, 1)[1], [1.0, 0.0]);
  });
}
