import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/cordoba_pmtiles_delivery.dart';
import 'package:suelosar/gis/map_coverage.dart';
import 'package:suelosar/gis/province_config.dart';
import 'package:suelosar/gis/series_resolver.dart';

void main() {
  test('Córdoba is registered in the shared multi-coverage map', () {
    final cordoba = MapCoverage.cordoba;

    expect(MapCoverage.all.map((coverage) => coverage.id), [
      'buenos_aires',
      'santa_fe',
      'cordoba',
    ]);
    expect(cordoba.config, same(ProvinceConfig.cordoba));
    expect(cordoba.onDemandDelivery, same(CordobaPmtilesDelivery.instance));
    expect(
      cordoba.config.pmtilesAsset,
      'assets/maps/cordoba_soil_polygons.pmtiles',
    );
    expect(
      cordoba.config.referenceMapAsset,
      'assets/maps/agronomic_reference_map_cordoba.json',
    );
    expect(cordoba.bounds.containsPoint(-32.4, -63.24), isTrue);
    expect(cordoba.config.seriesResolver, isA<CordobaSeriesResolver>());
    expect(cordoba.config.showPolygonUnitSymbols, isFalse);
  });
}
