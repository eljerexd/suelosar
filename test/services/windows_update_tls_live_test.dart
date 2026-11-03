import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/services/windows_update_http_client.dart';
import 'package:suelosar/services/windows_update_service.dart';

const _runLiveTlsTest = bool.fromEnvironment(
  'SUELOSAR_RUN_LIVE_TLS_TEST',
  defaultValue: false,
);

void main() {
  test(
    'installed 1.7.0+20 recognizes public v1.7.0 as up to date over TLS',
    () async {
      final client = await createWindowsUpdateHttpClient();
      final service = WindowsUpdateService(
        client: client,
        isWindows: true,
        installedVersionReader: () async => '1.7.0+20',
      );
      addTearDown(service.close);

      final result = await service.checkForUpdates().timeout(
        const Duration(seconds: 30),
      );

      expect(result.status, WindowsUpdateStatus.upToDate);
      expect(result.updateAvailable, isFalse);
      expect(result.installedVersion.toString(), '1.7.0+20');
      expect(result.release!.tag, 'v1.7.0');
      expect(result.release!.version.isStable, isTrue);
    },
    skip: !_runLiveTlsTest,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
