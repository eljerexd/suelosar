import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/suelosar_data/sources/dbf_reader.dart';
import '../../../tool/suelosar_data/sources/geojson_reader.dart';
import '../../../tool/suelosar_data/sources/shapefile_reader.dart';
import 'helpers.dart';

void main() {
  group('DbfTable', () {
    const fields = <FieldSpec>[
      ('NAME', 'C', 12, 0),
      ('PORC', 'N', 5, 0),
      ('AREA', 'N', 8, 2),
      ('OK', 'L', 1, 0),
    ];

    test('reads text, numbers, logicals, blanks and deleted records', () {
      final dir = tempDir('dbf');
      final file = File(p.join(dir.path, 't.dbf'))
        ..writeAsBytesSync(
          buildDbf(fields, [
            ['Cañada', 40, '12.50', 'T'],
            ['#deleted', 'Borrado', 1, '1.00', 'F'],
            ['   ', '', '', '?'],
            [' Lead', '***', '3', 'N'],
          ]),
        );
      File(p.join(dir.path, 't.cpg')).writeAsStringSync('UTF-8');
      final table = DbfTable.open(file);
      expect(table.fields.map((f) => f.name), ['NAME', 'PORC', 'AREA', 'OK']);
      expect(table.fields[2].description, 'N(8,2)');
      expect(table.encodingName, 'UTF-8');
      final records = table.records().toList();
      expect(table.deletedRecords, 1);
      expect([for (final (index, _) in records) index], [0, 2, 3]);
      expect(records[0].$2, {
        'NAME': 'Cañada',
        'PORC': 40,
        'AREA': 12.5,
        'OK': true,
      });
      expect(records[1].$2, {
        'NAME': null,
        'PORC': null,
        'AREA': null,
        'OK': null,
      });
      expect(records[2].$2, {
        'NAME': ' Lead',
        'PORC': null,
        'AREA': 3.0,
        'OK': false,
      });
    });

    test('flags bytes that are not valid UTF-8', () {
      final dir = tempDir('dbf_bad');
      final file = File(p.join(dir.path, 't.dbf'))
        ..writeAsBytesSync(
          buildDbf(fields.sublist(0, 1), [
            [
              Uint8List.fromList([0x43, 0xF1, 0x61]),
            ], // "Cña" in Latin-1
          ]),
        );
      File(p.join(dir.path, 't.cpg')).writeAsStringSync('UTF-8');
      final table = DbfTable.open(file);
      final value = table.records().single.$2['NAME'];
      expect(value, contains('\uFFFD'));
      expect(table.encodingIssues.single.field, 'NAME');
    });

    test('defaults to Latin-1 without a .cpg and honours an override', () {
      final dir = tempDir('dbf_latin');
      final file = File(p.join(dir.path, 't.dbf'))
        ..writeAsBytesSync(
          buildDbf(fields.sublist(0, 1), [
            ['Cañada'],
          ], encoding: latin1),
        );
      final table = DbfTable.open(file);
      expect(table.encodingName, contains('sin .cpg'));
      expect(table.records().single.$2['NAME'], 'Cañada');
      expect(
        () => DbfTable.open(file, encoding: 'EBCDIC'),
        throwsFormatException,
      );
    });
  });

  group('ShapefilePolygonReader', () {
    test('groups holes with their outer ring and keeps coordinates exact', () {
      final geometry = ShapefilePolygonReader.polygonFromRings([
        square(0, 0, 10),
        hole(2, 2, 1),
        square(20, 0, 5),
        hole(21, 1, 1),
      ])!;
      expect(geometry['type'], 'MultiPolygon');
      final polygons = geometry['coordinates']! as List;
      expect(polygons, hasLength(2));
      expect((polygons[0] as List).length, 2);
      expect((polygons[1] as List).length, 2);
      expect((polygons[1] as List)[1], hole(21, 1, 1));
    });

    test(
      'a single outer ring is a Polygon; an orphan hole becomes its own polygon',
      () {
        expect(
          ShapefilePolygonReader.polygonFromRings([square(0, 0, 1)])!['type'],
          'Polygon',
        );
        final orphan = ShapefilePolygonReader.polygonFromRings([
          square(0, 0, 1),
          hole(5, 5, 1),
        ])!;
        expect(orphan['type'], 'MultiPolygon');
        expect(ShapefilePolygonReader.polygonFromRings([]), isNull);
      },
    );

    test('reads records in order, including null shapes', () {
      final dir = tempDir('shp');
      final shp = File(p.join(dir.path, 'a.shp'))
        ..writeAsBytesSync(
          buildShp([
            [square(-60, -35, 0.5)],
            null,
            [square(-61, -36, 1), hole(-60.8, -35.8, 0.1)],
          ]),
        );
      File(p.join(dir.path, 'a.prj')).writeAsStringSync(wgs84Prj);
      ShapefilePolygonReader.ensureGeographicWgs84(shp);
      final geometries = ShapefilePolygonReader(shp).geometries().toList();
      expect([for (final (i, _) in geometries) i], [0, 1, 2]);
      expect(geometries[0].$2!['coordinates'], [square(-60, -35, 0.5)]);
      expect(geometries[1].$2, isNull);
      expect((geometries[2].$2!['coordinates']! as List).length, 2);
    });

    test('rejects projected or unknown coordinate systems', () {
      final dir = tempDir('prj');
      final shp = File(p.join(dir.path, 'a.shp'))
        ..writeAsBytesSync(buildShp([]));
      expect(
        () => ShapefilePolygonReader.ensureGeographicWgs84(shp),
        throwsFormatException,
      );
      File(p.join(dir.path, 'a.prj')).writeAsStringSync(
        'PROJCS["POSGAR 94 / Argentina 5",GEOGCS["POSGAR 94"]]',
      );
      expect(
        () => ShapefilePolygonReader.ensureGeographicWgs84(shp),
        throwsFormatException,
      );
    });
  });

  group('GeoJSON readers', () {
    test('topLevelMembers slices raw values, including tricky strings', () {
      final members = topLevelMembers(
        '{"type":"Feature","properties":{"a":"x, } ] \\" y","b":[1,{"c":2}]},'
        ' "geometry" : {"type":"Point","coordinates":[-60.0,-35.10]} }',
      );
      expect(members.keys, ['type', 'properties', 'geometry']);
      expect(jsonDecode(members['properties']!), {
        'a': 'x, } ] " y',
        'b': [
          1,
          {'c': 2},
        ],
      });
      expect(
        members['geometry'],
        '{"type":"Point","coordinates":[-60.0,-35.10]}',
      );
      expect(() => topLevelMembers('{"a":1'), throwsFormatException);
    });

    test('readGeoJsonLines keeps geometry text byte-for-byte', () async {
      final dir = tempDir('geojson');
      final file = File(p.join(dir.path, 'a.geojson'))
        ..writeAsStringSync(
          '{"type":"FeatureCollection","features":[\n'
          '{"type":"Feature","properties":{"ucar":"MLA-04","comp1_porc":40},"geometry":{"type":"Point","coordinates":[-61.0,-31.50]}},\n'
          '{"type":"Feature","properties":null,"geometry":null}\n'
          ']}\n',
        );
      final features = await readGeoJsonLines(
        file,
        withGeometry: true,
      ).toList();
      expect(features, hasLength(2));
      expect(features[0].properties, {'ucar': 'MLA-04', 'comp1_porc': 40});
      expect(
        features[0].rawGeometry,
        '{"type":"Point","coordinates":[-61.0,-31.50]}',
      );
      expect(features[1].properties, isEmpty);
      expect(features[1].rawGeometry, isNull);
      final withoutGeometry = await readGeoJsonLines(file).toList();
      expect(withoutGeometry[0].rawGeometry, isNull);
    });

    test('readGeoJsonDocument decodes a regular collection', () async {
      final dir = tempDir('geojson_doc');
      final file = File(p.join(dir.path, 'a.geojson'))
        ..writeAsStringSync(
          jsonEncode({
            'type': 'FeatureCollection',
            'features': [
              {
                'type': 'Feature',
                'properties': {'x': 1},
                'geometry': {
                  'type': 'Point',
                  'coordinates': [1, 2],
                },
              },
            ],
          }),
        );
      final features = await readGeoJsonDocument(
        file,
        withGeometry: true,
      ).toList();
      expect(features.single.properties, {'x': 1});
      expect(jsonDecode(features.single.rawGeometry!), {
        'type': 'Point',
        'coordinates': [1, 2],
      });
    });
  });
}
