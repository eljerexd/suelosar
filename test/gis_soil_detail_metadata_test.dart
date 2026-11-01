import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/gis_soil_series.dart';
import 'package:suelosar/gis/gis_soil_taxonomy.dart';

void main() {
  test('CoD1 source series and missing proportions stay ordered through 8', () {
    // Source fixture: data/provinces/cordoba/source/gis/
    // carta_suelo_100mil_2025.json, id 86 (pdf_simbolo CoD1).
    final series = GisSoilSeries.fromProperties({
      'SERIE1': 'YACANTO I',
      'FASE1': null,
      'SERIE2': 'YACANTO II',
      'SERIE3': 'YACANTO III',
      'SERIE4': 'YACANTO IV',
      'SERIE5': 'CALAMUCHITA III',
      'SERIE6': 'SAN IGNACIO IV',
      'SERIE7': 'FUNDACIÓN',
      'SERIE8': 'SAN PANCRACIO',
      // The source record has no porc_1..porc_5 values and publishes no
      // percentage fields for serie_6..serie_8.
    });

    expect(series.map((item) => item.name), [
      'YACANTO I',
      'YACANTO II',
      'YACANTO III',
      'YACANTO IV',
      'CALAMUCHITA III',
      'SAN IGNACIO IV',
      'FUNDACIÓN',
      'SAN PANCRACIO',
    ]);
    expect(series.map((item) => item.percentage), everyElement(isEmpty));
    expect(series.map((item) => item.phase), everyElement(isEmpty));
  });

  test(
    'series parser skips absent and empty optional slots without phantoms',
    () {
      final series = GisSoilSeries.fromProperties({
        'SERIE1': 'Bragado',
        'PORC1': 70,
        'FASE1': 'en fase leve',
        'SERIE2': null,
        'PORC2': 0,
        'SERIE8': 'SAN PANCRACIO',
      });

      expect(series, hasLength(2));
      expect(series.first.displayLabel, 'Bragado (70%)');
      expect(series.first.phase, 'en fase leve');
      expect(series.last.name, 'SAN PANCRACIO');
      expect(series.last.percentage, isEmpty);
    },
  );

  test('MNtc-2 source taxonomy keeps IP, subgroup and position', () {
    // Source fixture: data/provinces/cordoba/source/gis/
    // carta_suelo_500mil_2024.json, id 17 (pdf_simbolo MNtc-2).
    final taxonomy = GisSoilTaxonomy.fromProperties({
      'IP': '24',
      'CLASE': 'IV',
      'SUBCLASE': 'e',
      'SUBGRUPO1': 'Haplustol típico',
      'POSICION1': 'Pendientes pronunciadas',
      'SUBGRUPO2': null,
      'POSICION2': null,
      'SUBGRUPO5': null,
      'POSICION5': null,
    });

    expect(taxonomy.isEmpty, isFalse);
    expect(taxonomy.soilClass, 'IV');
    expect(taxonomy.subclass, 'e');
    expect(taxonomy.productivityIndex, '24');
    expect(taxonomy.components, hasLength(1));
    expect(taxonomy.components.first.index, 1);
    expect(taxonomy.components.first.subgroup, 'Haplustol típico');
    expect(taxonomy.components.first.position, 'Pendientes pronunciadas');
    expect(taxonomy.components.single.index, 1);
    expect(taxonomy.components.single.subgroup, 'Haplustol típico');
    expect(taxonomy.components.single.position, 'Pendientes pronunciadas');
  });

  test(
    'Buenos Aires source taxonomies remain distinct from series positions',
    () {
      final taxonomy = GisSoilTaxonomy.fromProperties({
        'taxo_ppal': 'Haplustol litico',
        'taxo_2rio': 'Haplustol tipico',
      });
      final series = GisSoilSeries.fromProperties({
        'SERIE1': 'Alta Vista',
        'PORC1': 70,
        'POSIC1': 'Loma y pendiente',
      });

      expect(
        taxonomy.sourceClassifications.map((item) => (item.label, item.value)),
        [
          ('Taxonomía principal', 'Haplustol litico'),
          ('Taxonomía secundaria 2', 'Haplustol tipico'),
        ],
      );
      expect(series.single.position, 'Loma y pendiente');
      expect(series.single.phase, isEmpty);
    },
  );

  test('taxonomy parser returns empty when source fields are unavailable', () {
    final taxonomy = GisSoilTaxonomy.fromProperties({
      'IP': null,
      'CLASE': '',
      'SUBCLASE': null,
      'SUBGRUPO1': '',
      'POSICION1': '  ',
    });

    expect(taxonomy.isEmpty, isTrue);
    expect(taxonomy.components, isEmpty);
  });

  test('AEtc-2 source phase stays attached to the matching series', () {
    final series = GisSoilSeries.fromProperties({
      'SERIE1': 'ARROYITO',
      'FASE1': 'en fase moderadamente salina',
      'PORC1': 30,
      'SERIE2': 'ALTOS DE CHIPIÓN',
      'FASE2': 'en fase moderadamente salina',
      'PORC2': 30,
      'SERIE3': 'LA ARGENTINA',
      'FASE3': 'en fase moderadamente salina',
      'PORC3': 20,
      'SERIE4': 'suelos hidro-halomórficos',
      'FASE4': null,
      'PORC4': 20,
      'FASE5': null,
    });

    expect(series.map((item) => item.name), [
      'ARROYITO',
      'ALTOS DE CHIPIÓN',
      'LA ARGENTINA',
      'suelos hidro-halomórficos',
    ]);
    expect(series.map((item) => item.phase), [
      'en fase moderadamente salina',
      'en fase moderadamente salina',
      'en fase moderadamente salina',
      '',
    ]);
    expect(series.map((item) => item.percentage), ['30', '30', '20', '20']);
  });
}
