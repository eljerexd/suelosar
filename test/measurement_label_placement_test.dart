import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:suelosar/gis/measurement_label_placement.dart';

void main() {
  test('camera revisions translate the label without changing its side', () {
    final cache = MeasurementLabelPlacementCache();
    final first = cache.resolve(
      id: 'area-1',
      geometryKey: 1,
      anchor: const Offset(280, 260),
      size: const Size(220, 68),
      viewport: const Size(600, 800),
      occupied: const [],
      safeInsets: const EdgeInsets.fromLTRB(8, 80, 8, 80),
    );
    final moved = cache.resolve(
      id: 'area-1',
      geometryKey: 1,
      anchor: const Offset(180, 360),
      size: const Size(220, 68),
      viewport: const Size(600, 800),
      occupied: const [],
      safeInsets: const EdgeInsets.fromLTRB(8, 80, 8, 80),
    );

    expect(
      moved.topLeft - const Offset(180, 360),
      first.topLeft - const Offset(280, 260),
    );
  });

  test('geometry and viewport changes select a fresh safe placement', () {
    final cache = MeasurementLabelPlacementCache();
    final first = cache.resolve(
      id: 'area-1',
      geometryKey: 1,
      anchor: const Offset(30, 110),
      size: const Size(220, 68),
      viewport: const Size(600, 800),
      occupied: const [],
      safeInsets: const EdgeInsets.fromLTRB(8, 80, 8, 80),
    );
    final resized = cache.resolve(
      id: 'area-1',
      geometryKey: 2,
      anchor: const Offset(30, 110),
      size: const Size(220, 68),
      viewport: const Size(600, 900),
      occupied: [first.inflate(4)],
      safeInsets: const EdgeInsets.fromLTRB(8, 80, 8, 80),
    );

    expect(resized.overlaps(first.inflate(4)), isFalse);
  });
}
