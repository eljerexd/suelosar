// SuelosAR Data Pipeline (Fase 1) — validates and prepares a province's
// data before it reaches Flutter. Usage and commands:
//   dart run tool/suelosar_data.dart help
// See tool/suelosar_data/README.md.
import 'dart:io';

import 'suelosar_data/cli/runner.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runSuelosArData(arguments);
}
