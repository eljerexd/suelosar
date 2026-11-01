import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:suelosar/gis/gis_soil_taxonomy.dart';

import '../../../tool/suelosar_data/config/province_definition.dart';
import '../../../tool/suelosar_data/cordoba_feature_metadata_builder.dart';

void main() {
  test(
    'builds collision-free metadata keys from configured source offsets',
    () async {
      final root = Directory.current.path;
      final province = ProvinceDefinition.load(
        id: 'cordoba',
        provincesDir: p.join(root, 'data', 'provinces'),
        repoRoot: root,
      );
      final index = await buildCordobaFeatureMetadataIndex(province);
      final features = (index['features']! as Map).cast<String, Object?>();
      final aetc = (features['100271']! as Map).cast<String, Object?>();
      final cod1 = (features['100086']! as Map).cast<String, Object?>();
      final mntc = (features['500017']! as Map).cast<String, Object?>();

      expect(index['identityField'], 'OBJECTID');
      expect(aetc['SIMBC'], 'AEtc-2');
      expect(aetc['CLASE'], 'VII');
      expect(aetc['SUBCLASE'], 'ws');
      expect(aetc['IP'], 10);
      expect(aetc['FASE1'], 'en fase moderadamente salina');
      expect(aetc['FASE4'], isNull);
      expect(cod1['SIMBC'], 'CoD1');
      expect(cod1['FASE1'], isNull);
      expect(mntc['SIMBC'], 'MNtc-2');
      expect(mntc['CLASE'], 'IV');
      expect(mntc['SUBCLASE'], 'e');
      expect(mntc['IP'], '24');
      expect(features.length, greaterThan(100));
      expect(GisSoilTaxonomy.fromProperties(mntc).soilClass, 'IV');
    },
  );
}
