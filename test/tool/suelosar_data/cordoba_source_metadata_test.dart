import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:suelosar/gis/gis_soil_series.dart';
import 'package:suelosar/gis/gis_soil_taxonomy.dart';

import '../../../tool/suelosar_data/config/province_definition.dart';
import '../../../tool/suelosar_data/normalize/normalizer.dart';

Map<String, Object?> _sourceRecord(String relativePath, int id) {
  final source = jsonDecode(File(relativePath).readAsStringSync()) as Map;
  final feature = (source['features'] as List).cast<Map>().firstWhere(
    (feature) => (feature['properties'] as Map)['id'] == id,
  );
  return (feature['properties'] as Map).cast<String, Object?>();
}

void main() {
  final root = Directory.current.path;
  final province = ProvinceDefinition.load(
    id: 'cordoba',
    provincesDir: p.join(root, 'data', 'provinces'),
    repoRoot: root,
  );

  test('AEtc-2 1:100,000 source metadata maps to its unit and series', () {
    final source = _sourceRecord(
      'data/provinces/cordoba/source/gis/carta_suelo_100mil_2025.json',
      271,
    );
    final config = province.gis.additionalSources.singleWhere(
      (item) => item.id == 'carta_suelo_100mil_2025',
    );
    final mapped = Normalizer(province).apply(source, mapping: config.mapping);

    expect(mapped['CLASE'], 'VII');
    expect(mapped['SUBCLASE'], 'ws');
    expect(mapped['IP'], 10);
    final series = GisSoilSeries.fromProperties(mapped);
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
    expect(GisSoilTaxonomy.fromProperties(mapped).productivityIndex, '10');
  });

  test(
    'MNtc-2 1:500,000 maps classification without turning taxa into series',
    () {
      final source = _sourceRecord(
        'data/provinces/cordoba/source/gis/carta_suelo_500mil_2024.json',
        17,
      );
      final config = province.gis.additionalSources.singleWhere(
        (item) => item.id == 'carta_suelo_500mil_2024',
      );
      final mapped = Normalizer(
        province,
      ).apply(source, mapping: config.mapping);
      final classification = GisSoilTaxonomy.fromProperties(mapped);

      expect(classification.soilClass, 'IV');
      expect(classification.subclass, 'e');
      expect(classification.productivityIndex, '24');
      expect(classification.components.single.subgroup, 'Haplustol típico');
      expect(
        classification.components.single.position,
        'Pendientes pronunciadas',
      );
      expect(GisSoilSeries.fromProperties(mapped), isEmpty);
    },
  );
}
