import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:suelosar/gis/buenos_aires_pmtiles_delivery.dart';
import 'package:suelosar/gis/cordoba_pmtiles_delivery.dart';
import 'package:suelosar/gis/pmtiles_delivery.dart';
import 'package:suelosar/gis/santa_fe_pmtiles_delivery.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('all province PMTiles use the same on-demand debug flow', (
    tester,
  ) async {
    final deliveries = <PmtilesDelivery>[
      BuenosAiresPmtilesDelivery.instance,
      SantaFePmtilesDelivery.instance,
      CordobaPmtilesDelivery.instance,
    ];

    expect(
      deliveries.map((delivery) => delivery.status),
      everyElement(PmtilesDeliveryStatus.notInstalled),
    );

    await Future.wait(deliveries.map((delivery) => delivery.checkStatus()));
    final statusBeforeDownload = useLocalPmtilesAssetsInDebug
        ? PmtilesDeliveryStatus.available
        : PmtilesDeliveryStatus.notInstalled;
    expect(
      deliveries.map((delivery) => delivery.status),
      everyElement(statusBeforeDownload),
    );

    final downloads = deliveries
        .map((delivery) => delivery.download())
        .toList();
    expect(
      deliveries.map((delivery) => delivery.status),
      everyElement(PmtilesDeliveryStatus.downloading),
    );

    await Future.wait(downloads);
    expect(
      deliveries.map((delivery) => delivery.status),
      everyElement(PmtilesDeliveryStatus.available),
    );
  });
}
