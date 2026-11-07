import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/measurement_render_style.dart';

void main() {
  test('active foreground widths are explicit and reusable', () {
    expect(MeasurementRenderStyles.activeDistance.width, 4);
    expect(MeasurementRenderStyles.activeDistance.width, 4);
    expect(MeasurementRenderStyles.activeAreaOutline.width, 3);
    expect(MeasurementRenderStyles.activeAreaFillOpacity, 0.25);
  });

  test('saved measurement styles preserve their state-specific widths', () {
    final normal = MeasurementRenderStyles.saved(
      SavedMeasurementVisualState.normal,
    );
    final hovered = MeasurementRenderStyles.saved(
      SavedMeasurementVisualState.hovered,
    );
    final selected = MeasurementRenderStyles.saved(
      SavedMeasurementVisualState.selected,
    );

    expect(normal.distance.width, 4);
    expect(hovered.distance.width, 5.5);
    expect(selected.distance.width, 8);
    expect(normal.areaOutline.width, 3);
    expect(hovered.areaOutline.width, 4.5);
    expect(selected.areaOutline.width, 6);
    expect(
      [
        normal.areaFillOpacity,
        hovered.areaFillOpacity,
        selected.areaFillOpacity,
      ],
      [0.25, 0.34, 0.42],
    );
  });

  test('both engines use rounded measurement line ends and joins', () {
    expect(MeasurementRenderStyles.activeDistance.cap.name, 'round');
    expect(MeasurementRenderStyles.activeDistance.join.name, 'round');
  });
}
