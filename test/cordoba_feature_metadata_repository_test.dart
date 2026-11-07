import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/cordoba_feature_metadata_repository.dart';
import 'package:suelosar/gis/gis_feature.dart';
import 'package:suelosar/gis/gis_soil_series.dart';
import 'package:suelosar/gis/gis_soil_taxonomy.dart';

void main() {
  test(
    'joins AEtc-2 by offset OBJECTID and preserves existing PMTiles values',
    () async {
      final repository = CordobaFeatureMetadataRepository(
        assetBundle: _JsonAssetBundle(_index),
      );
      final original = _feature({
        'OBJECTID': 100271,
        'SIMBC': 'AEtc-2',
        'IP': 10,
        'SERIE1': 'ARROYITO',
        'PORC1': 30,
        'SERIE2': 'ALTOS DE CHIPIÓN',
        'PORC2': 30,
        'SERIE3': 'LA ARGENTINA',
        'PORC3': 20,
        'SERIE4': 'suelos hidro-halomórficos',
        'PORC4': 20,
      });

      final enriched = await repository.enrichCardFeature(original);
      final taxonomy = GisSoilTaxonomy.fromProperties(enriched.properties);
      final series = GisSoilSeries.fromProperties(enriched.properties);

      expect(taxonomy.soilClass, 'VII');
      expect(taxonomy.subclass, 'ws');
      expect(taxonomy.productivityIndex, '10');
      expect(enriched.properties['FASE1'], 'en fase moderadamente salina');
      expect(enriched.properties['FASE2'], 'en fase moderadamente salina');
      expect(enriched.properties['FASE3'], 'en fase moderadamente salina');
      expect(enriched.properties.containsKey('FASE4'), isFalse);
      expect(series.map((item) => item.percentage), ['30', '30', '20', '20']);
      expect(original.properties.containsKey('CLASE'), isFalse);
    },
  );

  test(
    'fills only missing optional metadata and refuses symbol mismatches',
    () async {
      final repository = CordobaFeatureMetadataRepository(
        assetBundle: _JsonAssetBundle(_index),
      );
      final partial = _feature({
        'OBJECTID': '100271',
        'SIMBC': 'AEtc-2',
        'CLASE': 'VI',
        'FASE1': 'fase local',
      });
      final enriched = await repository.enrichCardFeature(partial);
      expect(enriched.properties['CLASE'], 'VI');
      expect(enriched.properties['FASE1'], 'fase local');
      expect(enriched.properties['FASE2'], 'en fase moderadamente salina');

      final mismatched = _feature({'OBJECTID': 100271, 'SIMBC': 'otra unidad'});
      expect(await repository.enrichCardFeature(mismatched), same(mismatched));
    },
  );

  test(
    'does not invent metadata for unknown IDs or missing source values',
    () async {
      final repository = CordobaFeatureMetadataRepository(
        assetBundle: _JsonAssetBundle(_index),
      );
      final unknown = _feature({'OBJECTID': 9, 'SIMBC': 'sin registro'});
      expect(await repository.enrichCardFeature(unknown), same(unknown));

      final missingOptional = _feature({'OBJECTID': 500017, 'SIMBC': 'MNtc-2'});
      final enriched = await repository.enrichCardFeature(missingOptional);
      expect(enriched.properties['CLASE'], 'IV');
      expect(enriched.properties['SUBCLASE'], 'e');
      expect(enriched.properties['IP'], '24');
      expect(enriched.properties.containsKey('FASE1'), isFalse);
    },
  );
}

GisFeature _feature(Map<String, Object?> properties) => GisFeature(
  id: 'cordoba:test',
  geometry: const GisGeometry(type: 'Polygon', coordinates: <Object>[]),
  properties: properties,
  locality: '',
  soilMapId: 0,
);

const _index = <String, Object?>{
  'version': 1,
  'province': 'cordoba',
  'identityField': 'OBJECTID',
  'features': <String, Object?>{
    '100271': <String, Object?>{
      'SIMBC': 'AEtc-2',
      'CLASE': 'VII',
      'SUBCLASE': 'ws',
      'IP': 10,
      'FASE1': 'en fase moderadamente salina',
      'FASE2': 'en fase moderadamente salina',
      'FASE3': 'en fase moderadamente salina',
    },
    '500017': <String, Object?>{
      'SIMBC': 'MNtc-2',
      'CLASE': 'IV',
      'SUBCLASE': 'e',
      'IP': '24',
    },
  },
};

class _JsonAssetBundle extends CachingAssetBundle {
  _JsonAssetBundle(this.value);

  final Map<String, Object?> value;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(jsonEncode(value))));
}
