import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android MapLibre F5 keeps all provinces in on-demand debug mode', () {
    final launch = jsonDecode(
      File('.vscode/launch.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final configurations = launch['configurations'] as List<dynamic>;
    final androidMapLibre = configurations
        .cast<Map<String, dynamic>>()
        .singleWhere(
          (configuration) =>
              configuration['name'] ==
              'SuelosAR Alpha - Android MapLibre (Debug)',
        );
    final arguments = (androidMapLibre['toolArgs'] as List<dynamic>)
        .cast<String>();

    expect(arguments, contains('--dart-define=SUelosAR_MAPLIBRE_NATIVE=true'));
    expect(
      arguments,
      isNot(contains('--dart-define=SUelosAR_DEBUG_LOCAL_PMTILES=true')),
    );
  });

  test('the explicit local PMTiles profile remains available for map QA', () {
    final launch = jsonDecode(
      File('.vscode/launch.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final configurations = launch['configurations'] as List<dynamic>;
    final localMapLibre = configurations
        .cast<Map<String, dynamic>>()
        .singleWhere(
          (configuration) =>
              configuration['name'] ==
              'SuelosAR Alpha - Android MapLibre (Local PMTiles)',
        );
    final arguments = (localMapLibre['toolArgs'] as List<dynamic>)
        .cast<String>();

    expect(arguments, contains('--dart-define=SUelosAR_MAPLIBRE_NATIVE=true'));
    expect(
      arguments,
      contains('--dart-define=SUelosAR_DEBUG_LOCAL_PMTILES=true'),
    );
  });
}
