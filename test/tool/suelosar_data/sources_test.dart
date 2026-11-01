import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/suelosar_data/config/province_definition.dart';
import '../../../tool/suelosar_data/sources/dbf_reader.dart';
import '../../../tool/suelosar_data/sources/geojson_reader.dart';
import '../../../tool/suelosar_data/sources/gis_source.dart';
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

    // A one-line FeatureCollection shaped like the Córdoba WFS export:
    // root members before and after `features`, per-feature `id`, `bbox`
    // and `geometry_name`, accents, escapes and braces inside strings.
    const wfsGeometry1 =
        '{"type":"MultiPolygon","coordinates":[[[[-62.49999992,-30.90651996],'
        '[-62.49999992,-30.90523065],[-62.4998845,-30.90528742],'
        '[-62.49999992,-30.90651996]]]]}';
    const wfsGeometry2 =
        '{"type":"MultiPolygon","coordinates":[[[[-64.1,-33.2],[-64.0,-33.2],'
        '[-64.0,-33.1],[-64.1,-33.2]]],[[[-63.9,-33.0],[-63.8,-33.0],'
        '[-63.8,-32.9],[-63.9,-33.0]]]]}';
    const wfsDocument =
        '{"type":"FeatureCollection","features":['
        '{"type":"Feature","id":"carta.17","geometry":$wfsGeometry1,'
        '"geometry_name":"geom","properties":{"id":17,"simbolo":"Lsp",'
        '"cu":"VIII","nombre":"Lagunas semipermanentes","serie_1":null,'
        '"porc_1":null},"bbox":[-62.5,-30.9,-62.49,-30.9]},'
        '{"type":"Feature","id":"carta.427","geometry":$wfsGeometry2,'
        '"geometry_name":"geom","properties":{"id":427,"simbolo":"E23/17",'
        '"nombre":"Complejo de Series EL VEINTITRÉS 40%; \\"HUINCA\\" {x} [y]",'
        '"serie_1":"EL VEINTITRÉS","pdf_serie1":"EL_VEINTITRÉS","porc_1":40,'
        '"ip":2.5,"activo":true},"bbox":[-64.1,-33.2,-63.8,-32.9]},'
        '{"type":"Feature","id":"carta.9","geometry":null,'
        '"properties":{"id":9,"simbolo":"Río Primero"}}'
        '],"totalFeatures":3,"numberMatched":3,"timeStamp":"2026-09-17T11:07:23Z",'
        '"crs":{"type":"name","properties":{"name":"urn:ogc:def:crs:EPSG::4326"}},'
        '"bbox":[-65.1,-35.0,-61.8,-30.3]}';

    void expectWfsFeatures(List<GeoJsonFeature> features) {
      expect(features.map((f) => f.index), [0, 1, 2]);
      expect(features[0].properties, {
        'id': 17,
        'simbolo': 'Lsp',
        'cu': 'VIII',
        'nombre': 'Lagunas semipermanentes',
        'serie_1': null,
        'porc_1': null,
      });
      expect(features[0].rawGeometry, wfsGeometry1);
      expect(features[1].properties, {
        'id': 427,
        'simbolo': 'E23/17',
        'nombre': 'Complejo de Series EL VEINTITRÉS 40%; "HUINCA" {x} [y]',
        'serie_1': 'EL VEINTITRÉS',
        'pdf_serie1': 'EL_VEINTITRÉS',
        'porc_1': 40,
        'ip': 2.5,
        'activo': true,
      });
      expect(features[1].rawGeometry, wfsGeometry2);
      expect(features[2].properties, {'id': 9, 'simbolo': 'Río Primero'});
      expect(features[2].rawGeometry, isNull);
    }

    test('readGeoJsonDocument streams a one-line FeatureCollection, keeping '
        'properties and geometry text', () async {
      final file = File(p.join(tempDir('geojson_wfs').path, 'wfs.json'))
        ..writeAsStringSync(wfsDocument);
      expectWfsFeatures(
        await readGeoJsonDocument(file, withGeometry: true).toList(),
      );
      final withoutGeometry = await readGeoJsonDocument(file).toList();
      expect(withoutGeometry, hasLength(3));
      expect(withoutGeometry.every((f) => f.rawGeometry == null), isTrue);
    });

    test('readGeoJsonDocument reads pretty-printed collections', () async {
      final pretty = const JsonEncoder.withIndent(
        '  ',
      ).convert(jsonDecode(wfsDocument));
      final file = File(p.join(tempDir('geojson_pretty').path, 'p.geojson'))
        ..writeAsStringSync(pretty);
      final features = await readGeoJsonDocument(
        file,
        withGeometry: true,
      ).toList();
      expect(features, hasLength(3));
      expect(features[1].properties['nombre'], contains('"HUINCA" {x} [y]'));
      final withBom = File(p.join(tempDir('geojson_bom').path, 'bom.json'))
        ..writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(wfsDocument)]);
      expect(await readGeoJsonDocument(withBom).toList(), hasLength(3));
      // Indented geometry is kept as written; it still decodes the same.
      expect(jsonDecode(features[1].rawGeometry!), jsonDecode(wfsGeometry2));
    });

    test('the scanner handles features split across any chunk boundary', () {
      for (final size in [1, 2, 3, 7, 64, 1000]) {
        final scanner = FeatureCollectionScanner();
        final texts = <String>[
          for (var i = 0; i < wfsDocument.length; i += size)
            ...scanner.add(
              wfsDocument.substring(
                i,
                i + size > wfsDocument.length ? wfsDocument.length : i + size,
              ),
            ),
        ];
        scanner.close('mem');
        expect(texts, hasLength(3), reason: 'chunk $size');
        expect(
          [for (final t in texts) jsonDecode(t)],
          (jsonDecode(wfsDocument) as Map)['features'],
          reason: 'chunk $size',
        );
      }
    });

    test('readGeoJsonDocument streams many features', () async {
      const count = 2500;
      final file = File(p.join(tempDir('geojson_many').path, 'many.json'));
      final sink = file.openWrite()
        ..write('{"type":"FeatureCollection","features":[');
      for (var i = 0; i < count; i++) {
        if (i > 0) sink.write(',');
        sink.write(
          '{"type":"Feature","properties":{"n":$i,"s":"v$i"},'
          '"geometry":{"type":"Point","coordinates":[$i,-$i]}}',
        );
      }
      sink.write(']}');
      await sink.close();
      var n = 0;
      await for (final f in readGeoJsonDocument(file, withGeometry: true)) {
        expect(f.index, n);
        expect(f.properties, {'n': n, 's': 'v$n'});
        expect(f.rawGeometry, '{"type":"Point","coordinates":[$n,-$n]}');
        n++;
      }
      expect(n, count);
    });

    test('readGeoJsonDocument handles empty and invalid documents', () async {
      final dir = tempDir('geojson_bad');
      Future<List<GeoJsonFeature>> read(String name, String text) =>
          readGeoJsonDocument(
            File(p.join(dir.path, name))..writeAsStringSync(text),
          ).toList();

      expect(
        await read('empty.json', '{"type":"FeatureCollection","features":[]}'),
        isEmpty,
      );
      for (final (name, text, fragment) in [
        ('array.json', '[1]', 'no es un objeto'),
        ('feature.json', '{"type":"Feature","properties":{}}', 'type: Feature'),
        ('nofeatures.json', '{"type":"FeatureCollection"}', '"features"'),
        (
          'cut.json',
          '{"type":"FeatureCollection","features":[{"type":',
          'incompleto',
        ),
        (
          'element.json',
          '{"type":"FeatureCollection","features":[1]}',
          'no es un objeto',
        ),
        (
          'notfeature.json',
          '{"type":"FeatureCollection","features":[{"type":"Point"}]}',
          'no es un Feature',
        ),
        (
          'trailing.json',
          '{"type":"FeatureCollection","features":[]} {}',
          'después',
        ),
      ]) {
        await expectLater(
          read(name, text),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains(fragment), contains(name)),
            ),
          ),
          reason: name,
        );
      }
    });

    test('readGeoJsonLines rejects a one-line FeatureCollection', () async {
      final file = File(p.join(tempDir('geojson_oneline').path, 'wfs.json'))
        ..writeAsStringSync(wfsDocument);
      await expectLater(
        readGeoJsonLines(file).toList(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('gis.format: geojson'),
          ),
        ),
      );
    });

    test(
      'GisSource reads format geojson through the streaming reader',
      () async {
        final root = tempDir('geojson_source');
        writeProvince(root, 'wfs', '''
id: wfs
name: WFS
gis:
  source: wfs.json
  format: geojson
  mapping:
${identityMapping()}
''');
        File(
          p.join(root.path, 'wfs', 'wfs.json'),
        ).writeAsStringSync(wfsDocument);
        final definition = ProvinceDefinition.load(
          id: 'wfs',
          provincesDir: root.path,
          repoRoot: repoRoot,
        );
        final source = GisSource.open(definition.gis);
        final records = await source.records(withGeometry: true).toList();
        expect(records.map((r) => r.index), [0, 1, 2]);
        expect(records[1].properties['simbolo'], 'E23/17');
        expect(records[1].geometryJson, wfsGeometry2);
        expect(records[2].geometryJson, isNull);
        expect(source.encodingName, 'UTF-8');
      },
    );
  });
}
