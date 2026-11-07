import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/engine/maplibre_engine.dart';

void main() {
  test('Android uses thin soil outlines to avoid dense rendering', () {
    expect(
      MapLibreEngine.soilPolygonFillOpacityFor(TargetPlatform.android),
      0.10,
    );
    expect(
      MapLibreEngine.soilPolygonOutlineWidthFor(TargetPlatform.android),
      1,
    );
    expect(MapLibreEngine.soilPolygonFillOutlineColor(), Colors.transparent);
    expect(
      MapLibreEngine.selectedSoilPolygonOutlineWidthFor(TargetPlatform.android),
      2,
    );
  });

  test('Windows outlines stay thin to avoid dense polygon rendering', () {
    expect(
      MapLibreEngine.soilPolygonFillOpacityFor(TargetPlatform.windows),
      0.10,
    );
    expect(
      MapLibreEngine.soilPolygonOutlineWidthFor(TargetPlatform.windows),
      1,
    );
    expect(
      MapLibreEngine.selectedSoilPolygonOutlineWidthFor(TargetPlatform.windows),
      2,
    );
  });
}
