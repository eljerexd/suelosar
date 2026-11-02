import 'windows_update_models.dart';

class WindowsUpdateService {
  WindowsUpdateService({
    Object? client,
    InstalledVersionReader? installedVersionReader,
    InstallerStarter? installerStarter,
    Object? temporaryDirectory,
    bool? isWindows,
    this.requestTimeout = const Duration(seconds: 20),
  });

  static const latestReleaseUrl =
      'https://api.github.com/repos/eljerexd/suelosar/releases/latest';
  final Duration requestTimeout;

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

  Future<WindowsUpdateOperationResult> launchInstaller(String path) async =>
      const WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.unsupportedPlatform,
      );

  void close() {}
}
