import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/measurement_label_edge_fade.dart';

void main() {
  const viewport = Size(800, 600);

  test('labels comfortably inside the viewport remain fully opaque', () {
    expect(
      measurementLabelEdgeOpacity(
        const Rect.fromLTWH(250, 200, 220, 60),
        viewport,
      ),
      1,
    );
  });

  test('full label bounds fade continuously across each viewport edge', () {
    final nearLeft = measurementLabelEdgeOpacity(
      const Rect.fromLTWH(0, 200, 180, 50),
      viewport,
    );
    final beyondLeft = measurementLabelEdgeOpacity(
      const Rect.fromLTWH(-56, 200, 180, 50),
      viewport,
    );
    expect(nearLeft, 0.5);
    expect(beyondLeft, 0);

    expect(
      measurementLabelEdgeOpacity(
        const Rect.fromLTWH(620, 200, 180, 50),
        viewport,
      ),
      0.5,
    );
    expect(
      measurementLabelEdgeOpacity(
        const Rect.fromLTWH(200, 0, 180, 50),
        viewport,
      ),
      0.5,
    );
    expect(
      measurementLabelEdgeOpacity(
        const Rect.fromLTWH(200, 550, 180, 50),
        viewport,
      ),
      0.5,
    );
  });

  test('wide labels and corners use the nearest full-rect edge', () {
    final centeredWide = measurementLabelEdgeOpacity(
      const Rect.fromLTWH(56, 150, 688, 70),
      viewport,
    );
    final corner = measurementLabelEdgeOpacity(
      const Rect.fromLTWH(-20, -20, 180, 60),
      viewport,
    );
    expect(centeredWide, 1);
    expect(corner, lessThan(0.5));
  });

  test(
    'opacity changes monotonically and symmetrically as a label returns',
    () {
      final values = [
        for (final left in [-70.0, -56.0, -28.0, 0.0, 28.0, 56.0, 70.0])
          measurementLabelEdgeOpacity(
            Rect.fromLTWH(left, 200, 180, 50),
            viewport,
          ),
      ];
      expect(values, orderedEquals([...values]..sort()));
      expect(values.first, 0);
      expect(values.last, 1);
      expect(values[3], 0.5);
    },
  );

  test('invalid viewport and rectangles are hidden safely', () {
    expect(measurementLabelEdgeOpacity(Rect.zero, viewport), 0);
    expect(
      measurementLabelEdgeOpacity(
        const Rect.fromLTWH(10, 10, 20, 20),
        Size.zero,
      ),
      0,
    );
  });
}
