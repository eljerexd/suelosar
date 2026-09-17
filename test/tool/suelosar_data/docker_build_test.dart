// Fase 2 end-to-end build through the real Docker image, on a tiny
// synthetic GeoJSON province. Opt-in (needs Docker Desktop running; the
// first run may rebuild the `suelosar-gis-builder:local` image):
//
//   $env:SUELOSAR_DOCKER = "1"
//   flutter test test/tool/suelosar_data/docker_build_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/suelosar_data/cli/runner.dart';
import '../../../tool/suelosar_data/pmtiles/optimizer.dart';
import '../../../tool/suelosar_data/schema/suelosar_schema.dart';
import 'helpers.dart';

final _enabled = Platform.environment['SUELOSAR_DOCKER'] == '1';

// build_map.sh requires at least one value in every required column.
const _series = ['Alfa', 'Beta', 'Gama', 'Delta', 'Epsilon', 'Zeta'];

List<Map<String, Object?>> _stages(String outputDir) => [
  for (final s
      in ((jsonDecode(File(p.join(outputDir, 'report.json')).readAsStringSync())
                  as Map)['timings']
              as Map)['stages']
          as List)
    (s as Map).cast<String, Object?>(),
];

Map<String, Object?> _stage(String outputDir, String name) =>
    _stages(outputDir).singleWhere((s) => s['stage'] == name);

void main() {
  test(
    'build, reuse and --force through Docker',
    () async {
      final root = tempDir('docker_build');
      final dir = Directory(p.join(root.path, 'mini'))..createSync();
      File(p.join(dir.path, 'province.yaml')).writeAsStringSync('''
id: mini
name: Mini
gis:
  source: gis.geojson
  format: geojson_lines
  mapping:
${identityMapping()}
pmtiles:
  output: mini_soil_polygons.pmtiles
  zooms: { min: 4, max: 13 }
''');
      writeGeoJsonLines(dir, 'gis.geojson', [
        {...fullProperties(series: _series), 'EXTRA': 'x'},
        {...fullProperties(simbc: 'U2', series: _series), 'EXTRA': 'y'},
      ]);
      final sourceBefore = File(
        p.join(dir.path, 'gis.geojson'),
      ).readAsBytesSync();
      final output = p.join(dir.path, 'output');
      final published = File(p.join(output, 'mini_soil_polygons.pmtiles'));
      final args = ['--provinces-dir', root.path, 'build', 'mini'];

      expect(await runSuelosArData(args), 0);
      expect(published.existsSync(), isTrue);
      expect(
        File('${published.path}.sha256').readAsStringSync().trim(),
        await sha256OfFile(published),
      );
      final metadata =
          jsonDecode(
                File(
                  p.join(output, 'pmtiles_metadata.json'),
                ).readAsStringSync(),
              )
              as Map;
      expect(
        (metadata['attributes'] as List).toSet(),
        SuelosArSchema.requiredFields.toSet(),
      );
      // Normalization already dropped EXTRA: optimize: auto only copies.
      expect((metadata['optimization'] as Map)['removed'], isEmpty);
      expect((metadata['optimization'] as Map)['rewritten'], isFalse);
      expect(_stage(output, 'map')['reused'], isFalse);
      final firstHash = await sha256OfFile(published);

      expect(await runSuelosArData(args), 0);
      for (final stage in ['normalize', 'prepare', 'map', 'optimize']) {
        expect(_stage(output, stage)['reused'], isTrue, reason: stage);
      }
      expect(await sha256OfFile(published), firstHash);

      expect(await runSuelosArData([...args, '--force']), 0);
      for (final stage in ['normalize', 'prepare', 'map', 'optimize']) {
        expect(_stage(output, stage)['reused'], isFalse, reason: stage);
      }
      expect(published.existsSync(), isTrue);
      expect(
        File(p.join(dir.path, 'gis.geojson')).readAsBytesSync(),
        sourceBefore,
      );
      // Everything the build wrote stays inside the province folder.
      expect(root.listSync().map((e) => p.basename(e.path)), ['mini']);
    },
    skip: _enabled ? false : 'set SUELOSAR_DOCKER=1 to run',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
