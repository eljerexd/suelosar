import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/buenos_aires_feature_metadata_repository.dart';
import 'package:suelosar/gis/gis_feature.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AVi3 metadata joins by stable OBJECTID and SIMBC identity', () async {
    final original = _feature({'OBJECTID': 175, 'SIMBC': 'AVi3'});
    final enriched = await BuenosAiresFeatureMetadataRepository()
        .enrichCardFeature(original);

    expect(enriched.properties['taxo_ppal'], 'Haplustol litico');
    expect(enriched.properties['taxo_2rio'], 'Haplustol tipico');
    expect(enriched.properties['POSIC1'], 'Loma y pendiente');
    expect(enriched.properties['POSIC2'], 'Loma');
    expect(original.properties.keys, {'OBJECTID', 'SIMBC'});
  });

  test('repeated OBJECTIDs resolve independently by SIMBC', () async {
    final first = await BuenosAiresFeatureMetadataRepository()
        .enrichCardFeature(_feature({'OBJECTID': 1825, 'SIMBC': 'PM1'}));
    final second = await BuenosAiresFeatureMetadataRepository()
        .enrichCardFeature(_feature({'OBJECTID': 1825, 'SIMBC': 'PM'}));

    expect(first.properties['taxo_ppal'], 'Udipsament tipico');
    expect(first.properties['taxo_2rio'], 'Haplacuol tipico');
    expect(second.properties['taxo_2rio'], 'Uidipsament acuico');
    expect(second.properties['FASE4'], 'algo pobremente drenada');
    expect(second.properties.containsKey('POSIC6'), isFalse);
  });

  test('a symbol mismatch cannot receive another unit metadata', () async {
    final original = _feature({'OBJECTID': 175, 'SIMBC': 'other'});
    final enriched = await BuenosAiresFeatureMetadataRepository()
        .enrichCardFeature(original);

    expect(identical(enriched, original), isTrue);
    expect(enriched.properties.containsKey('taxo_ppal'), isFalse);
  });

  test('missing stable identity leaves the feature untouched', () async {
    final original = _feature({'SIMBC': 'AVi3'});
    final enriched = await BuenosAiresFeatureMetadataRepository()
        .enrichCardFeature(original);

    expect(identical(enriched, original), isTrue);
  });
}

GisFeature _feature(Map<String, Object?> properties) => GisFeature(
  id: '175',
  geometry: const GisGeometry(type: 'Polygon', coordinates: null),
  properties: Map<String, Object?>.unmodifiable(properties),
  locality: '',
  soilMapId: 0,
);
