import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/engine/maplibre_geographic_annotations.dart';
import 'package:suelosar/gis/engine/maplibre_reference_basemap.dart';
import 'package:suelosar/gis/engine/soil_map_engine.dart';

void main() {
  group('MapLibreGeographicAnnotationData', () {
    test('preserves city identity, coordinates and primary ordering', () {
      final data = MapLibreGeographicAnnotationData.cities([
        const MapLibreReferenceCity(
          id: 'locality-secondary',
          name: 'Villa Nueva',
          point: LatLng(-32.9, -68.8),
          isPrimary: false,
        ),
        const MapLibreReferenceCity(
          id: 'locality-primary',
          name: 'Mendoza',
          point: LatLng(-32.89, -68.84),
          isPrimary: true,
        ),
      ]);

      final features = _features(data);
      expect(features, hasLength(2));
      expect(features[0]['id'], 'locality-secondary');
      expect(features[0]['geometry']['coordinates'], [-68.8, -32.9]);
      expect(features[0]['properties']['name'], 'Villa Nueva');
      expect(features[0]['properties']['isPrimary'], isFalse);
      expect(features[0]['properties']['sortKey'], 100000);
      expect(
        features[0]['properties']['labelImage'],
        MapLibreGeographicAnnotationData.cityLabelImageId('locality-secondary'),
      );
      expect(features[1]['properties']['sortKey'], 1);
    });

    test('serializes administrative labels after locality labels', () {
      final features = _features(
        MapLibreGeographicAnnotationData.cities([
          const MapLibreReferenceCity(
            id: 'partido',
            name: 'Arrecifes',
            point: LatLng(-34.06, -60.10),
            isPrimary: false,
            isAdministrative: true,
            provinceId: 'buenos_aires',
            minZoom: 7.7,
          ),
          const MapLibreReferenceCity(
            id: 'city',
            name: 'Salto',
            point: LatLng(-34.29, -60.25),
            isPrimary: false,
          ),
        ]),
      );

      expect(features[0]['properties']['isAdministrative'], isTrue);
      expect(features[0]['properties']['sortKey'], 200000);
      expect(features[0]['properties']['provinceId'], 'buenos_aires');
      expect(features[0]['properties']['minZoomTier'], 1);
      expect(features[1]['properties']['isAdministrative'], isFalse);
      expect(features[1]['properties']['sortKey'], 100001);
    });

    test(
      'uses the enhanced Buenos Aires label image only with soil polygons',
      () {
        const partido = MapLibreReferenceCity(
          id: 'partido-ba',
          name: 'Arrecifes',
          point: LatLng(-34.06, -60.10),
          isPrimary: false,
          isAdministrative: true,
          provinceId: 'buenos_aires',
          minZoom: 7,
        );
        final normal = _features(
          MapLibreGeographicAnnotationData.cities([partido]),
        ).single['properties']['labelImage'];
        final enhanced = _features(
          MapLibreGeographicAnnotationData.cities(
            [partido],
            enhancedAdministrativeProvinceIds: const {'buenos_aires'},
          ),
        ).single['properties']['labelImage'];
        expect(
          normal,
          MapLibreGeographicAnnotationData.administrativeLabelImageId(
            partido.id,
            enhancedForSoilPolygons: false,
          ),
        );
        expect(
          enhanced,
          MapLibreGeographicAnnotationData.administrativeLabelImageId(
            partido.id,
            enhancedForSoilPolygons: true,
          ),
        );
        expect(enhanced, isNot(normal));
      },
    );

    test('keeps locality features when no soil polygons are available', () {
      const localities = [
        MapLibreReferenceCity(
          id: 'buenos-aires:arrecifes',
          name: 'Arrecifes',
          point: LatLng(-34.06, -60.10),
          isPrimary: false,
          provinceId: 'buenos_aires',
        ),
        MapLibreReferenceCity(
          id: 'buenos-aires:salto',
          name: 'Salto',
          point: LatLng(-34.29, -60.25),
          isPrimary: false,
          provinceId: 'buenos_aires',
        ),
      ];

      final withoutSoil = _features(
        MapLibreGeographicAnnotationData.cities(localities),
      );
      final withSoil = _features(
        MapLibreGeographicAnnotationData.cities(
          localities,
          enhancedAdministrativeProvinceIds: const {'buenos_aires'},
        ),
      );

      expect(withoutSoil, hasLength(2));
      expect(withoutSoil.map((feature) => feature['properties']['name']), [
        'Arrecifes',
        'Salto',
      ]);
      expect(
        withSoil.map((feature) => feature['id']),
        withoutSoil.map((feature) => feature['id']),
      );
      expect(
        withSoil.map((feature) => feature['geometry']),
        withoutSoil.map((feature) => feature['geometry']),
      );
    });

    test(
      'preserves personal marker properties and category sprite identity',
      () {
        final data = MapLibreGeographicAnnotationData.personalMarkers([
          const SoilMapMarkerPin(
            id: 'marker-7',
            point: LatLng(-34.2, -61.7),
            icon: Icons.place,
            categoryId: 'soil-pit',
            properties: {'label': 'Muestreo norte', 'custom': 42},
          ),
        ]);

        final feature = _features(data).single;
        expect(feature['id'], 'marker-7');
        expect(feature['geometry']['coordinates'], [-61.7, -34.2]);
        expect(feature['properties'], containsPair('label', 'Muestreo norte'));
        expect(feature['properties'], containsPair('custom', 42));
        expect(feature['properties'], containsPair('markerId', 'marker-7'));
        expect(feature['properties'], containsPair('category', 'soil-pit'));
        expect(
          feature['properties']['iconImage'],
          'suelosar-personal-marker-soil-pit',
        );
      },
    );

    test('serializes current location and omits a missing location', () {
      final visible = _features(
        MapLibreGeographicAnnotationData.currentLocation(
          point: const LatLng(-34.6, -58.4),
          accuracyMeters: 18.5,
          hasAccuracy: true,
        ),
      ).single;
      expect(visible['geometry']['coordinates'], [-58.4, -34.6]);
      expect(visible['properties']['latitude'], -34.6);
      expect(visible['properties']['accuracyMeters'], 18.5);
      expect(visible['properties']['hasAccuracy'], isTrue);

      expect(
        _features(
          MapLibreGeographicAnnotationData.currentLocation(
            point: null,
            accuracyMeters: 0,
            hasAccuracy: false,
          ),
        ),
        isEmpty,
      );
      expect(
        _features(
          MapLibreGeographicAnnotationData.currentLocation(
            point: const LatLng(double.nan, -58.4),
            accuracyMeters: double.infinity,
            hasAccuracy: true,
          ),
        ),
        isEmpty,
      );
    });
  });
}

List<Map<String, dynamic>> _features(String data) {
  final collection = jsonDecode(data) as Map<String, dynamic>;
  return (collection['features'] as List).cast<Map<String, dynamic>>();
}
