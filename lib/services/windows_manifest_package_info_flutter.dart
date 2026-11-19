import 'package:package_info_plus/package_info_plus.dart';

import 'windows_manifest_package_info_stub.dart';

Future<CurrentPackageInfo?> readCurrentPackageInfo() async {
  final info = await PackageInfo.fromPlatform();
  return CurrentPackageInfo(
    version: info.version,
    buildNumber: info.buildNumber,
  );
}
