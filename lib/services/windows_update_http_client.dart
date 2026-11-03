import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart';

const windowsUpdateClientSettings = ClientSettings(
  redirectSettings: RedirectSettings.none(),
  tlsSettings: TlsSettings(
    rootCertSource: RootCertSource.platform,
    verifyCertificates: true,
  ),
);

Future<http.Client> createWindowsUpdateHttpClient() async {
  await Rhttp.init();
  return RhttpCompatibleClient.create(settings: windowsUpdateClientSettings);
}
