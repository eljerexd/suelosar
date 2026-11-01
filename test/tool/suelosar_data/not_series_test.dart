import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/suelosar_data/config/paths.dart';
import '../../../tool/suelosar_data/config/province_definition.dart';
import '../../../tool/suelosar_data/normalize/normalizer.dart';
import '../../../tool/suelosar_data/validation/cross_reference.dart';
import '../../../tool/suelosar_data/validation/finding.dart';
import 'helpers.dart';

ProvinceDefinition _province(Directory root, String series) {
  writeProvince(root, 'cmp', '''
id: cmp
name: Componentes
gis:
  source: gis.geojson
  format: geojson_lines
  mapping:
${identityMapping()}
  series:
$series
''');
  writeGeoJsonLines(Directory(p.join(root.path, 'cmp')), 'gis.geojson', [
    fullProperties(series: ['ALFA', 'suelos menores'], porc: [70, 30]),
    fullProperties(simbc: 'U2', series: ['roca expuesta']),
    fullProperties(simbc: 'U3', series: ['BETA', 'ALFA']),
  ]);
  return ProvinceDefinition.load(
    id: 'cmp',
    provincesDir: root.path,
    repoRoot: repoRoot,
  );
}

void main() {
  test(
    'not_series keeps components in the data but out of the catalog lookup',
    () async {
      final root = tempDir('not_series');
      final d = _province(root, "    not_series: '^[a-z]'");
      expect(d.gis.series.notSeries!.pattern, '^[a-z]');

      final output = File(p.join(root.path, 'normalized.geojson'));
      final result = await Normalizer(
        d,
        catalogKeys: {'alfa'},
      ).run(output: output);
      expect(result.seriesFeatureCounts, {'alfa': 2, 'beta': 1});
      expect(result.nonSeriesFeatureCounts, {
        'suelos menores': 1,
        'roca expuesta': 1,
      });
      // The feature that only has a component has no series.
      expect(result.featuresWithSeries, 2);
      expect(result.featuresWithUncataloguedSeries, 1);

      // Values are written unchanged.
      final features =
          (jsonDecode(output.readAsStringSync()) as Map)['features'] as List;
      expect(
        ((features[0] as Map)['properties'] as Map)['SERIE2'],
        'suelos menores',
      );
      expect(
        ((features[1] as Map)['properties'] as Map)['SERIE1'],
        'roca expuesta',
      );

      // Summary round-trip (reused normalize stages).
      final replay = NormalizeResult.fromSummaryJson(
        jsonDecode(jsonEncode(result.toSummaryJson())) as Map<String, Object?>,
      );
      expect(replay.nonSeriesFeatureCounts, result.nonSeriesFeatureCounts);

      final findings = FindingSink();
      final data = checkCrossReference(
        d,
        result,
        const CatalogKeys(
          keys: {'alfa'},
          labels: {'alfa': 'ALFA.pdf'},
          kind: 'PDFs',
        ),
        findings,
      );
      final xrf001 = findings.findings.singleWhere((f) => f.code == 'XRF001');
      expect(xrf001.examples.single, startsWith('BETA'));
      final xrf004 = findings.findings.singleWhere((f) => f.code == 'XRF004');
      expect(xrf004.severity, Severity.info);
      expect(
        xrf004.examples,
        containsAll([
          'suelos menores (1 features)',
          'roca expuesta (1 features)',
        ]),
      );
      expect(data['nonSeriesValues'], 2);
    },
  );

  test('without not_series every SERIEn value is a series', () async {
    final d = _province(tempDir('not_series_off'), '    aliases: {}');
    expect(d.gis.series.notSeries, isNull);
    final result = await Normalizer(d).run();
    expect(
      result.seriesFeatureCounts.keys,
      containsAll(['suelos_menores', 'roca_expuesta']),
    );
    expect(result.nonSeriesFeatureCounts, isEmpty);
    expect(result.featuresWithSeries, 3);
  });

  test('an invalid not_series pattern is a configuration error', () {
    expect(
      () => _province(tempDir('not_series_bad'), "    not_series: '('"),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('gis.series.not_series'),
        ),
      ),
    );
  });
}
