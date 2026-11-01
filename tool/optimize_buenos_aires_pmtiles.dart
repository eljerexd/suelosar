// Second, optional stage after the main Docker GIS pipeline
// (`docker/build_map.sh`): writes a copy of a PMTiles archive keeping only
// the attributes SuelosAR reads, with geometry, feature ids, zooms, bounds,
// metadata and compression carried through byte-for-byte.
//
// Kept for compatibility: the logic now lives in the generic optimizer of
// the SuelosAR Data Pipeline (`tool/suelosar_data/pmtiles/optimizer.dart`),
// and the list of kept attributes is the central schema
// (`SuelosArSchema.appAttributes`). `dart run tool/suelosar_data.dart
// optimize --input A --output B` does the same for any province.
//
// Usage:
//   dart run tool/optimize_buenos_aires_pmtiles.dart <input.pmtiles> <output.pmtiles>
//
// The input file is only ever read. The output gets a `.sha256` sidecar.
// Fails loudly (non-zero exit) on any structural assumption that does not
// hold, rather than silently producing a subtly-wrong archive.
import 'dart:io';

import 'suelosar_data/config/province_definition.dart' show OptimizeMode;
import 'suelosar_data/pmtiles/optimizer.dart';
import 'suelosar_data/schema/suelosar_schema.dart';

/// The 18 attributes SuelosAR's own code reads from a feature's properties.
/// `TIPO` and `PAISAJE` feed the polygon detail sheet ("Tipo", and the
/// "Descripción" under "Paisaje"); leaving them out once made both read
/// "Sin datos" for every Buenos Aires polygon.
/// `test/gis_attribute_contract_test.dart` fails if the map screen ever
/// reads an attribute that is missing from this set.
final Set<String> keptAttributes = SuelosArSchema.appAttributes;

/// The Buenos Aires source attributes known to have no reader in the app.
/// Informational only: the optimizer removes whatever is not in
/// [keptAttributes], discovered from the archive itself.
const droppedAttributes = {
  'FASE5',
  'FASE6',
  'OBJECTID_1',
  'POSIC1',
  'POSIC2',
  'POSIC3',
  'POSIC4',
  'POSIC5',
  'POSIC6',
  'taxo_2rio',
  'taxo_3rio',
  'taxo_4rio',
  'taxo_5',
  'taxo_6',
  'taxo_ppal',
};

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/optimize_buenos_aires_pmtiles.dart '
      '<input.pmtiles> <output.pmtiles>',
    );
    exitCode = 64; // EX_USAGE
    return;
  }
  final input = File(arguments[0]);
  final output = File(arguments[1]);
  if (!input.existsSync()) {
    stderr.writeln('[optimize] ERROR: input file not found: ${input.path}');
    exitCode = 66; // EX_NOINPUT
    return;
  }
  try {
    final report = await PmtilesOptimizer(
      keep: keptAttributes,
      log: (message) => stdout.writeln('[optimize] $message'),
    ).run(input, output, mode: OptimizeMode.always);
    stdout
      ..writeln('[optimize] Done.')
      ..writeln('[optimize] Original size: ${report.sizeBefore} bytes')
      ..writeln('[optimize] New size:      ${report.sizeAfter} bytes')
      ..writeln('[optimize] SHA-256:       ${report.sha256After}')
      ..writeln(
        '[optimize] Removed: ${(report.attributesRemoved.toList()..sort()).join(', ')}',
      )
      ..writeln(
        '[optimize] Kept (${report.attributesKept.length}/${keptAttributes.length}): '
        '${(report.attributesKept.toList()..sort()).join(', ')}',
      );
  } on PmtilesStructureException catch (e) {
    stderr.writeln('[optimize] ERROR: ${e.message}');
    exitCode = 1;
  }
}
