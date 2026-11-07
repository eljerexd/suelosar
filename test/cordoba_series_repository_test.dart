import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pmtiles/pmtiles.dart';
import 'package:suelosar/constants/asset_paths.dart';
import 'package:suelosar/gis/gis_soil_series.dart';
import 'package:suelosar/gis/map_coverage.dart';
import 'package:suelosar/gis/province_config.dart';
import 'package:suelosar/gis/series_resolver.dart';
import 'package:suelosar/models/soil_card.dart';
import 'package:suelosar/repositories/cordoba_series_repository.dart';

/// Verifies the Córdoba wiring against the real generated index asset
/// (`assets/data/cordoba_series_index.json`, produced from the master PDF
/// manifest) — not a synthetic fixture. The GIS map, attribute reading and
/// catalog UI are already covered by the Buenos Aires/Santa Fe suites and
/// are unchanged for Córdoba.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CordobaSeriesRepository — real index asset', () {
    late CordobaSeriesRepository repository;

    setUp(() {
      CordobaSeriesRepository.resetCacheForTesting();
      repository = CordobaSeriesRepository();
    });

    test('pdfAsset points at the consolidated Córdoba PDF', () async {
      expect(await repository.pdfAsset, AssetPaths.cordobaSeriesPdf);
    });

    // 358 from carta_suelo_50mil_2025 + 51 from carta_suelo_100mil_2025
    // (Parte 11: unified into one 409-series/833-page edition of the PDF).
    test('indexes the 409 documented series', () async {
      expect(await repository.loadAllSeries(), hasLength(409));
    });

    test(
      'includes series documented from the 1:100.000 carta (Parte 10-11)',
      () async {
        final achalaI = await repository.findByName('ACHALA I');
        expect(achalaI, isNotNull);
        expect(achalaI!.startPage, lessThanOrEqualTo(achalaI.endPage));

        final sanJose = await repository.findByName('San José de las Salinas');
        expect(sanJose, isNotNull);
        expect(sanJose!.name, 'SAN JOSÉ DE LAS SALINAS');
      },
    );

    // Page ranges spot-checked against the consolidated PDF's own text
    // during index generation ("Serie <name>" starts each startPage).
    test('resolves accented names keeping the GIS spelling', () async {
      final aaron = await repository.findByName('AARÓN CASTELLANOS');
      expect(aaron, isNotNull);
      expect(aaron!.name, 'AARÓN CASTELLANOS');
      expect(aaron.startPage, lessThanOrEqualTo(aaron.endPage));

      final vicente = await repository.findByName('VICENTE AGÜERO');
      expect(vicente, isNotNull);
      expect(vicente!.name, 'VICENTE AGÜERO');
      expect(vicente.startPage, lessThanOrEqualTo(vicente.endPage));
    });

    test('lookup ignores case, accents and separators', () async {
      final canonical = await repository.findByName('VICENTE AGÜERO');
      for (final spelling in [
        'Vicente Agüero',
        'vicente aguero',
        'VICENTE_AGUERO',
      ]) {
        final entry = await repository.findByName(spelling);
        expect(entry, isNotNull, reason: spelling);
        expect(entry!.name, canonical!.name, reason: spelling);
        expect(entry.startPage, canonical.startPage, reason: spelling);
      }
    });

    test('non-series components and unknown values return null', () async {
      // Lowercase map-unit components ("suelos menores", "roca expuesta")
      // stay in the GIS data on purpose and simply have no description.
      expect(await repository.findByName('suelos menores'), isNull);
      expect(await repository.findByName('roca expuesta'), isNull);
      expect(await repository.findByName('NO EXISTE'), isNull);
      expect(await repository.findByName(''), isNull);
    });

    test('every entry has a valid range inside the 833-page PDF', () async {
      for (final entry in await repository.loadAllSeries()) {
        expect(entry.startPage, greaterThanOrEqualTo(1), reason: entry.name);
        expect(
          entry.endPage,
          greaterThanOrEqualTo(entry.startPage),
          reason: entry.name,
        );
        expect(entry.endPage, lessThanOrEqualTo(833), reason: entry.name);
      }
    });

    test('names are unique', () async {
      final all = await repository.loadAllSeries();
      expect(all.map((entry) => entry.name).toSet(), hasLength(all.length));
    });
  });

  group('CordobaSeriesResolver', () {
    setUp(CordobaSeriesRepository.resetCacheForTesting);

    test('resolves a GIS series to its page range in the shared PDF', () async {
      final resolver = CordobaSeriesResolver(CordobaSeriesRepository());
      final location = await resolver.resolve(
        const GisSoilSeries(name: 'AARÓN CASTELLANOS', percentage: '60'),
      );
      expect(location, isNotNull);
      expect(location!.assetPath, AssetPaths.cordobaSeriesPdf);
      expect(location.startPage, isNotNull);
      expect(location.endPage, greaterThanOrEqualTo(location.startPage!));
    });

    test('returns null for a component that is not a series', () async {
      final resolver = CordobaSeriesResolver(CordobaSeriesRepository());
      expect(
        await resolver.resolve(
          const GisSoilSeries(name: 'suelos menores', percentage: '10'),
        ),
        isNull,
      );
    });
  });

  group('ProvinceConfig.cordoba', () {
    test('points at the Córdoba assets, not the other provinces\' ', () {
      final config = ProvinceConfig.cordoba;
      expect(config.id, 'cordoba');
      expect(config.pmtilesAsset, AssetPaths.cordobaGisPmTiles);
      expect(config.pmtilesVersionAsset, AssetPaths.cordobaGisPmTilesVersion);
      expect(config.pmtilesAsset, isNot(AssetPaths.gisPmTiles));
      expect(config.pmtilesAsset, isNot(AssetPaths.santaFeGisPmTiles));
      expect(config.seriesResolver, isA<CordobaSeriesResolver>());
      expect(config.showPolygonUnitSymbols, isFalse);
      expect(config.referenceMapAsset, AssetPaths.cordobaAgronomicReferenceMap);
      expect(config.referenceMapAsset, isNot(AssetPaths.agronomicReferenceMap));
      expect(
        config.referenceMapAsset,
        isNot(AssetPaths.santaFeAgronomicReferenceMap),
      );
    });

    test('the other two provinces keep their own reference basemaps', () {
      expect(
        ProvinceConfig.buenosAires.referenceMapAsset,
        AssetPaths.agronomicReferenceMap,
      );
      expect(
        ProvinceConfig.santaFe.referenceMapAsset,
        AssetPaths.santaFeAgronomicReferenceMap,
      );
    });

    test('Buenos Aires stays the default/first coverage', () {
      expect(MapCoverage.all.first.id, 'buenos_aires');
      expect(
        MapCoverage.all.map((coverage) => coverage.id),
        containsAllInOrder(['buenos_aires', 'santa_fe', 'cordoba']),
      );
    });

    test(
      'Córdoba coverage bounds contain the province, not its neighbours',
      () {
        final bounds = MapCoverage.cordoba.bounds;
        // Córdoba capital.
        expect(bounds.containsPoint(-31.4201, -64.1888), isTrue);
        // Rosario (Santa Fe) must NOT fall inside Córdoba's archive extent.
        expect(bounds.containsPoint(-32.9442, -60.6505), isFalse);
      },
    );

    test('Córdoba coverage encompasses the published PMTiles extent', () async {
      final archive = await PmTilesArchive.fromFile(
        File(AssetPaths.cordobaGisPmTiles),
      );
      addTearDown(archive.close);
      final southwest = archive.header.minPosition;
      final northeast = archive.header.maxPosition;
      final bounds = MapCoverage.cordoba.bounds;

      expect(
        bounds.minLatitude,
        lessThanOrEqualTo(southwest.latitude),
      );
      expect(
        bounds.maxLatitude,
        greaterThanOrEqualTo(northeast.latitude),
      );
      expect(
        bounds.minLongitude,
        lessThanOrEqualTo(southwest.longitude),
      );
      expect(
        bounds.maxLongitude,
        greaterThanOrEqualTo(northeast.longitude),
      );
    });
  });

  group(
    'Córdoba reference basemap (real asset, built by tool/build_reference_map.dart)',
    () {
      late Map<String, dynamic> cordobaJson;
      late Map<String, dynamic> buenosAiresJson;

      setUpAll(() {
        // Read off disk, like the Santa Fe basemap test: no rootBundle needed
        // to prove the file's own shape.
        cordobaJson =
            jsonDecode(
                  File(
                    AssetPaths.cordobaAgronomicReferenceMap,
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        buenosAiresJson =
            jsonDecode(
                  File(AssetPaths.agronomicReferenceMap).readAsStringSync(),
                )
                as Map<String, dynamic>;
      });

      test('the asset exists and is EPSG:4326, as the loader demands', () {
        expect(
          File(AssetPaths.cordobaAgronomicReferenceMap).existsSync(),
          isTrue,
        );
        expect(cordobaJson['crs'], 'EPSG:4326');
        expect(cordobaJson['schema'], buenosAiresJson['schema']);
      });

      test(
        'shares the reference layer schema with Buenos Aires and Santa Fe',
        () {
          final cordobaKeys = (cordobaJson['layers'] as Map).keys.toSet();
          final buenosAiresKeys = (buenosAiresJson['layers'] as Map).keys
              .toSet();
          final santaFeJson =
              jsonDecode(
                    File(
                      AssetPaths.santaFeAgronomicReferenceMap,
                    ).readAsStringSync(),
                  )
                  as Map<String, dynamic>;
          final santaFeKeys = (santaFeJson['layers'] as Map).keys.toSet();
          expect(cordobaKeys, containsAll(buenosAiresKeys));
          expect(cordobaKeys, containsAll(santaFeKeys));
          expect(cordobaKeys, contains('departmentLabels'));
        },
      );

      test('departmentLabels covers all 26 real departments, each inside the '
          'coverage', () {
        final labels = cordobaJson['layers']['departmentLabels'] as List;
        expect(labels, hasLength(26));
        final names = labels.map((raw) => (raw as Map)['name']).toSet();
        expect(names, hasLength(26));
        expect(names, contains('Capital'));
        final bbox = (cordobaJson['bbox'] as List)
            .map((value) => (value as num).toDouble())
            .toList();
        for (final raw in labels) {
          final label = raw as Map;
          final lat = (label['lat'] as num).toDouble();
          final lon = (label['lon'] as num).toDouble();
          expect(
            lat.isFinite && lon.isFinite,
            isTrue,
            reason: '${label['name']}',
          );
          // The centroid comes straight from IGN's own department polygon,
          // never clipped to the working bbox (unlike the line layers) — a
          // department whose true geometry pokes past the PMTiles-derived
          // bbox margin (e.g. Minas, on the sparse western edge) is real
          // data, not a bug, so this allows the same small overshoot the
          // line-vertex check above does.
          expect(
            lat,
            inInclusiveRange(bbox[1] - 0.5, bbox[3] + 0.5),
            reason: '${label['name']}',
          );
          expect(
            lon,
            inInclusiveRange(bbox[0] - 0.5, bbox[2] + 0.5),
            reason: '${label['name']}',
          );
        }
      });

      test('majorCities entries have the same shape as Buenos Aires', () {
        final cities = cordobaJson['layers']['majorCities'] as List;
        expect(cities, isNotEmpty);
        final sourceIds = <String>{};
        for (final raw in cities) {
          final city = raw as Map;
          expect(city.keys, containsAll({'name', 'lat', 'lon', 'importance'}));
          if (city['officialSupplement'] == true) {
            expect(city['provinceCode'], '14');
            expect(city['sourceId'], isA<String>());
            expect(sourceIds.add(city['sourceId'] as String), isTrue);
            expect(city['departmentId'], isA<String>());
            expect(city['departmentName'], isA<String>());
            expect(city['markerRadius'], 2.3);
          } else {
            expect(city['importance'], anyOf('primary', 'secondary'));
          }
        }
      });

      test('is Córdoba\'s own data, not another province\'s', () {
        expect(cordobaJson['bbox'], isNot(buenosAiresJson['bbox']));
        expect(
          (cordobaJson['layers']['majorCities'] as List).map(
            (city) => (city as Map)['name'],
          ),
          contains('Córdoba'),
        );
      });

      test('every line vertex is finite and near the provincial boundary', () {
        // Guards the same int-vs-double decoding the Santa Fe boundary test
        // covers. Córdoba's soil archive bbox does not include the province's
        // northern edge, so reference linework is checked against the complete
        // stored provincial boundary instead.
        final boundary =
            (cordobaJson['layers']['provincialBoundaries'] as List).first
                as List;
        final boundaryLongitudes = boundary
            .map((point) => ((point as List)[0] as num).toDouble())
            .toList();
        final boundaryLatitudes = boundary
            .map((point) => ((point as List)[1] as num).toDouble())
            .toList();
        final west = boundaryLongitudes.reduce(math.min);
        final east = boundaryLongitudes.reduce(math.max);
        final south = boundaryLatitudes.reduce(math.min);
        final north = boundaryLatitudes.reduce(math.max);
        var vertices = 0;
        for (final entry in (cordobaJson['layers'] as Map).entries) {
          if (entry.key == 'majorCities' || entry.key == 'departmentLabels') {
            continue;
          }
          for (final line in entry.value as List) {
            for (final point in line as List) {
              final coordinates = point as List;
              final longitude = (coordinates[0] as num).toDouble();
              final latitude = (coordinates[1] as num).toDouble();
              expect(longitude.isFinite && latitude.isFinite, isTrue);
              // Reference layers use a 0.2-degree context margin and clipping
              // retains the first outside source vertex, so allow 0.3 degrees.
              expect(longitude, inInclusiveRange(west - 0.3, east + 0.3));
              expect(latitude, inInclusiveRange(south - 0.3, north + 0.3));
              vertices++;
            }
          }
        }
        expect(vertices, greaterThan(1000));
      });

      test('all clipped reference layers cover northern Córdoba', () {
        const formerlyClippedNorth = -30.10;
        for (final layerName in const [
          'departmentBoundaries',
          'majorRivers',
          'nationalRoads',
          'provincialRoads',
        ]) {
          final lines = cordobaJson['layers'][layerName] as List;
          final northernmost = lines
              .expand((line) => line as List)
              .map((point) => ((point as List)[1] as num).toDouble())
              .reduce(math.max);
          expect(
            northernmost,
            greaterThan(formerlyClippedNorth),
            reason: '$layerName must not stop at the former working bbox',
          );
        }
      });

      test('provincial boundary is present, so the download banner can outline '
          'Córdoba before its PMTiles is installed', () {
        final rings = cordobaJson['layers']['provincialBoundaries'] as List;
        expect(rings, isNotEmpty);
        expect((rings.first as List).length, greaterThan(50));
      });
    },
  );

  group('SoilCard.cordoba', () {
    setUp(CordobaSeriesRepository.resetCacheForTesting);

    test('favorite identifiers cannot collide with the other provinces', () {
      const entry = CordobaSeriesEntry(
        name: 'AARÓN CASTELLANOS',
        startPage: 7,
        endPage: 8,
      );
      final card = SoilCard.cordoba(
        entry,
        pdfAsset: AssetPaths.cordobaSeriesPdf,
      );
      expect(card.province, SoilCardProvince.cordoba);
      expect(card.title, 'AARÓN CASTELLANOS');
      expect(card.favoriteIdentifier, 'cordoba:AARÓN CASTELLANOS');
      expect(
        card.favoriteIdentifier.startsWith(
          SoilCard.santaFeFavoriteIdentifierPrefix,
        ),
        isFalse,
      );
      // Buenos Aires identifiers are bare PDF filenames.
      expect(card.favoriteIdentifier.endsWith('.pdf'), isFalse);
      expect(card.location.startPage, 7);
      expect(card.location.endPage, 8);
    });
  });
}
