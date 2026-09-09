import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/map_coverage.dart';

/// Fase 11D: Configuración's cartography manager (settings_screen.dart)
/// groups each province's cached PMTiles file(s) by a "stem" derived from
/// its asset path — the same content-hash-stripped filename
/// `gis_repository.dart`'s `_prepareAssetArchive` already writes to disk
/// (`<stem>-<sha256>.pmtiles`). That manager reads every province from
/// `MapCoverage.all` rather than naming Buenos Aires/Santa Fe directly, so
/// it silently breaks — two provinces' sizes/actions merging into one card
/// — if a future province's `pmtilesAsset` ever collided on this stem.
/// `_provinceCacheStem` itself is private to settings_screen.dart, so this
/// mirrors its one-line derivation directly against the real coverage
/// list, the same way `_mapsCacheStem`'s derivation is already duplicated
/// between gis_repository.dart and settings_screen.dart by convention.
String _stem(MapCoverage coverage) {
  final name = coverage.config.pmtilesAsset.split('/').last;
  return name.replaceFirst(RegExp(r'\.pmtiles$'), '');
}

void main() {
  test('every registered coverage has a real, unique cartography stem', () {
    expect(MapCoverage.all, isNotEmpty);

    final stems = MapCoverage.all.map(_stem).toList();

    for (final stem in stems) {
      expect(stem, isNotEmpty);
      expect(stem, isNot(endsWith('.pmtiles')));
    }
    expect(stems.toSet(), hasLength(stems.length));
  });

  test('Buenos Aires and Santa Fe resolve to their known real stems', () {
    final byId = {for (final c in MapCoverage.all) c.id: _stem(c)};
    expect(byId['buenos_aires'], 'soil_polygons');
    expect(byId['santa_fe'], 'santa_fe_soil_polygons');
  });
}
