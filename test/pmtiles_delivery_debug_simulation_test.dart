import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/pmtiles_delivery.dart';

void main() {
  for (final entry in {
    'Buenos Aires': 158646380,
    'Santa Fe': 65985455,
    'Córdoba': 77400595,
  }.entries) {
    test('${entry.key} debug simulation reports progressive bytes', () async {
      final statuses = <PmtilesDeliveryStatus>[];
      final updates = <PmtilesDownloadBytes>[];

      await simulateDevelopmentPmtilesDownload(
        totalBytes: entry.value,
        stepDelay: Duration.zero,
        setStatus: statuses.add,
        setDownloadBytes: (bytes) {
          if (bytes != null) updates.add(bytes);
        },
      );

      expect(statuses, [
        PmtilesDeliveryStatus.downloading,
        PmtilesDeliveryStatus.available,
      ]);
      expect(updates.map((bytes) => bytes.percent), [20, 40, 60, 80, 100]);
      expect(updates.every((bytes) => bytes.total == entry.value), isTrue);
      expect(updates.last.downloaded, entry.value);
    });
  }

  test('rejects an unknown or empty archive size', () {
    expect(
      () => simulateDevelopmentPmtilesDownload(
        totalBytes: 0,
        setStatus: (_) {},
        setDownloadBytes: (_) {},
      ),
      throwsArgumentError,
    );
  });
}
