import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/engine/maplibre_reference_basemap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'converts all bundled reference lines without changing coordinates',
    () async {
      const paths = [
        'assets/maps/agronomic_reference_map.json',
        'assets/maps/agronomic_reference_map_santa_fe.json',
        'assets/maps/agronomic_reference_map_cordoba.json',
      ];
      final documents = await Future.wait(
        paths.map(
          (path) async => MapEntry(path, await rootBundle.loadString(path)),
        ),
      );
      final decoded = {
        for (final entry in documents)
          entry.key: jsonDecode(entry.value) as Map<String, dynamic>,
      };
      final converted = MapLibreReferenceBasemapData.fromAssetJson(documents);

      for (final category in MapLibreReferenceBasemapData.lineCategories) {
        final expectedLines = paths.fold<int>(
          0,
          (count, path) =>
              count +
              ((decoded[path]!['layers'] as Map)[category] as List).length,
        );
        expect(
          converted.featureCount(category),
          expectedLines,
          reason: category,
        );

        final featureCollection =
            jsonDecode(converted.featureCollections[category]!) as Map;
        final firstFeature = featureCollection['features'].first as Map;
        final source = firstFeature['properties']['sourceAsset'] as String;
        final sourceIndex = firstFeature['properties']['sourceIndex'] as int;
        if (category == 'departmentBoundaries') {
          expect(firstFeature['properties']['provinceId'], switch (source) {
            'assets/maps/agronomic_reference_map.json' => 'buenos_aires',
            'assets/maps/agronomic_reference_map_santa_fe.json' => 'santa_fe',
            'assets/maps/agronomic_reference_map_cordoba.json' => 'cordoba',
            _ => fail('Unexpected administrative geometry source: $source'),
          });
        }
        final original =
            ((decoded[source]!['layers'] as Map)[category]
                as List)[sourceIndex];
        expect(firstFeature['geometry']['coordinates'], original);
        expect(firstFeature['id'], '$source:$category:$sourceIndex');
      }

      final expectedCities = <(String, String, int, Map)>[];
      for (final path in paths) {
        final originalCities =
            ((decoded[path]!['layers'] as Map)['majorCities'] as List?) ??
            const [];
        for (var index = 0; index < originalCities.length; index++) {
          expectedCities.add((
            path,
            'majorCities',
            index,
            originalCities[index] as Map,
          ));
        }
        final originalDepartments =
            ((decoded[path]!['layers'] as Map)['departmentLabels'] as List?) ??
            const [];
        for (var index = 0; index < originalDepartments.length; index++) {
          expectedCities.add((
            path,
            'departmentLabels',
            index,
            originalDepartments[index] as Map,
          ));
        }
      }
      expect(converted.cities, hasLength(expectedCities.length));
      for (final city in converted.cities) {
        final sourceParts = city.id.split(
          RegExp(r':(majorCities|departmentLabels):'),
        );
        final category = city.isAdministrative
            ? 'departmentLabels'
            : 'majorCities';
        final sourceIndex = int.parse(city.id.split(':').last);
        final original = expectedCities
            .singleWhere(
              (item) =>
                  item.$1 == sourceParts.first &&
                  item.$2 == category &&
                  item.$3 == sourceIndex,
            )
            .$4;
        expect(city.name, original['name']);
        expect(city.point.latitude, original['lat']);
        expect(city.point.longitude, original['lon']);
        expect(city.isPrimary, original['importance'] == 'primary');
        expect(city.isAdministrative, category == 'departmentLabels');
        expect(city.provinceId, switch (sourceParts.first) {
          'assets/maps/agronomic_reference_map.json' => 'buenos_aires',
          'assets/maps/agronomic_reference_map_santa_fe.json' => 'santa_fe',
          'assets/maps/agronomic_reference_map_cordoba.json' => 'cordoba',
          _ => 'unknown',
        });
        if (city.isAdministrative) {
          expect(city.minZoom, anyOf(7.0, 7.7, 8.6, 9.4));
          expect(city.minZoomTier, inInclusiveRange(0, 3));
        }
      }
      expect(converted.cities.first.isPrimary, isTrue);
      expect(
        converted.cities.where((city) => city.isAdministrative),
        hasLength(26 + 135 + 19),
      );
      final departmentFeatures =
          ((jsonDecode(converted.featureCollections['departmentBoundaries']!)
                      as Map)['features']
                  as List)
              .cast<Map>();
      expect(
        {
          for (final provinceId in MapLibreReferenceBasemapData.provinceIds)
            provinceId: departmentFeatures
                .where(
                  (feature) =>
                      feature['properties']['provinceId'] == provinceId,
                )
                .length,
        },
        {'buenos_aires': 182, 'santa_fe': 19, 'cordoba': 26},
      );
    },
  );

  test('every reference category has a native source identifier', () {
    expect(
      MapLibreReferenceBasemapData.sourceIdsByCategory.keys,
      containsAll(MapLibreReferenceBasemapData.lineCategories),
    );
    expect(
      MapLibreReferenceBasemapData.sourceIdsByCategory.values.toSet(),
      hasLength(MapLibreReferenceBasemapData.lineCategories.length),
    );
    expect(
      MapLibreReferenceBasemapData.sourceIdForCategory('departmentBoundaries'),
      'suelosar-reference-department-boundaries-source',
    );
    expect(
      () => MapLibreReferenceBasemapData.sourceIdForCategory('unknown'),
      throwsArgumentError,
    );
  });

  test(
    'prioritizes only the currently visible locality and district labels',
    () {
      const cities = [
        MapLibreReferenceCity(
          id: 'later-district',
          name: 'Partido tardío',
          point: LatLng(-34, -60),
          isPrimary: false,
          isAdministrative: true,
          minZoom: 8.6,
        ),
        MapLibreReferenceCity(
          id: 'primary-city',
          name: 'Ciudad principal',
          point: LatLng(-34, -60),
          isPrimary: true,
        ),
        MapLibreReferenceCity(
          id: 'visible-district',
          name: 'Partido visible',
          point: LatLng(-34, -60),
          isPrimary: false,
          isAdministrative: true,
          minZoom: 7,
        ),
        MapLibreReferenceCity(
          id: 'secondary-city',
          name: 'Localidad secundaria',
          point: LatLng(-34, -60),
          isPrimary: false,
        ),
      ];

      final prioritized =
          MapLibreReferenceBasemapData.prioritizeLabelRegistration(
            cities,
            zoom: 7,
          );

      expect(prioritized.map((city) => city.id), [
        'primary-city',
        'visible-district',
        'secondary-city',
        'later-district',
      ]);
      expect(prioritized, hasLength(cities.length));
    },
  );

  test('jurisdiction labels follow display zoom and stable fade rules', () {
    expect(jurisdictionLabelOpacityForTier(tier: 0, zoom: 6.99), 0);
    expect(jurisdictionLabelOpacityForTier(tier: 0, zoom: 7), 1);
    expect(jurisdictionLabelOpacityForTier(tier: 1, zoom: 7.69), 0);
    expect(jurisdictionLabelOpacityForTier(tier: 1, zoom: 7.7), 1);
    expect(
      jurisdictionLabelOpacityForTier(tier: 2, zoom: 8.6),
      closeTo(0.85, 1e-12),
    );
    expect(
      jurisdictionLabelOpacityForTier(tier: 3, zoom: 9.4),
      closeTo(0.65, 1e-12),
    );
    expect(jurisdictionLabelOpacityForTier(tier: 0, zoom: 10), 0.5);
    expect(jurisdictionLabelOpacityForTier(tier: 0, zoom: 12), 0);
  });

  test('administrative boundaries use the stable app zoom styles', () {
    final defaultStyle = administrativeBoundaryStyleAtZoom(
      enhancedForSoilPolygons: false,
      zoom: 12,
    );
    expect(defaultStyle.color, const Color(0xFF62695C));
    expect(defaultStyle.strokeWidth, 1.5);
    expect(defaultStyle.opacity, 0.78);

    final broadStyle = administrativeBoundaryStyleAtZoom(
      enhancedForSoilPolygons: true,
      zoom: 10,
    );
    expect(broadStyle.color, const Color(0xFF252A25));
    expect(broadStyle.strokeWidth, 2.5);
    expect(broadStyle.opacity, 1);

    expect(enhancedAdministrativeBoundaryOpacityAtZoom(11), 0.75);
    expect(enhancedAdministrativeBoundaryOpacityAtZoom(12), 0.5);
    expect(enhancedAdministrativeBoundaryOpacityAtZoom(13), 0.3);
    expect(enhancedAdministrativeBoundaryOpacityAtZoom(14), 0.15);
    expect(enhancedAdministrativeBoundaryOpacityAtZoom(16), 0.045);
  });

  test('rejects reference assets that are not EPSG:4326', () {
    expect(
      () => MapLibreReferenceBasemapData.fromAssetJson([
        const MapEntry('invalid.json', '{"crs":"EPSG:3857","layers":{}}'),
      ]),
      throwsFormatException,
    );
  });

  test('rejects invalid locality annotation coordinates and names', () {
    expect(
      () => MapLibreReferenceBasemapData.fromAssetJson([
        const MapEntry(
          'invalid-city.json',
          '{"crs":"EPSG:4326","layers":{"majorCities":[{"name":"","lat":-34,"lon":-58}]}}',
        ),
      ]),
      throwsFormatException,
    );
  });

  test('MapLibreEngine owns one native viewport and no FlutterMap camera', () {
    final source = File('lib/gis/engine/maplibre_engine.dart')
        .readAsStringSync();
    expect(source, contains('ml.MapLibreMap('));
    expect(source, isNot(contains('fm.FlutterMap(')));
    expect(source, isNot(contains('flutter_map/flutter_map.dart')));
    expect(source, isNot(contains('_annotationController')));
    expect(source, contains('suelosar-measure-saved-geometry'));
    expect(source, contains('suelosar-measure-active-distance-line'));
    expect(source, contains('suelosar-city-annotations'));
    expect(source, contains('suelosar-personal-marker-source'));
    expect(source, contains('suelosar-personal-marker-circles'));
    expect(source, contains('featuresAtPoint('));
    expect(source, contains('addImageFromCanvas('));
    expect(source, contains('Expression.image('));
    expect(source, isNot(contains('MapLibreGeographicAnnotationsLayer')));
    expect(source, isNot(contains('_personalMarkerAt(')));
    final fallback = File('lib/gis/engine/flutter_map_engine.dart')
        .readAsStringSync();
    expect(fallback, contains('class FlutterMapEngine'));
    expect(fallback, contains('return FlutterMap('));
  });
}
