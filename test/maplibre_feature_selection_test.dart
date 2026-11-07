import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/engine/maplibre_feature_selection.dart';

void main() {
  group('MapLibreFeatureSelector', () {
    test('prefers the source object id over a tile-scoped MVT id', () {
      final selector = MapLibreFeatureSelector.forFeature(
        featureId: '406',
        properties: const {'SIMBC': 'GG12', 'OBJECTID': 939},
      );

      expect(selector.isUsable, isTrue);
      expect(selector.featureId, isNull);
      expect(selector.propertyName, 'OBJECTID');
      expect(selector.filter.toJson(), ['==', 'OBJECTID', 939]);
    });

    test(
      'strips the coverage prefix without changing the source feature id',
      () {
        final selector = MapLibreFeatureSelector.forFeature(
          featureId: 'cordoba:406',
          properties: const {'SIMBC': 'GG12', 'OBJECTID': 939},
        );

        expect(selector.featureId, isNull);
        expect(selector.propertyName, 'OBJECTID');
        expect(selector.filter.toJson(), ['==', 'OBJECTID', 939]);
      },
    );

    test('uses a source object id when the vector query omits its tile id', () {
      final selector = MapLibreFeatureSelector.forFeature(
        featureId: 'native-fragment-hash',
        properties: const {'SIMBC': 'GG12', 'OBJECTID': 939},
      );

      expect(selector.featureId, isNull);
      expect(selector.propertyName, 'OBJECTID');
      expect(selector.filter.toJson(), ['==', 'OBJECTID', 939]);
    });

    test(
      'falls back to the numeric MVT id if no source identity is present',
      () {
        final selector = MapLibreFeatureSelector.forFeature(
          featureId: '406',
          properties: const {'SIMBC': 'GG12'},
        );

        expect(selector.featureId, 406);
        expect(selector.propertyName, isNull);
        expect(selector.filter.toJson(), ['==', r'$id', 406]);
      },
    );

    test('does not fall back to a non-unique map-unit symbol', () {
      final selector = MapLibreFeatureSelector.forFeature(
        featureId: 'native-fragment-hash',
        properties: const {'SIMBC': 'GG12'},
      );

      expect(selector.isUsable, isFalse);
      expect(selector.filter.toJson(), ['==', r'$id', -1]);
    });
  });
}
