import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:suelosar/gis/offline_reference_map_layer.dart';
import 'package:suelosar/gis/pmtiles_delivery.dart';

import '../tool/build_reference_map.dart'
    show buildOfficialProvinceLocalityRecords;

void main() {
  Map<String, dynamic> document(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

  group('Santa Fe and Cordoba reference coverage', () {
    for (final (province, code, path, departments) in [
      (
        'Santa Fe',
        '82',
        'assets/maps/agronomic_reference_map_santa_fe.json',
        19,
      ),
      ('Cordoba', '14', 'assets/maps/agronomic_reference_map_cordoba.json', 26),
    ]) {
      test('$province keeps official boundaries and progressive labels', () {
        final map = document(path);
        final layers = map['layers'] as Map<String, dynamic>;
        expect(map['source'], contains('Instituto Geografico Nacional'));
        expect(layers['departmentBoundaries'], hasLength(departments));
        final labels = (layers['departmentLabels'] as List).cast<Map>();
        expect(labels, hasLength(departments));
        final zooms = progressiveJurisdictionMinZooms([
          for (final label in labels)
            LatLng(
              (label['lat'] as num).toDouble(),
              (label['lon'] as num).toDouble(),
            ),
        ]);
        expect(zooms.toSet().length, greaterThan(1));
        expect(zooms, everyElement(inInclusiveRange(7.0, 9.4)));
        expect(map['localitySource'], contains('GeoRef Argentina'));
        expect(
          (layers['majorCities'] as List).cast<Map>().where(
            (city) => city['officialSupplement'] == true,
          ),
          isNotEmpty,
        );
        final sourced = (layers['majorCities'] as List)
            .cast<Map>()
            .where((city) => city['sourceId'] != null)
            .toList();
        expect(sourced, isNotEmpty);
        expect(sourced.every((city) => city['provinceCode'] == code), isTrue);
        expect(
          sourced.map((city) => city['sourceId']).toSet().length,
          sourced.length,
        );
      });
    }

    test('keeps the established city anchors and markers unchanged', () {
      final santaFeCities =
          (document(
                    'assets/maps/agronomic_reference_map_santa_fe.json',
                  )['layers']['majorCities']
                  as List)
              .cast<Map>();
      final cordobaCities =
          (document(
                    'assets/maps/agronomic_reference_map_cordoba.json',
                  )['layers']['majorCities']
                  as List)
              .cast<Map>();
      for (final (cities, name, latitude, longitude) in [
        (santaFeCities, 'Santa Fe', -31.65516, -60.63877),
        (santaFeCities, 'Rosario', -32.94896, -60.69808),
        (cordobaCities, 'Córdoba', -31.4168, -64.18361),
        (cordobaCities, 'Villa María', -32.4135, -63.24833),
      ]) {
        final city = cities.firstWhere((item) => item['name'] == name);
        expect((city['lat'] as num).toDouble(), latitude);
        expect((city['lon'] as num).toDouble(), longitude);
        expect(city['importance'], 'primary');
      }
      final santaFeAdded = santaFeCities.firstWhere(
        (city) => city['officialSupplement'] == true,
      );
      expect(santaFeAdded['markerRadius'], 2.3);
    });
  });

  group('official locality merge', () {
    Map<String, dynamic> source({
      required String id,
      required String name,
      required String category,
      required String departmentId,
      required double latitude,
      required double longitude,
    }) => {
      'id': id,
      'nombre': name,
      'categoria': category,
      'provincia': {'id': '82'},
      'departamento': {
        'id': departmentId,
        'nombre': 'Departamento $departmentId',
      },
      'centroide': {'lat': latitude, 'lon': longitude},
    };

    test('retains curated anchors and deduplicates within each department', () {
      final existing = <Map<String, dynamic>>[
        {
          'name': 'San Justo',
          'lat': -30.001,
          'lon': -60.001,
          'importance': 'secondary',
        },
      ];
      final result = buildOfficialProvinceLocalityRecords(
        provinceCode: '82',
        existingRecords: existing,
        officialRecords: [
          source(
            id: '82001001',
            name: 'San Justo',
            category: 'Localidad simple',
            departmentId: '82001',
            latitude: -30,
            longitude: -60,
          ),
          source(
            id: '82001002',
            name: 'San Justo',
            category: 'Componente de localidad compuesta',
            departmentId: '82001',
            latitude: -30.001,
            longitude: -60.001,
          ),
          source(
            id: '82002001',
            name: 'San Justo',
            category: 'Localidad simple',
            departmentId: '82002',
            latitude: -31,
            longitude: -61,
          ),
          source(
            id: '82003001',
            name: 'Paraje Nuevo',
            category: 'Entidad',
            departmentId: '82003',
            latitude: -32,
            longitude: -62,
          ),
        ],
      );
      final curated = result.first;
      expect(curated['lat'], -30.001);
      expect(curated['lon'], -60.001);
      expect(curated['importance'], 'secondary');
      expect(curated['sourceId'], '82001002');
      expect(curated['departmentName'], 'Departamento 82001');
      expect(
        result.where((record) => record['name'] == 'San Justo'),
        hasLength(2),
      );
      final entity = result.singleWhere(
        (record) => record['name'] == 'Paraje Nuevo',
      );
      expect(entity['minZoom'], 11.5);
      expect(entity['fadeInEndZoom'], 12.3);
      expect(entity['markerRadius'], 2.3);
      expect(entity['provinceCode'], '82');
      expect(entity['officialSupplement'], isTrue);
    });

    test('rejects records belonging to a different province', () {
      final wrongProvince = source(
        id: '14001001',
        name: 'Localidad',
        category: 'Localidad simple',
        departmentId: '14001',
        latitude: -31,
        longitude: -64,
      )..['provincia'] = {'id': '14'};
      expect(
        () => buildOfficialProvinceLocalityRecords(
          provinceCode: '82',
          existingRecords: const [],
          officialRecords: [wrongProvince],
        ),
        throwsStateError,
      );
    });
  });

  test('all provinces use the enhanced boundary gate only when ready', () {
    bool shouldEnhance({
      PmtilesDeliveryStatus status = PmtilesDeliveryStatus.available,
      bool polygons = true,
      bool ready = true,
      bool hasVisible = true,
    }) => shouldUseEnhancedAdministrativeBoundaryStyle(
      deliveryStatus: status,
      soilPolygonsVisible: polygons,
      mapReady: ready,
      hasVisiblePolygons: hasVisible,
    );

    expect(shouldEnhance(), isTrue);
    expect(shouldEnhance(status: PmtilesDeliveryStatus.downloading), isFalse);
    expect(shouldEnhance(status: PmtilesDeliveryStatus.error), isFalse);
    expect(shouldEnhance(polygons: false), isFalse);
    expect(shouldEnhance(ready: false), isFalse);
    expect(shouldEnhance(hasVisible: false), isFalse);
  });

  test('administrative boundaries share both reference styles', () {
    final defaultStyle = administrativeBoundaryStyleAtZoom(
      enhancedForSoilPolygons: false,
      zoom: 10,
    );
    expect(defaultStyle.color, const Color(0xFF62695C));
    expect(defaultStyle.strokeWidth, 1.5);
    expect(defaultStyle.opacity, 0.78);

    for (final zoom in [10.0, 11.0, 12.0, 13.5, 16.0]) {
      final enhanced = administrativeBoundaryStyleAtZoom(
        enhancedForSoilPolygons: true,
        zoom: zoom,
      );
      expect(enhanced.color, const Color(0xFF252A25));
      expect(enhanced.strokeWidth, 2.5);
      expect(enhanced.opacity, enhancedBuenosAiresBoundaryOpacityAtZoom(zoom));
    }
  });

  test('Buenos Aires soil state does not restyle other province labels', () {
    expect(
      shouldEnhanceGeographicLabelForProvince(
        provinceId: 'buenos_aires',
        enhancedBuenosAiresBoundaries: true,
      ),
      isTrue,
    );
    for (final provinceId in ['santa_fe', 'cordoba']) {
      expect(
        shouldEnhanceGeographicLabelForProvince(
          provinceId: provinceId,
          enhancedBuenosAiresBoundaries: true,
        ),
        isFalse,
      );
    }
    expect(
      shouldEnhanceGeographicLabelForProvince(
        provinceId: 'buenos_aires',
        enhancedBuenosAiresBoundaries: false,
      ),
      isFalse,
    );
  });

  test('official locality visibility consumes each asset zoom range', () {
    expect(
      localityVisibilityAtZoom(
        zoom: 10.5,
        minZoom: 10,
        fadeInEndZoom: 11,
        category: 'Localidad simple',
      ),
      0.5,
    );
    expect(
      localityVisibilityAtZoom(
        zoom: 9,
        minZoom: 10,
        fadeInEndZoom: 11,
        category: 'Localidad simple',
      ),
      0,
    );
    expect(
      localityVisibilityAtZoom(
        zoom: 12,
        minZoom: 10,
        fadeInEndZoom: 11,
        category: 'Localidad simple',
      ),
      1,
    );
    expect(
      localityVisibilityAtZoom(
        zoom: 9.9,
        minZoom: null,
        fadeInEndZoom: null,
        category: 'Localidad simple',
      ),
      closeTo(0.5, 0.0001),
    );
  });
}
