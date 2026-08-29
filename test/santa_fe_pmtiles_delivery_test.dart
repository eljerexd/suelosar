import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/santa_fe_pmtiles_delivery.dart';

/// Fase 11D: `uninstall()` is the new half of the existing Play Asset
/// Delivery wrapper (added for the Android-only cartography manager in
/// Configuración). These tests run on the host (never Android), so they
/// exercise exactly the same "always available, nothing to do" branch
/// `download()` already had — confirming the new method mirrors it rather
/// than accidentally flipping Santa Fe to "not installed" on a platform
/// where it's actually always bundled (Windows, and this test host).
void main() {
  test(
    'uninstall() is a no-op on a non-Android platform and status stays '
    'available',
    () async {
      final delivery = SantaFePmtilesDelivery.instance;
      expect(delivery.status, SantaFePmtilesStatus.available);

      await delivery.uninstall();

      expect(delivery.status, SantaFePmtilesStatus.available);
    },
  );
}
