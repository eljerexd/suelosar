class CurrentPackageInfo {
  const CurrentPackageInfo({required this.version, required this.buildNumber});

  final String version;
  final String buildNumber;
}

Future<CurrentPackageInfo?> readCurrentPackageInfo() async => null;
