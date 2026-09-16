import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_repository.dart';

import '../tool/optimize_buenos_aires_pmtiles.dart' as optimizer;

/// Every feature attribute `gis_map_screen.dart` reads by literal name.
///
/// Scans the source rather than keeping a hand-written list, so a new read
/// (e.g. `_readAttribute(feature, 'X')`) is picked up automatically. Reads
/// through a variable key over a const list of alternatives (the PDF id and
/// area fallbacks) are optional lookups for fields the Buenos Aires dataset
/// never had, and are deliberately not matched.
Set<String> _attributesReadByMapScreen() {
  final source = File('lib/gis/gis_map_screen.dart').readAsStringSync();
  final pattern = RegExp(
    r"(?:_readAttribute|_featureValue|_propertyValue)\(\s*\w+\s*,\s*'([^']+)'\s*\)"
    r"|properties\['([^']+)'\]",
  );
  return {
    for (final match in pattern.allMatches(source))
      (match.group(1) ?? match.group(2))!,
  };
}

void main() {
  test('the map screen attribute scan finds the detail sheet fields', () {
    // Guards the scan itself: if a refactor renamed the helpers, the
    // contract test below would pass vacuously.
    expect(
      _attributesReadByMapScreen(),
      containsAll(<String>['SIMBC', 'CAP_USO', 'Nombre_UC', 'TIPO', 'PAISAJE']),
    );
  });

  test('the Buenos Aires optimizer keeps every attribute the map screen reads',
      () {
    final read = _attributesReadByMapScreen();
    expect(
      read.difference(optimizer.keptAttributes),
      isEmpty,
      reason:
          'tool/optimize_buenos_aires_pmtiles.dart would strip these from the '
          'Buenos Aires archive, and the map screen would show "Sin datos"',
    );
    expect(read.intersection(optimizer.droppedAttributes), isEmpty);
    expect(
      optimizer.keptAttributes.intersection(optimizer.droppedAttributes),
      isEmpty,
    );
  });

  test('the shipped Buenos Aires archive carries TIPO and PAISAJE', () async {
    final repository = PmTilesGisRepository.fromFile(
      archiveFile: File('assets/maps/soil_polygons.pmtiles'),
      layerName: 'soil_polygons',
    );
    addTearDown(repository.close);
    await repository.initialize();

    // z9 tile over the centre of the province (Saladillo / 25 de Mayo).
    final layer = await repository.loadTile(
      const GisTileCoordinates(zoom: 9, x: 169, y: 309),
    );
    expect(layer.features, isNotEmpty);
    expect(
      layer.features.where((f) => f.properties.containsKey('TIPO')),
      isNotEmpty,
    );
    expect(
      layer.features.where((f) => f.properties.containsKey('PAISAJE')),
      isNotEmpty,
    );
  });
}
