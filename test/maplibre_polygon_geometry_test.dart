import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/engine/maplibre_polygon_geometry.dart';

void main() {
  group('normalizeMapLibrePolygonGeometry', () {
    test('closes a valid three-vertex tile ring', () {
      final geometry = normalizeMapLibrePolygonGeometry('Polygon', [
        [
          [-64.0, -35.0],
          [-63.0, -35.0],
          [-63.0, -34.0],
        ],
      ]);

      expect(geometry, isNotNull);
      final rings = geometry!['coordinates']! as List;
      final ring = rings.single as List;
      expect(ring, hasLength(4));
      expect(ring.first, ring.last);
    });

    test('rejects degenerate and malformed polygon rings', () {
      expect(
        normalizeMapLibrePolygonGeometry('Polygon', [
          [
            [-64.0, -35.0],
            [-64.0, -35.0],
            [-63.0, -35.0],
          ],
        ]),
        isNull,
      );
      expect(
        normalizeMapLibrePolygonGeometry('Polygon', [
          [
            [-64.0, -35.0],
            [-63.0, -35.0],
            ['bad', -34.0],
          ],
        ]),
        isNull,
      );
    });

    test('preserves valid MultiPolygon structure', () {
      final geometry = normalizeMapLibrePolygonGeometry('MultiPolygon', [
        [
          [
            [0, 0],
            [1, 0],
            [1, 1],
            [0, 0],
          ],
        ],
      ]);

      expect(geometry, isNotNull);
      expect(geometry!['type'], 'MultiPolygon');
      expect(geometry['coordinates'], hasLength(1));
    });
  });
}
