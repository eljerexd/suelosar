// Fase 1 acceptance criteria against the real Buenos Aires and Santa Fe
// data. Opt-in (the sources are large and partly outside the repo):
//
//   $env:SUELOSAR_ACCEPTANCE = "1"
//   # criterion 2 also needs the reference output of remap_santa_fe.mjs:
//   $env:SUELOSAR_REMAP_OUTPUT = "<ruta>\remap_reference.geojson"
//   flutter test test/tool/suelosar_data/acceptance_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/suelosar_data/cli/runner.dart';
import '../../../tool/suelosar_data/sources/geojson_reader.dart';
import 'helpers.dart';

final _enabled = Platform.environment['SUELOSAR_ACCEPTANCE'] == '1';

Map<String, Object?> _report(String province) =>
    (jsonDecode(
              File(
                p.join(
                  repoRoot,
                  'data',
                  'provinces',
                  province,
                  'output',
                  'report.json',
                ),
              ).readAsStringSync(),
            )
            as Map)
        .cast();

List<Map<String, Object?>> _findings(Map<String, Object?> report) => [
  for (final f in report['findings']! as List)
    (f as Map).cast<String, Object?>(),
];

void main() {
  const timeout = Timeout(Duration(minutes: 10));

  test(
    '1. catalog santa_fe reproduces assets/data/santa_fe_series_index.json exactly',
    () async {
      expect(await runSuelosArData(['catalog', 'santa_fe', '--diff']), 0);
      final generated = File(
        p.join(
          repoRoot,
          'data/provinces/santa_fe/output/santa_fe_series_index.json',
        ),
      ).readAsStringSync();
      final shipped = File(
        p.join(repoRoot, 'assets/data/santa_fe_series_index.json'),
      ).readAsStringSync();
      expect(generated, shipped.replaceAll('\r\n', '\n'));
    },
    skip: !_enabled,
    timeout: timeout,
  );

  test(
    '2. normalize santa_fe produces the same properties as remap_santa_fe.mjs',
    () async {
      final reference = Platform.environment['SUELOSAR_REMAP_OUTPUT'];
      if (reference == null || !File(reference).existsSync()) {
        markTestSkipped(
          'SUELOSAR_REMAP_OUTPUT no apunta a la salida de remap_santa_fe.mjs',
        );
        return;
      }
      expect(await runSuelosArData(['normalize', 'santa_fe']), 0);
      final ours = readGeoJsonLines(
        File(
          p.join(repoRoot, 'data/provinces/santa_fe/work/normalized.geojson'),
        ),
        withGeometry: true,
      ).asBroadcastStream();
      final theirs = readGeoJsonLines(
        File(reference),
        withGeometry: true,
      ).toList();
      final expected = await theirs;
      var index = 0;
      await for (final feature in ours) {
        final other = expected[index];
        expect(feature.properties, other.properties, reason: 'feature $index');
        expect(
          jsonDecode(feature.rawGeometry!),
          jsonDecode(other.rawGeometry!),
          reason: 'geometry $index',
        );
        index++;
      }
      expect(index, expected.length);
    },
    skip: !_enabled,
    timeout: timeout,
  );

  test(
    '3. catalog buenos_aires --diff compares with assets/data/soil_maps.json and reports inconsistencies',
    () async {
      expect(await runSuelosArData(['catalog', 'buenos_aires', '--diff']), 1);
      final stage =
          jsonDecode(
                File(
                  p.join(
                    repoRoot,
                    'data/provinces/buenos_aires/output/stages/catalog.json',
                  ),
                ).readAsStringSync(),
              )
              as Map;
      final diff = (stage['data'] as Map)['diff'] as Map;
      expect(diff['reference'], 'assets/data/soil_maps.json');
      expect(diff['textEqual'], isTrue);
      final codes = [
        for (final f in stage['findings'] as List)
          '${f['severity']} ${f['code']}',
      ];
      expect(codes.where((c) => c == 'ERROR PDF001'), hasLength(2));
      expect(codes, contains('WARNING PDF002'));
    },
    skip: !_enabled,
    timeout: timeout,
  );

  test(
    '4. validate buenos_aires finds the duplicates, series without PDF and PDFs without series',
    () async {
      expect(await runSuelosArData(['validate', 'buenos_aires']), 1);
      final report = _report('buenos_aires');
      final findings = _findings(report);
      expect(findings.where((f) => f['code'] == 'PDF001'), hasLength(2));
      final crossref = (report['stages']! as Map)['crossref'] as Map;
      expect(crossref['gisSeriesWithoutCatalogRawValues'], 46);
      expect(crossref['gisSeriesWithoutCatalog'], 44);
      expect(crossref['catalogEntriesWithoutGis'], 27);
      expect(
        File(
          p.join(repoRoot, 'data/provinces/buenos_aires/output/report.md'),
        ).existsSync(),
        isTrue,
      );
    },
    skip: !_enabled,
    timeout: timeout,
  );

  test(
    '5. metadata on the Buenos Aires archive, including the stale app size',
    () async {
      expect(
        await runSuelosArData(['metadata', '--province', 'buenos_aires']),
        0,
      );
      final metadata =
          jsonDecode(
                File(
                  p.join(
                    repoRoot,
                    'data/provinces/buenos_aires/output/pmtiles_metadata.json',
                  ),
                ).readAsStringSync(),
              )
              as Map;
      // Fase 2: the published archive when `build` produced one, otherwise
      // the one the app uses.
      final published = File(
        p.join(
          repoRoot,
          'data/provinces/buenos_aires/output/soil_polygons.pmtiles',
        ),
      );
      final archive = published.existsSync()
          ? published
          : File(p.join(repoRoot, 'assets/maps/soil_polygons.pmtiles'));
      expect(metadata['sizeBytes'], archive.lengthSync());
      expect(
        metadata['sha256'],
        File('${archive.path}.sha256').readAsStringSync().trim(),
      );
      expect(metadata['minZoom'], 4);
      expect(metadata['maxZoom'], 14);
      expect(metadata['bounds'], isNotNull);
      expect(metadata['center'], isNotNull);
      final stage =
          jsonDecode(
                File(
                  p.join(
                    repoRoot,
                    'data/provinces/buenos_aires/output/stages/metadata.json',
                  ),
                ).readAsStringSync(),
              )
              as Map;
      final app = (stage['data'] as Map)['app'] as Map;
      expect(app['sizeMatches'], isFalse);
      expect(
        [
          for (final f in stage['findings'] as List) f['message'] as String,
        ].join(),
        contains('pmtilesDownloadSizeBytes está desactualizado'),
      );
      expect(
        await runSuelosArData([
          'metadata',
          '--province',
          'buenos_aires',
          '--strict',
        ]),
        1,
      );
    },
    skip: !_enabled,
    timeout: timeout,
  );
}
