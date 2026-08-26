import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/gis_feature.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_repository.dart';
import 'package:suelosar/gis/gis_soil_series.dart';
import 'package:suelosar/gis/province_config.dart';
import 'package:suelosar/gis/series_resolver.dart';
import 'package:suelosar/repositories/santa_fe_series_repository.dart';

/// Fase 4B verification: proves the NEW Santa Fe wiring (PMTiles asset,
/// SeriesResolver, SeriesNameResolver) against the real generated archive
/// and the real audited PDF page numbers — not against a synthetic fixture.
/// `GisSoilSeries.fromProperties`, attribute reading, and the map/selection
/// UI itself are already covered by the existing (Buenos Aires) GIS test
/// suite and are unchanged for Santa Fe (Fase 4A confirmed them generic).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProvinceConfig.santaFe', () {
    test('points at the Santa Fe assets, not Buenos Aires\' ', () {
      final config = ProvinceConfig.santaFe;
      expect(config.id, 'santa_fe');
      expect(config.pmtilesAsset, AssetPaths.santaFeGisPmTiles);
      expect(config.pmtilesVersionAsset, AssetPaths.santaFeGisPmTilesVersion);
      expect(config.pmtilesAsset, isNot(AssetPaths.gisPmTiles));
      expect(config.pmtilesLayerName, AssetPaths.gisLayerName);
      // Fase 5: Santa Fe now has its own validated reference basemap,
      // separate from Buenos Aires'.
      expect(
        config.referenceMapAsset,
        AssetPaths.santaFeAgronomicReferenceMap,
      );
      expect(
        config.referenceMapAsset,
        isNot(AssetPaths.agronomicReferenceMap),
      );
    });

    test('Buenos Aires config is untouched', () {
      final config = ProvinceConfig.buenosAires;
      expect(config.id, 'buenos_aires');
      expect(config.pmtilesAsset, AssetPaths.gisPmTiles);
      expect(config.referenceMapAsset, AssetPaths.agronomicReferenceMap);
      expect(config.seriesNameResolver, isA<IdentitySeriesNameResolver>());
    });
  });

  group('Santa Fe reference basemap (Fase 5) — schema matches Buenos Aires', () {
    late Map<String, dynamic> sfJson;
    late Map<String, dynamic> baJson;

    setUpAll(() {
      sfJson = jsonDecode(
        File(AssetPaths.santaFeAgronomicReferenceMap).readAsStringSync(),
      );
      baJson = jsonDecode(
        File(AssetPaths.agronomicReferenceMap).readAsStringSync(),
      );
    });

    test('crs is EPSG:4326, same as required by the loader', () {
      expect(sfJson['crs'], 'EPSG:4326');
      expect(sfJson['crs'], baJson['crs']);
    });

    test('has exactly the same layer keys as Buenos Aires', () {
      final sfLayers = (sfJson['layers'] as Map).keys.toSet();
      final baLayers = (baJson['layers'] as Map).keys.toSet();
      expect(sfLayers, baLayers);
    });

    test('majorCities entries have the same shape as Buenos Aires', () {
      final city =
          (sfJson['layers']['majorCities'] as List).first as Map;
      expect(city.keys.toSet(), {'name', 'lat', 'lon', 'importance'});
      expect(city['importance'], anyOf('primary', 'secondary'));
    });

    test('does not reuse Buenos Aires\' actual data', () {
      expect(sfJson['bbox'], isNot(baJson['bbox']));
      final sfCityNames = (sfJson['layers']['majorCities'] as List)
          .map((c) => (c as Map)['name'])
          .toSet();
      final baCityNames = (baJson['layers']['majorCities'] as List)
          .map((c) => (c as Map)['name'])
          .toSet();
      expect(sfCityNames.intersection(baCityNames), isEmpty);
    });
  });

  group('Santa Fe PMTiles archive (real asset, real pipeline output)', () {
    // .fromFile reads the same asset directly off disk, exercising the same
    // PmTilesArchive/tile-decoding path as .fromAsset (used by
    // ProvinceConfig/GisMapScreen) without needing the path_provider
    // platform channel, which flutter_test doesn't mock.
    PmTilesGisRepository openRealArchive() => PmTilesGisRepository.fromFile(
      archiveFile: File(AssetPaths.santaFeGisPmTiles),
      layerName: AssetPaths.gisLayerName,
    );

    test('loads through the same PmTilesGisRepository BA uses', () async {
      final repository = openRealArchive();
      addTearDown(repository.close);

      final info = await repository.initialize();
      expect(info.minZoom, 4);
      expect(info.maxZoom, 14);
      // Real center read from the archive's own PMTiles header (Fase 3),
      // not Buenos Aires' hardcoded (-36.5, -60).
      expect(info.centerLatitude, closeTo(-32.389239, 0.01));
      expect(info.centerLongitude, closeTo(-61.929932, 0.01));
    });

    test('a real tile decodes real Santa Fe features with CAP_USO', () async {
      final repository = openRealArchive();
      addTearDown(repository.close);
      await repository.initialize();

      // z4 is guaranteed non-empty by validate_map.py's own header check
      // (Fase 3) — covers all of Santa Fe in a handful of tiles.
      GisFeature? found;
      outer:
      for (var x = 0; x < 16; x++) {
        for (var y = 0; y < 16; y++) {
          final layer = await repository.loadTile(
            GisTileCoordinates(zoom: 4, x: x, y: y),
          );
          if (layer.features.isNotEmpty) {
            found = layer.features.first;
            break outer;
          }
        }
      }

      expect(found, isNotNull, reason: 'expected at least one z4 tile with features');
      // CAP_USO is real INTA data (the `gat` field) for the large majority
      // of Santa Fe features — see Fase 3 report section A.
      final capUso = found!.properties['CAP_USO'];
      expect(capUso, isNotNull);
      expect(capUso.toString(), isNotEmpty);
      // PAISAJE has no source in Santa Fe (Fase 3 report section B) —
      // tippecanoe omits empty attributes entirely, so the key must be
      // absent, never an invented placeholder value.
      expect(found.properties.containsKey('PAISAJE'), isFalse);
    });
  });

  group('SantaFeSeriesResolver — real audited page numbers (Fase 1)', () {
    final resolver = SantaFeSeriesResolver(SantaFeSeriesRepository());

    Future<void> expectSeries(
      String rawSeriesValue,
      String expectedName,
      int expectedStartPage,
      int expectedEndPage,
    ) async {
      final location = await resolver.resolve(
        GisSoilSeries(name: rawSeriesValue, percentage: '40'),
      );
      expect(
        location,
        isNotNull,
        reason: '$rawSeriesValue should resolve via the real index',
      );
      expect(location!.assetPath, 'assets/pdfs_santa_fe/mapa_suelos_santa_fe.pdf');
      expect(location.startPage, expectedStartPage);
      expect(location.endPage, expectedEndPage);
    }

    test('Rafaela (RAF)', () => expectSeries('RAF cc', 'Rafaela', 493, 496));
    test(
      'María Luisa (MLA)',
      () => expectSeries('MLA cc', 'María Luisa', 430, 432),
    );
    test(
      'Petronila (PEA)',
      () => expectSeries('PEA d-mb/i', 'Petronila', 473, 475),
    );
  });

  group('SantaFeSeriesNameResolver — raw code to real name', () {
    test('resolves RAF/MLA/PEA after preload, falls back before it', () async {
      final nameResolver = ProvinceConfig.santaFe.seriesNameResolver;
      expect(nameResolver, isA<SantaFeSeriesNameResolver>());
      final typed = nameResolver as SantaFeSeriesNameResolver;

      // Before preload: never invents a name, returns the raw value as-is.
      expect(typed.resolve('RAF cc'), 'RAF cc');

      await ProvinceConfig.santaFe.preloadSeriesNames!();

      expect(typed.resolve('RAF cc'), 'Rafaela');
      expect(typed.resolve('MLA cc'), 'María Luisa');
      expect(typed.resolve('PEA d-mb/i'), 'Petronila');
      // Unknown code: still falls back to the raw value, never invents one.
      expect(typed.resolve('AVE1 cc'), 'AVE1 cc');
    });
  });
}
