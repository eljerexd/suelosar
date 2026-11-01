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
      expect(config.referenceMapAsset, AssetPaths.santaFeAgronomicReferenceMap);
      expect(config.referenceMapAsset, isNot(AssetPaths.agronomicReferenceMap));
    });

    test('Buenos Aires config is untouched', () {
      final config = ProvinceConfig.buenosAires;
      expect(config.id, 'buenos_aires');
      expect(config.pmtilesAsset, AssetPaths.gisPmTiles);
      expect(config.referenceMapAsset, AssetPaths.agronomicReferenceMap);
      expect(config.seriesNameResolver, isA<IdentitySeriesNameResolver>());
    });
  });

  group('province reference basemap jurisdiction labels', () {
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

    test('all three province basemaps use the shared layer schema', () {
      final sfLayers = (sfJson['layers'] as Map).keys.toSet();
      final baLayers = (baJson['layers'] as Map).keys.toSet();
      final cordobaJson =
          jsonDecode(
                File(
                  AssetPaths.cordobaAgronomicReferenceMap,
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final cordobaLayers = (cordobaJson['layers'] as Map).keys.toSet();
      expect(sfLayers, baLayers);
      expect(cordobaLayers, baLayers);
    });

    test('Buenos Aires has 135 official Partido labels inside its extent', () {
      final labels = baJson['layers']['departmentLabels'] as List;
      final names = labels.map((raw) => (raw as Map)['name']).toSet();
      final bbox = (baJson['bbox'] as List)
          .map((value) => (value as num).toDouble())
          .toList();

      expect(labels, hasLength(135));
      expect(names, hasLength(135));
      expect(names, containsAll(['La Plata', 'Tandil', 'Morón']));
      expect(baJson['departmentLabelSource'], contains('INDEC WFS'));
      expect(baJson['departmentLabelSource'], contains('cpr=06'));
      expect(baJson['departmentLabelSource'], contains('gna=Partido'));
      final visibleCountsByZoom = <double, int>{
        for (final zoom in [7.0, 7.7, 8.6, 9.4])
          zoom: labels
              .where((raw) => ((raw as Map)['minZoom'] as num) <= zoom)
              .length,
      };
      expect(visibleCountsByZoom, {7.0: 15, 7.7: 47, 8.6: 88, 9.4: 135});
      expect(
        baJson['departmentLabelSource'],
        contains('spherical area in km2'),
      );
      for (final raw in labels) {
        final label = raw as Map;
        expect(label.keys.toSet(), {'name', 'lat', 'lon', 'minZoom'});
        expect(label['minZoom'], anyOf(7.0, 7.7, 8.6, 9.4));
        final lat = (label['lat'] as num).toDouble();
        final lon = (label['lon'] as num).toDouble();
        expect(
          lat.isFinite && lon.isFinite,
          isTrue,
          reason: '${label['name']}',
        );
        expect(
          lat,
          inInclusiveRange(bbox[1], bbox[3]),
          reason: '${label['name']}',
        );
        expect(
          lon,
          inInclusiveRange(bbox[0], bbox[2]),
          reason: '${label['name']}',
        );
      }
    });

    test('Buenos Aires administrative boundaries reuse official line data', () {
      final boundaries = baJson['layers']['departmentBoundaries'] as List;

      expect(baJson['source'], contains('Instituto Geografico Nacional'));
      expect(boundaries, isNotEmpty);
      for (final boundary in boundaries) {
        expect(boundary, isA<List>());
        expect((boundary as List).length, greaterThanOrEqualTo(2));
      }
    });

    test('has the 19 unique official Santa Fe department labels', () {
      const expectedNames = {
        '9 de Julio',
        'Belgrano',
        'Caseros',
        'Castellanos',
        'Constitución',
        'Garay',
        'General López',
        'General Obligado',
        'Iriondo',
        'La Capital',
        'Las Colonias',
        'Rosario',
        'San Cristóbal',
        'San Javier',
        'San Jerónimo',
        'San Justo',
        'San Lorenzo',
        'San Martín',
        'Vera',
      };
      final labels = sfJson['layers']['departmentLabels'] as List;
      final names = labels.map((label) => (label as Map)['name']).toSet();

      expect(labels, hasLength(19));
      expect(names, expectedNames);
      for (final label in labels.cast<Map>()) {
        expect(label.keys.toSet(), {'name', 'lat', 'lon'});
        expect((label['lat'] as num).toDouble().isFinite, isTrue);
        expect((label['lon'] as num).toDouble().isFinite, isTrue);
      }
    });

    test('majorCities entries have the same shape as Buenos Aires', () {
      final city = (sfJson['layers']['majorCities'] as List).first as Map;
      expect(city.keys, containsAll({'name', 'lat', 'lon', 'importance'}));
      expect(city['importance'], anyOf('primary', 'secondary'));
    });

    test('Bahía Blanca, La Plata and Mar del Plata remain primary cities', () {
      final primaryCities = {
        for (final raw in (baJson['layers']['majorCities'] as List).cast<Map>())
          if (raw['importance'] == 'primary') raw['name'] as String,
      };

      expect(
        primaryCities,
        containsAll({'Bahía Blanca', 'La Plata', 'Mar del Plata'}),
      );
    });

    test('shared locality names retain province-specific official points', () {
      expect(sfJson['bbox'], isNot(baJson['bbox']));
      final sfCities = (sfJson['layers']['majorCities'] as List).cast<Map>();
      final baCities = (baJson['layers']['majorCities'] as List).cast<Map>();
      final sharedNames = {'Avellaneda', 'Las Toscas', 'San Justo'};
      for (final name in sharedNames) {
        final santaFeCity = sfCities.firstWhere((city) => city['name'] == name);
        final buenosAiresCity = baCities.firstWhere(
          (city) => city['name'] == name,
        );
        expect(buenosAiresCity['provinceCode'], '06');
        final distance =
            (((santaFeCity['lat'] as num).toDouble() -
                    (buenosAiresCity['lat'] as num).toDouble())
                .abs() +
            ((santaFeCity['lon'] as num).toDouble() -
                    (buenosAiresCity['lon'] as num).toDouble())
                .abs());
        expect(distance, greaterThan(1));
      }
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

      expect(
        found,
        isNotNull,
        reason: 'expected at least one z4 tile with features',
      );
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
      expect(
        location!.assetPath,
        'assets/pdfs_santa_fe/mapa_suelos_santa_fe.pdf',
      );
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
