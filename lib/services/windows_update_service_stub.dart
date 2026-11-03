import 'windows_update_models.dart';

class WindowsUpdateService {
  WindowsUpdateService({
    Object? client,
    InstalledVersionReader? installedVersionReader,
    InstallerStarter? installerStarter,
    InstallerLifecycleStarter? installerLifecycleStarter,
    Object? installerHelperResolver,
    Object? applicationExecutableResolver,
    Object? temporaryDirectory,
    bool? isWindows,
    this.requestTimeout = const Duration(seconds: 20),
  });

  static const latestReleaseUrl =
      'https://api.github.com/repos/eljerexd/Web-SuelosAR/releases/latest';
  final Duration requestTimeout;
  bool get canLaunchInstaller => false;

  Future<WindowsUpdateCheckResult> checkForUpdates() async =>
      const WindowsUpdateCheckResult(
        status: WindowsUpdateStatus.unsupportedPlatform,
      );

  Future<WindowsUpdateOperationResult> downloadUpdate(
    WindowsUpdateCheckResult check, {
    void Function(WindowsUpdateProgress progress)? onProgress,
  }) async => const WindowsUpdateOperationResult(
    status: WindowsUpdateOperationStatus.unsupportedPlatform,
  );

  void cancelDownload() {}

  Future<WindowsUpdateOperationResult> verifyDownloadedInstaller(
    String path,
    String expectedSha256,
  ) async => const WindowsUpdateOperationResult(
    status: WindowsUpdateOperationStatus.unsupportedPlatform,
  );

  Future<bool> restoreDownloadedInstaller({
    required String path,
    required String expectedSha256,
    required String version,
  }) async => false;

  Future<WindowsUpdateOperationResult> launchInstaller(String path) async =>
      const WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.unsupportedPlatform,
      );

  void close() {}
}
