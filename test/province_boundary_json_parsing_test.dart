import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression test for the boundary-parsing bug fixed in
/// `_ProvinceBoundaryLoader.load()` (lib/gis/gis_map_screen.dart): some
/// coordinates in the real Santa Fe boundary JSON are whole numbers (e.g.
/// `-28`), which `jsonDecode` decodes as `int` rather than `double`. A
/// direct `as double` cast throws on those points; the fix casts through
/// `num` and calls `.toDouble()` instead. `_ProvinceBoundaryLoader` itself
/// is private to gis_map_screen.dart and can't be imported here, so this
/// exercises the exact same parsing expression against the real asset
/// file that triggered the bug.
void main() {
  test(
    'Santa Fe boundary JSON mixes int and double coordinates, and both '
    'parse correctly via (num).toDouble()',
    () {
      final file = File(
        'assets/maps/agronomic_reference_map_santa_fe.json',
      );
      final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final layers = decoded['layers'] as Map<String, Object?>;
      final rings = layers['provincialBoundaries']! as List<Object?>;

      // Confirms the regression scenario is actually present in the real
      // data — if this ever stops being true the bug this test guards
      // against can no longer reproduce from this asset.
      final hasIntegerCoordinate = rings.any(
        (ring) => (ring! as List<Object?>).any(
          (point) => (point! as List<Object?>).any((n) => n is int),
        ),
      );
      expect(hasIntegerCoordinate, isTrue);

      final points = <(double lat, double lon)>[];
      for (final ring in rings) {
        for (final point in ring! as List<Object?>) {
          final coordinates = point! as List<Object?>;
          points.add((
            (coordinates[1]! as num).toDouble(),
            (coordinates[0]! as num).toDouble(),
          ));
        }
      }

      expect(points, isNotEmpty);
      // [lon: -58.884, lat: -28] in the source file — lat is the integer
      // that used to throw; spot-checked against the raw JSON.
      final (lat, lon) = points[2];
      expect(lat, closeTo(-28.0, 1e-9));
      expect(lon, closeTo(-58.884, 1e-9));
    },
  );
}
