import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/pmtiles_delivery.dart';

void main() {
  test('web standalone flavor is declared in Android Gradle configuration', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('create("web")'));
    expect(gradle, contains('create("prod")'));
    expect(gradle, contains('create("beta")'));
  });

  test('only Android non-web flavors use Play Feature Delivery', () {
    expect(
      usesOnDemandPmtilesDeliveryFor(isAndroid: true, flavor: 'prod'),
      isTrue,
    );
    expect(
      usesOnDemandPmtilesDeliveryFor(isAndroid: true, flavor: 'beta'),
      isTrue,
    );
    expect(
      usesOnDemandPmtilesDeliveryFor(isAndroid: true, flavor: 'web'),
      isFalse,
    );
    expect(
      usesOnDemandPmtilesDeliveryFor(isAndroid: false, flavor: 'prod'),
      isFalse,
    );
  });
}
