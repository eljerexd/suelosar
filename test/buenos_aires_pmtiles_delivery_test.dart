import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/buenos_aires_pmtiles_delivery.dart';
import 'package:suelosar/gis/pmtiles_delivery.dart';

/// Fase 12A: Buenos Aires' on-demand delivery, mirroring exactly the
/// already-validated Santa Fe implementation (see
/// `santa_fe_pmtiles_delivery_test.dart`). These tests run on the host
/// (never Android), so they exercise exactly the "always available,
/// nothing to do" branch every method has for non-Android platforms —
/// confirming Buenos Aires never flips to "not installed" on a platform
/// where it's actually always bundled (Windows, and this test host).
void main() {
  test(
    'is available by default on a non-Android platform, and download()/'
    'uninstall() are no-ops that keep it that way',
    () async {
      final delivery = BuenosAiresPmtilesDelivery.instance;
      expect(delivery.status, PmtilesDeliveryStatus.available);

      await delivery.download();
      expect(delivery.status, PmtilesDeliveryStatus.available);

      await delivery.uninstall();
      expect(delivery.status, PmtilesDeliveryStatus.available);

      await delivery.checkStatus();
      expect(delivery.status, PmtilesDeliveryStatus.available);
    },
  );

  test('resolveWindowsArchiveFile() points at the real bundled path', () {
    final delivery = BuenosAiresPmtilesDelivery.instance;
    final file = delivery.resolveWindowsArchiveFile();
    expect(file.path, contains('buenos_aires_pmtiles'));
    expect(file.path, endsWith('soil_polygons.pmtiles'));
  });
}
