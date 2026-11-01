import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/offline_reference_map_layer.dart';

import '../tool/build_reference_map.dart' show buildBuenosAiresLocalityRecords;

void main() {
  final document =
      jsonDecode(
            File('assets/maps/agronomic_reference_map.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final localities =
      (document['layers'] as Map<String, dynamic>)['majorCities'] as List;

  group('Buenos Aires official locality point coverage', () {
    Map<String, dynamic> named(String name) => localities
        .cast<Map<String, dynamic>>()
        .singleWhere((record) => record['name'] == name);

    test(
      'retains curated Salto and Chacabuco points and adds Carmen de Areco',
      () {
        final salto = named('Salto');
        expect(salto['sourceId'], '06714060');
        expect(salto['departmentId'], '06714');
        expect(salto['importance'], 'secondary');
        expect(salto['officialSupplement'], isNull);

        final chacabuco = named('Chacabuco');
        expect(chacabuco['sourceId'], '06210020');
        expect(chacabuco['departmentName'], 'Chacabuco');
        expect(chacabuco['importance'], 'secondary');

        final carmen = named('Carmen de Areco');
        expect(carmen['sourceId'], '06161010');
        expect(carmen['sourceCategory'], 'Localidad simple');
        expect(carmen['departmentId'], '06161');
        expect(carmen['departmentName'], 'Carmen de Areco');
        expect(carmen['lat'], closeTo(-34.376662079, 0.000001));
        expect(carmen['lon'], closeTo(-59.822696533, 0.000001));
        expect(carmen['minZoom'], 9.5);
        expect(carmen['fadeInEndZoom'], 10.3);
        expect(carmen['officialSupplement'], isTrue);
      },
    );

    test(
      'includes distributed named settlements with official Partido IDs',
      () {
        for (final name in [
          'Junín',
          'Mercedes',
          'Bahía Blanca',
          'Mar del Plata',
          'La Plata',
          'Carmen de Areco',
          'Bahía San Blas',
          'Carmen de Patagones',
        ]) {
          final locality = named(name);
          expect(locality['sourceId'], isA<String>());
          expect(locality['departmentId'], isA<String>());
          expect(locality['provinceCode'], '06');
          expect((locality['lat'] as num).isFinite, isTrue);
          expect((locality['lon'] as num).isFinite, isTrue);
        }
      },
    );

    test(
      'stores one unique official source ID per canonical locality point',
      () {
        final records = localities.cast<Map<String, dynamic>>();
        final ids = records.map((record) => record['sourceId']).toSet();
        expect(records.length, 850);
        expect(ids.length, records.length);
        expect(records, hasLength(850));
        expect(
          records.where((record) => record['officialSupplement'] == true),
          hasLength(820),
        );
        expect(
          document['localitySource'],
          contains('GeoRef Argentina API v2.0'),
        );
        expect(document['localitySource'], contains('retrieved 2026-10-31'));
      },
    );

    test('keeps added points progressively tiered by official category', () {
      final added = localities.cast<Map<String, dynamic>>().where(
        (record) => record['officialSupplement'] == true,
      );
      expect(
        added.where(
          (record) =>
              record['sourceCategory'] == 'Localidad simple' ||
              record['sourceCategory'] == 'Componente de localidad compuesta',
        ),
        isNotEmpty,
      );
      for (final record in added) {
        if (record['sourceCategory'] == 'Entidad') {
          expect(record['minZoom'], 11.5);
          expect(record['fadeInEndZoom'], 12.3);
          expect(record['importance'], 'quaternary');
        } else {
          expect(record['minZoom'], 9.5);
          expect(record['fadeInEndZoom'], 10.3);
          expect(record['importance'], 'tertiary');
        }
      }
    });
  });

  group('Buenos Aires locality zoom and Partido priority', () {
    test('fades simple and compound localities at close zoom', () {
      for (final category in [
        'Localidad simple',
        'Componente de localidad compuesta',
      ]) {
        expect(
          buenosAiresLocalityVisibilityAtZoom(category: category, zoom: 9.4),
          0,
        );
        expect(
          buenosAiresLocalityVisibilityAtZoom(category: category, zoom: 9.9),
          closeTo(0.5, 1e-12),
        );
        expect(
          buenosAiresLocalityVisibilityAtZoom(category: category, zoom: 10.3),
          1,
        );
      }
    });

    test('reveals entities only at the more detailed zoom tier', () {
      expect(
        buenosAiresLocalityVisibilityAtZoom(category: 'Entidad', zoom: 11.4),
        0,
      );
      expect(
        buenosAiresLocalityVisibilityAtZoom(category: 'Entidad', zoom: 11.9),
        closeTo(0.5, 1e-12),
      );
      expect(
        buenosAiresLocalityVisibilityAtZoom(category: 'Entidad', zoom: 12.3),
        1,
      );
    });

    test(
      'suppresses only the Partido associated with the accepted locality',
      () {
        expect(
          shouldSuppressPartidoForLocality(
            partidoName: 'Carmen de Areco',
            localityPartidoNames: {'carmen de areco'},
            legacyLocalityNames: {},
          ),
          isTrue,
        );
        expect(
          shouldSuppressPartidoForLocality(
            partidoName: 'Carmen de Areco',
            localityPartidoNames: {'salto'},
            legacyLocalityNames: {},
          ),
          isFalse,
        );
        expect(
          shouldSuppressPartidoForLocality(
            partidoName: 'Salto',
            localityPartidoNames: {},
            legacyLocalityNames: {'Salto'},
          ),
          isTrue,
        );
      },
    );
  });

  test(
    'generator preserves legacy points and resolves duplicate categories',
    () {
      Map<String, dynamic> source({
        required String id,
        required String name,
        required String category,
        required String departmentId,
        required String departmentName,
        required double lat,
        required double lon,
      }) => {
        'id': id,
        'nombre': name,
        'categoria': category,
        'provincia': {'id': '06'},
        'departamento': {'id': departmentId, 'nombre': departmentName},
        'centroide': {'lat': lat, 'lon': lon},
      };

      final records = buildBuenosAiresLocalityRecords(
        officialRecords: [
          source(
            id: '06161010',
            name: 'Carmen de Areco',
            category: 'Localidad simple',
            departmentId: '06161',
            departmentName: 'Carmen de Areco',
            lat: -34.376662,
            lon: -59.822697,
          ),
          source(
            id: '0616101001',
            name: 'Carmen de Areco',
            category: 'Entidad',
            departmentId: '06161',
            departmentName: 'Carmen de Areco',
            lat: -34.377,
            lon: -59.823,
          ),
          source(
            id: '06210020',
            name: 'Chacabuco',
            category: 'Localidad simple',
            departmentId: '06210',
            departmentName: 'Chacabuco',
            lat: -34.642,
            lon: -60.471,
          ),
          source(
            id: '06300020',
            name: 'Chacabuco',
            category: 'Localidad simple',
            departmentId: '06300',
            departmentName: 'Hipólito Yrigoyen',
            lat: -36,
            lon: -61,
          ),
        ],
        existingRecords: [
          {
            'name': 'Chacabuco',
            'lat': -34.642,
            'lon': -60.471,
            'importance': 'secondary',
          },
        ],
      );

      expect(records, hasLength(3));
      expect(records.first['name'], 'Chacabuco');
      expect(records.first['lat'], -34.642);
      expect(records.first['importance'], 'secondary');
      expect(records.first['sourceId'], '06210020');
      final carmen = records.singleWhere(
        (record) => record['departmentId'] == '06161',
      );
      expect(carmen['sourceId'], '06161010');
      expect(carmen['sourceCategory'], 'Localidad simple');
      expect(
        records.singleWhere(
          (record) => record['departmentId'] == '06300',
        )['name'],
        'Chacabuco',
      );
    },
  );
}
