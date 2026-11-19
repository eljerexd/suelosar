import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'windows_differential_update.dart';
import 'windows_installation_manifest.dart';
import 'windows_update_models.dart';

typedef DifferentialLifecycleStarter = Future<void> Function(
  PreparedWindowsDifferentialUpdate prepared,
  String version,
  String installationId,
);

class WindowsUpdateService {
  WindowsUpdateService({
    http.Client? client,
    InstalledVersionReader? installedVersionReader,
    InstallerStarter? installerStarter,
    InstallerLifecycleStarter? installerLifecycleStarter,
    DifferentialLifecycleStarter? differentialLifecycleStarter,
    File Function()? installerHelperResolver,
    File Function()? applicationExecutableResolver,
    File Function()? installationManifestResolver,
    String? latestReleaseEndpoint,
    this.temporaryDirectory,
    bool? isWindows,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client(),
       _installedVersionReader =
           installedVersionReader ?? _readInstalledVersion,
       _installerHelperResolver =
           installerHelperResolver ?? _resolveBundledInstallerHelper,
       _applicationExecutableResolver =
           applicationExecutableResolver ??
           (() => File(Platform.resolvedExecutable)),
       _installationManifestResolver =
           installationManifestResolver ?? _resolveInstallationManifest,
       _latestReleaseEndpoint =
           latestReleaseEndpoint ?? _defaultLatestReleaseEndpoint,
       _isWindows = isWindows ?? Platform.isWindows {
    _installerLifecycleStarter =
        installerLifecycleStarter ??
        (installerStarter == null
            ? _startInstallerLifecycle
            : (path, _, _, _) => installerStarter(path));
    _differentialLifecycleStarter =
        differentialLifecycleStarter ?? _startDifferentialLifecycle;
  }

  static const repositoryOwner = 'eljerexd';
  static const repositoryName = 'Web-SuelosAR';
  static const latestReleaseUrl =
      'https://api.github.com/repos/$repositoryOwner/$repositoryName/releases/latest';
  static const _stagingBaseUrl = String.fromEnvironment(
    'SUelosAR_UPDATE_STAGING_BASE',
    defaultValue: '',
  );
  static const _requireDifferentialStaging = bool.fromEnvironment(
    'SUelosAR_UPDATE_REQUIRE_DIFFERENTIAL',
    defaultValue: false,
  );
  static const _userAgent = 'SuelosAR-Windows-Updater';

  static String get _defaultLatestReleaseEndpoint {
    if (_stagingBaseUrl.isEmpty) return latestReleaseUrl;
    final base = Uri.tryParse(_stagingBaseUrl);
    if (base == null ||
        base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.path.isNotEmpty && base.path != '/')) {
      throw StateError(
        'El endpoint diferencial QA no es una URL HTTPS válida.',
      );
    }
    return base
        .replace(
          path: '/repos/$repositoryOwner/$repositoryName/releases/latest',
        )
        .toString();
  }

  bool get canLaunchInstaller {
    if (!_isWindows) {
      return false;
    }
    try {
      if (_applicationExecutableResolver().uri.pathSegments.last
              .toLowerCase() !=
          'suelosar.exe') {
        return false;
      }
      final helper = _installerHelperResolver();
      if (!helper.existsSync() || helper.lengthSync() < 2) return false;
      final header = helper.openSync();
      try {
        final bytes = header.readSync(2);
        return bytes.length == 2 && bytes[0] == 0x4d && bytes[1] == 0x5a;
      } finally {
        header.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  final http.Client _client;
  final InstalledVersionReader _installedVersionReader;
  late final InstallerLifecycleStarter _installerLifecycleStarter;
  late final DifferentialLifecycleStarter _differentialLifecycleStarter;
  final File Function() _installerHelperResolver;
  final File Function() _applicationExecutableResolver;
  final File Function() _installationManifestResolver;
  final String _latestReleaseEndpoint;
  final Directory? temporaryDirectory;
  final bool _isWindows;
  final Duration requestTimeout;
  Completer<void>? _abortDownload;
  bool _downloading = false;
  final Map<String, _VerifiedInstaller> _verifiedInstallers = {};
  final Set<WindowsUpdateCheckResult> _issuedDownloadChecks =
      HashSet.identity();

  Future<WindowsUpdateCheckResult> checkForUpdates() async {
    if (!_isWindows) {
      return const WindowsUpdateCheckResult(
        status: WindowsUpdateStatus.unsupportedPlatform,
      );
    }

    try {
      final installedUpdate = UpdateVersion.tryParse(
        await _installedVersionReader(),
      );
      if (installedUpdate == null) {
        return _checkFailure(
          WindowsUpdateStatus.failed,
          WindowsUpdateErrorCode.invalidRelease,
          'No se pudo interpretar la versión instalada.',
        );
      }
      final installed = installedUpdate.semanticVersion;
      final response = await _get(
        Uri.parse(_latestReleaseEndpoint),
        headers: const {'Cache-Control': 'no-cache'},
      );
      if (response.statusCode == 404) {
        return const WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.noStableRelease,
        );
      }
      if (response.statusCode == 403 &&
          response.headers['x-ratelimit-remaining'] == '0') {
        return _checkFailure(
          WindowsUpdateStatus.releaseUnavailable,
          WindowsUpdateErrorCode.rateLimited,
          'GitHub limitó temporalmente las consultas de releases.',
        );
      }
      if (response.statusCode != 200) {
        return _checkFailure(
          WindowsUpdateStatus.releaseUnavailable,
          WindowsUpdateErrorCode.httpError,
          'GitHub respondió HTTP ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('La respuesta no es un objeto JSON.');
      }
      final release = _parseRelease(decoded);
      if (release == null) {
        return _checkFailure(
          WindowsUpdateStatus.invalidRelease,
          WindowsUpdateErrorCode.invalidRelease,
          'El release publicado no contiene metadatos estables válidos.',
        );
      }
      if (!release.updateVersion.isStable) {
        return _checkFailure(
          WindowsUpdateStatus.noStableRelease,
          WindowsUpdateErrorCode.noStableRelease,
          'El release más reciente no es una versión estable.',
        );
      }
      final versionComparison = UpdateVersion.compareRemoteToInstalled(
        remote: release.updateVersion,
        installed: installedUpdate,
      );
      if (versionComparison == null) {
        return _checkFailure(
          WindowsUpdateStatus.invalidRelease,
          WindowsUpdateErrorCode.invalidRelease,
          'No se puede comparar el build del release con el build instalado.',
        );
      }
      if (versionComparison <= 0) {
        return WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.upToDate,
          installedVersion: installed,
          release: release,
        );
      }

      final installers = release.assets
          .where((asset) => _isInstaller(asset, release.updateVersion))
          .toList();
      if (installers.isEmpty) {
        return WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.installerAssetMissing,
          installedVersion: installed,
          release: release,
          error: const WindowsUpdateError(
            code: WindowsUpdateErrorCode.installerAssetMissing,
            message: 'El release no incluye un instalador Windows SuelosAR.',
          ),
        );
      }
      if (installers.length != 1) {
        return WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.failed,
          installedVersion: installed,
          release: release,
          error: const WindowsUpdateError(
            code: WindowsUpdateErrorCode.invalidRelease,
            message: 'El release contiene varios instaladores candidatos.',
          ),
        );
      }

      final installer = installers.single;
      if (!_matchesReleaseAsset(installer, release.tag)) {
        return WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.failed,
          installedVersion: installed,
          release: release,
          installer: installer,
          error: const WindowsUpdateError(
            code: WindowsUpdateErrorCode.invalidRelease,
            message:
                'El nombre o URL del instalador no corresponde al release.',
          ),
        );
      }
      final checksum = await _resolveChecksum(release, installer);
      if (checksum == null) {
        return WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.checksumUnavailable,
          installedVersion: installed,
          release: release,
          installer: installer,
          error: const WindowsUpdateError(
            code: WindowsUpdateErrorCode.checksumUnavailable,
            message: 'El release no publica un SHA-256 verificable.',
          ),
        );
      }
      _DiscoveredDifferential? differential;
      try {
        differential = await _discoverDifferential(
          release: release,
          installed: installedUpdate,
        );
      } catch (_) {
        // Differential metadata is optional. The full Setup has already been
        // validated above, so a failed delta lookup must not block recovery.
        differential = null;
      }
      if (_stagingBaseUrl.isNotEmpty &&
          _requireDifferentialStaging &&
          differential == null) {
        return WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.invalidRelease,
          installedVersion: installed,
          release: release,
          installer: installer,
          error: const WindowsUpdateError(
            code: WindowsUpdateErrorCode.invalidRelease,
            message: 'El staging QA no ofreció un diferencial compatible; se bloqueó el Setup completo.',
          ),
        );
      }
      final result = WindowsUpdateCheckResult(
        status: WindowsUpdateStatus.updateAvailable,
        installedVersion: installed,
        release: release,
        installer: installer,
        sha256: checksum,
        differentialPackage: differential?.packageAsset,
        differentialPackageSha256: differential?.packageSha256,
        differentialManifest: differential?.manifestJson,
        differentialManifestJson: differential?.manifestText,
        differentialManifestSha256: differential?.manifestSha256,
      );
      _issuedDownloadChecks.clear();
      _issuedDownloadChecks.add(result);
      return result;
    } on TimeoutException {
      return _checkFailure(
        WindowsUpdateStatus.releaseUnavailable,
        WindowsUpdateErrorCode.timeout,
        'La consulta a GitHub superó el tiempo de espera.',
      );
    } on SocketException {
      return _checkFailure(
        WindowsUpdateStatus.releaseUnavailable,
        WindowsUpdateErrorCode.networkUnavailable,
        'No hay conexión disponible para consultar GitHub.',
      );
    } on http.ClientException {
      return _checkFailure(
        WindowsUpdateStatus.releaseUnavailable,
        WindowsUpdateErrorCode.networkUnavailable,
        'No se pudo conectar con GitHub.',
      );
    } on FormatException {
      return _checkFailure(
        WindowsUpdateStatus.invalidRelease,
        WindowsUpdateErrorCode.invalidJson,
        'GitHub devolvió metadatos inválidos.',
      );
    } catch (error) {
      return _checkFailure(
        WindowsUpdateStatus.failed,
        WindowsUpdateErrorCode.httpError,
        'Falló la consulta de actualizaciones: $error',
      );
    }
  }

  Future<WindowsUpdateOperationResult> downloadUpdate(
    WindowsUpdateCheckResult check, {
    void Function(WindowsUpdateProgress progress)? onProgress,
  }) async {
    if (!_isWindows) {
      return const WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.unsupportedPlatform,
      );
    }
    if (!_issuedDownloadChecks.remove(check) || !check.canDownload) {
      return _operationFailure(
        WindowsUpdateErrorCode.installerNotVerified,
        'La actualización no fue validada por esta instancia del servicio.',
      );
    }
    if (_downloading) {
      return _operationFailure(
        WindowsUpdateErrorCode.downloadInProgress,
        'Ya hay una descarga en curso.',
      );
    }
    _downloading = true;
    _abortDownload = Completer<void>();
    Directory? directory;
    File? partial;
    var completed = false;
    try {
      final storageDirectory =
          temporaryDirectory ?? _resolvePersistentUpdateDirectory();
      await storageDirectory.create(recursive: true);
      directory = await storageDirectory.createTemp('suelosar-update-');
      final asset = check.downloadAsset!;
      final expectedSha = check.downloadSha256!;
      final filename = _safeInstallerName(asset.name);
      partial = File(
        '${directory.path}${Platform.pathSeparator}$filename.part',
      );
      final response = await _send(
        asset.downloadUrl,
        abortTrigger: _abortDownload!.future,
      );
      if (response.statusCode != 200) {
        throw _DownloadException(
          WindowsUpdateErrorCode.httpError,
          'La descarga respondió HTTP ${response.statusCode}.',
        );
      }
      final total =
          int.tryParse(response.headers['content-length'] ?? '') ??
          (asset.size > 0 ? asset.size : null);
      var downloaded = 0;
      final output = partial.openWrite();
      try {
        await for (final chunk in response.stream.timeout(requestTimeout)) {
          output.add(chunk);
          downloaded += chunk.length;
          onProgress?.call(
            WindowsUpdateProgress(
              downloadedBytes: downloaded,
              totalBytes: total,
            ),
          );
        }
        await output.flush();
      } catch (_) {
        await output.close();
        rethrow;
      }
      await output.close();
      final installerFile = File(
        '${directory.path}${Platform.pathSeparator}$filename',
      );
      final actualLength = await partial.length();
      final expectedSize = asset.size > 0 ? asset.size : total;
      if (expectedSize != null && actualLength != expectedSize) {
        throw _DownloadException(
          WindowsUpdateErrorCode.sizeMismatch,
          'La descarga quedó incompleta ($actualLength de $expectedSize bytes).',
        );
      }
      final verification = await _verifyFile(
        partial.path,
        expectedSha,
        requireExeExtension: false,
        deleteMismatch: true,
      );
      if (!verification.succeeded) {
        throw _DownloadException(
          verification.error?.code ?? WindowsUpdateErrorCode.checksumMismatch,
          verification.error?.message ?? 'El SHA-256 no coincide.',
        );
      }
      await partial.rename(installerFile.path);
      PreparedWindowsDifferentialUpdate? prepared;
      if (check.usesDifferentialPackage) {
        final remoteJson = check.differentialManifest;
        final release = check.release;
        if (remoteJson == null || release == null) {
          throw const FormatException(
            'Falta el manifiesto diferencial validado.',
          );
        }
        final remote = WindowsDifferentialManifest.tryParse(
          remoteJson,
          expectedVersion: release.updateVersion.toString(),
          expectedRenderer: _renderer,
          expectedCompatibilityId:
              WindowsInstallationManifestService.compatibilityId,
        );
        final manifestFile = _installationManifestResolver();
        final localManifest =
            await WindowsInstallationManifestService.readManifest(manifestFile);
        if (remote == null ||
            localManifest == null ||
            !remote.supportsLocalManifest(localManifest)) {
          throw const FormatException(
            'El manifiesto diferencial o el baseline local dejó de ser válido.',
          );
        }
        final manifestText = check.differentialManifestJson;
        if (manifestText == null) {
          throw const FormatException('Falta el manifiesto remoto original.');
        }
        final remoteManifestFile = File(
          '${directory.path}${Platform.pathSeparator}remote-manifest.json',
        );
        await remoteManifestFile.writeAsString(manifestText, flush: true);
        final remoteManifestSha = await _fileSha256(remoteManifestFile);
        if (remoteManifestSha != check.differentialManifestSha256) {
          throw const FormatException(
            'El manifiesto diferencial cambió después de la comprobación.',
          );
        }
        prepared = await WindowsDifferentialPackageStager.stage(
          packageFile: installerFile,
          remote: remote,
          localManifest: localManifest,
          localManifestFile: manifestFile,
          installDirectory: Directory(
            _applicationExecutableResolver().parent.path,
          ),
          updateDirectory: directory,
        );
        final marker = File(
          '${directory.path}${Platform.pathSeparator}differential-update.json',
        );
        await marker.writeAsString(
          jsonEncode({
            'version': release.updateVersion.toString(),
            'baseline_version': UpdateVersion.fromPackageInfo(
              version: localManifest['app_version']! as String,
              buildNumber: '${localManifest['build_number']}',
            )!.toString(),
            'package_path': installerFile.path,
            'package_sha256': expectedSha,
            'manifest_sha256': remoteManifestSha,
            'installation_id': localManifest['installation_id'],
            'apply_list_sha256': prepared.applyListSha256,
            'remove_list_sha256': prepared.removeListSha256,
            'target_manifest_sha256': prepared.targetManifestSha256,
            'previous_manifest_sha256': prepared.previousManifestSha256,
            'target_verify_list_sha256': prepared.targetVerifyListSha256,
            'previous_verify_list_sha256': prepared.previousVerifyListSha256,
          }),
          flush: true,
        );
      }
      completed = true;
      _verifiedInstallers[installerFile.path] = _VerifiedInstaller(
        sha256: expectedSha,
        version: check.release!.updateVersion.toString(),
        differential: prepared,
      );
      onProgress?.call(
        WindowsUpdateProgress(
          downloadedBytes: actualLength,
          totalBytes: total ?? actualLength,
        ),
      );
      return WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.succeeded,
        installerPath: installerFile.path,
        sha256: expectedSha,
        differential: prepared != null,
      );
    } on _DownloadException catch (error) {
      return _operationFailure(error.code, error.message);
    } on TimeoutException {
      return _operationFailure(
        WindowsUpdateErrorCode.timeout,
        'La descarga superó el tiempo de espera.',
      );
    } on SocketException {
      return _operationFailure(
        WindowsUpdateErrorCode.networkUnavailable,
        'Se interrumpió la conexión durante la descarga.',
      );
    } on http.ClientException catch (error) {
      if (_abortDownload?.isCompleted ?? false) {
        return const WindowsUpdateOperationResult(
          status: WindowsUpdateOperationStatus.cancelled,
          error: WindowsUpdateError(
            code: WindowsUpdateErrorCode.downloadCancelled,
            message: 'Descarga cancelada.',
          ),
        );
      }
      return _operationFailure(
        WindowsUpdateErrorCode.downloadFailed,
        error.message,
      );
    } catch (error) {
      return _operationFailure(
        WindowsUpdateErrorCode.downloadFailed,
        'Falló la descarga: $error',
      );
    } finally {
      try {
        if (partial != null && await partial.exists()) await partial.delete();
        if (!completed && directory != null && await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } finally {
        _abortDownload = null;
        _downloading = false;
      }
    }
  }

  /// Revalidates a previously downloaded installer after an application restart.
  /// The path must remain inside SuelosAR's per-user update directory.
  Future<bool> restoreDownloadedInstaller({
    required String path,
    required String expectedSha256,
    required String version,
  }) async {
    if (!_isWindows || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expectedSha256)) {
      return false;
    }
    final parsedVersion = UpdateVersion.tryParse(version);
    if (parsedVersion == null || !parsedVersion.isStable) return false;

    try {
      final file = File(path).absolute;
      final updateRoot =
          temporaryDirectory ?? _resolvePersistentUpdateDirectory();
      final normalizedRoot = _normalizeWindowsPath(
        await updateRoot.resolveSymbolicLinks(),
      );
      final normalizedPath = _normalizeWindowsPath(
        await file.resolveSymbolicLinks(),
      );
      final isDifferential = file.path.toLowerCase().endsWith('.zip');
      final expectedName = isDifferential
          ? 'suelosar-differential-${parsedVersion.assetVersion}-win-x64-$_renderer.zip'
          : 'suelosar-setup-${parsedVersion.assetVersion}.exe';
      if (!normalizedPath.startsWith('$normalizedRoot\\') ||
          file.uri.pathSegments.last.toLowerCase() != expectedName ||
          !await file.exists()) {
        return false;
      }

      final verification = await _verifyFile(
        file.path,
        expectedSha256,
        requireExeExtension: !isDifferential,
        deleteMismatch: false,
      );
      if (!verification.succeeded) return false;
      final prepared = isDifferential
          ? await _restorePreparedDifferential(
              packageFile: file,
              expectedSha256: expectedSha256,
              expectedVersion: parsedVersion.toString(),
            )
          : null;
      if (isDifferential && prepared == null) return false;
      _verifiedInstallers[file.path] = _VerifiedInstaller(
        sha256: expectedSha256.toLowerCase(),
        version: parsedVersion.toString(),
        differential: prepared,
      );
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<PreparedWindowsDifferentialUpdate?> _restorePreparedDifferential({
    required File packageFile,
    required String expectedSha256,
    required String expectedVersion,
  }) async {
    try {
      final updateDirectory = packageFile.parent;
      final marker = File(
        '${updateDirectory.path}${Platform.pathSeparator}differential-update.json',
      );
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != expectedVersion ||
          decoded['package_path'] != packageFile.path ||
          decoded['package_sha256'] != expectedSha256.toLowerCase()) {
        return null;
      }
      File child(String name) =>
          File('${updateDirectory.path}${Platform.pathSeparator}$name');
      final stagingDirectory = Directory(
        '${updateDirectory.path}${Platform.pathSeparator}staged',
      );
      final values = <(File, String)>[
        (
          child('remote-manifest.json'),
          decoded['manifest_sha256'] as String? ?? '',
        ),
        (child('apply.tsv'), decoded['apply_list_sha256'] as String? ?? ''),
        (child('remove.txt'), decoded['remove_list_sha256'] as String? ?? ''),
        (
          child('target-manifest.json'),
          decoded['target_manifest_sha256'] as String? ?? '',
        ),
        (
          child('previous-manifest.json'),
          decoded['previous_manifest_sha256'] as String? ?? '',
        ),
        (
          child('target-verify.tsv'),
          decoded['target_verify_list_sha256'] as String? ?? '',
        ),
        (
          child('previous-verify.tsv'),
          decoded['previous_verify_list_sha256'] as String? ?? '',
        ),
      ];
      for (final (file, digest) in values) {
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
            !await _isSafeUpdateChild(updateDirectory, file) ||
            await _fileSha256(file) != digest) {
          return null;
        }
      }
      if (!await stagingDirectory.exists() ||
          !await _isSafeUpdateChild(
            updateDirectory,
            File(stagingDirectory.path),
          )) {
        return null;
      }
      final applyList = child('apply.tsv');
      final removeList = child('remove.txt');
      final targetManifest = child('target-manifest.json');
      final previousManifest = child('previous-manifest.json');
      final targetVerifyList = child('target-verify.tsv');
      final previousVerifyList = child('previous-verify.tsv');
      return PreparedWindowsDifferentialUpdate(
        stagingDirectory: stagingDirectory,
        applyList: applyList,
        applyListSha256: decoded['apply_list_sha256']! as String,
        removeList: removeList,
        removeListSha256: decoded['remove_list_sha256']! as String,
        targetManifest: targetManifest,
        targetManifestSha256: decoded['target_manifest_sha256']! as String,
        previousManifest: previousManifest,
        previousManifestSha256: decoded['previous_manifest_sha256']! as String,
        targetVerifyList: targetVerifyList,
        targetVerifyListSha256: decoded['target_verify_list_sha256']! as String,
        previousVerifyList: previousVerifyList,
        previousVerifyListSha256:
            decoded['previous_verify_list_sha256']! as String,
      );
    } on Object {
      return null;
    }
  }

  Future<bool> _isSafeUpdateChild(Directory root, File child) async {
    try {
      final normalizedRoot = _normalizeWindowsPath(
        await root.resolveSymbolicLinks(),
      );
      final normalizedChild = _normalizeWindowsPath(
        await child.resolveSymbolicLinks(),
      );
      return normalizedChild.startsWith('$normalizedRoot\\');
    } on FileSystemException {
      return false;
    }
  }

  Future<String> _fileSha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Directory _resolvePersistentUpdateDirectory() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      throw const FileSystemException('LOCALAPPDATA is unavailable.');
    }
    return Directory(
      '$localAppData${Platform.pathSeparator}SuelosAR'
      '${Platform.pathSeparator}Updates',
    );
  }

  String _normalizeWindowsPath(String value) =>
      value.replaceAll('/', '\\').replaceAll(RegExp(r'\\+$'), '').toLowerCase();

  void cancelDownload() {
    final abort = _abortDownload;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  Future<WindowsUpdateOperationResult> verifyDownloadedInstaller(
    String path,
    String expectedSha256,
  ) async {
    final known = _verifiedInstallers[path];
    if (known == null ||
        known.sha256.toLowerCase() != expectedSha256.toLowerCase()) {
      return _operationFailure(
        WindowsUpdateErrorCode.installerNotVerified,
        'El archivo no fue descargado y registrado por este servicio.',
      );
    }
    final result = await _verifyFile(
      path,
      expectedSha256,
      requireExeExtension: known.differential == null,
      deleteMismatch: true,
    );
    if (!result.succeeded) _verifiedInstallers.remove(path);
    return result;
  }

  Future<WindowsUpdateOperationResult> _verifyFile(
    String path,
    String expectedSha256, {
    required bool requireExeExtension,
    required bool deleteMismatch,
  }) async {
    if (!_isWindows) {
      return const WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.unsupportedPlatform,
      );
    }
    if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedSha256)) {
      return _operationFailure(
        WindowsUpdateErrorCode.checksumUnavailable,
        'El SHA-256 esperado no es válido.',
      );
    }
    final file = File(path);
    try {
      if (!await file.exists() ||
          (requireExeExtension && !path.toLowerCase().endsWith('.exe'))) {
        return _operationFailure(
          WindowsUpdateErrorCode.installerNotVerified,
          'No existe un instalador .exe válido en la ruta indicada.',
        );
      }
      final actual = await sha256.bind(file.openRead()).first;
      final digest = actual.toString();
      if (digest.toLowerCase() != expectedSha256.toLowerCase()) {
        if (deleteMismatch) await file.delete();
        return _operationFailure(
          WindowsUpdateErrorCode.checksumMismatch,
          'El SHA-256 del instalador no coincide; se eliminó el archivo.',
        );
      }
      return WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.succeeded,
        installerPath: file.path,
        sha256: digest,
      );
    } on FileSystemException catch (error) {
      return _operationFailure(
        WindowsUpdateErrorCode.downloadFailed,
        'No se pudo leer el instalador: ${error.message}',
      );
    }
  }

  Future<WindowsUpdateOperationResult> launchInstaller(String path) async {
    if (!_isWindows) {
      return const WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.unsupportedPlatform,
      );
    }
    if (!canLaunchInstaller) {
      return const WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.lifecycleUnavailable,
        error: WindowsUpdateError(
          code: WindowsUpdateErrorCode.installerLifecycleUnavailable,
          message: 'El instalador queda bloqueado porque faltan componentes ejecutables del ciclo seguro de actualización.',
        ),
      );
    }
    final verified = _verifiedInstallers[path];
    if (verified == null || !await File(path).exists()) {
      return _operationFailure(
        WindowsUpdateErrorCode.installerNotVerified,
        'Sólo puede iniciarse un instalador descargado y verificado por el servicio.',
      );
    }
    final verification = await _verifyFile(
      path,
      verified.sha256,
      requireExeExtension: verified.differential == null,
      deleteMismatch: true,
    );
    if (!verification.succeeded) {
      _verifiedInstallers.remove(path);
      return verification;
    }
    try {
      final prepared = verified.differential;
      if (prepared != null) {
        final localManifest =
            await WindowsInstallationManifestService.readManifest(
              _installationManifestResolver(),
            );
        if (localManifest == null ||
            localManifest['installation_id'] is! String) {
          return _operationFailure(
            WindowsUpdateErrorCode.installerNotVerified,
            'No se pudo validar la identidad de instalación del paquete diferencial.',
          );
        }
        await _differentialLifecycleStarter(
          prepared,
          verified.version,
          localManifest['installation_id']! as String,
        );
      } else {
        // The helper validates first, then waits for this app to exit before
        // presenting Inno Setup's normal UAC and installation flow.
        await _installerLifecycleStarter(
          path,
          verified.sha256,
          verified.version,
          File(path).parent.path,
        );
      }
      return WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.succeeded,
        installerPath: path,
        sha256: verified.sha256,
        differential: prepared != null,
      );
    } on ProcessException catch (error) {
      return _operationFailure(
        WindowsUpdateErrorCode.launchFailed,
        'Windows no pudo iniciar el instalador: ${error.message}',
      );
    } on FileSystemException catch (error) {
      return _operationFailure(
        WindowsUpdateErrorCode.launchFailed,
        'No se pudo acceder al instalador: ${error.message}',
      );
    } on TimeoutException catch (error) {
      return _operationFailure(
        WindowsUpdateErrorCode.launchFailed,
        'El auxiliar de instalación no respondió: $error',
      );
    } catch (error) {
      return _operationFailure(
        WindowsUpdateErrorCode.launchFailed,
        'No se pudo preparar la actualización: $error',
      );
    }
  }

  void close() => _client.close();

  Future<_DiscoveredDifferential?> _discoverDifferential({
    required WindowsReleaseInfo release,
    required UpdateVersion installed,
  }) async {
    final renderer = _renderer;
    final manifestName = WindowsDifferentialManifest.manifestAssetName(
      release.updateVersion,
      renderer,
    );
    final manifestAssets = release.assets
        .where((asset) => asset.name == manifestName)
        .toList();
    if (manifestAssets.length != 1) return null;
    final manifestAsset = manifestAssets.single;
    if (manifestAsset.size <= 0 ||
        manifestAsset.size > 4 * 1024 * 1024 ||
        !_matchesReleaseAsset(manifestAsset, release.tag)) {
      return null;
    }
    final manifestSha = await _resolveChecksum(release, manifestAsset);
    if (manifestSha == null) return null;
    final manifestResponse = await _get(manifestAsset.downloadUrl);
    if (manifestResponse.statusCode != 200 ||
        (manifestAsset.size > 0 &&
            manifestResponse.bodyBytes.length != manifestAsset.size)) {
      return null;
    }
    final actualManifestSha = sha256
        .convert(manifestResponse.bodyBytes)
        .toString();
    if (actualManifestSha != manifestSha) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(manifestResponse.body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final manifest = WindowsDifferentialManifest.tryParse(
      decoded,
      expectedVersion: release.updateVersion.toString(),
      expectedRenderer: renderer,
      expectedCompatibilityId:
          WindowsInstallationManifestService.compatibilityId,
    );
    if (manifest == null ||
        manifest.minimumSupportedBaseline.toString() != installed.toString()) {
      return null;
    }
    final targetHelper = manifest.files.where(
      (file) => file.path.toLowerCase() == 'suelosar_update_helper.exe',
    );
    if (targetHelper.length != 1 ||
        targetHelper.single.classification != 'executable') {
      return null;
    }
    final packageHelper = manifest.package.files.where(
      (file) => file.path.toLowerCase() == 'suelosar_update_helper.exe',
    );
    if (packageHelper.length > 1 ||
        (packageHelper.isNotEmpty &&
            (packageHelper.single.changeType != 'modified' ||
                packageHelper.single.classification != 'executable'))) {
      return null;
    }
    final localFile = _installationManifestResolver();
    final localManifest = await WindowsInstallationManifestService.readManifest(
      localFile,
    );
    if (localManifest == null ||
        !manifest.supportsLocalManifest(localManifest)) {
      return null;
    }
    final localHelper = (localManifest['files']! as List)
        .whereType<Map<String, dynamic>>()
        .where(
          (file) =>
              file['managed_by_updater'] == true &&
              (file['path'] as String).toLowerCase() ==
                  'suelosar_update_helper.exe',
        )
        .toList();
    if (localHelper.length != 1 ||
        (packageHelper.isEmpty &&
            (localHelper.single['size'] != targetHelper.single.size ||
                localHelper.single['sha256'] != targetHelper.single.sha256))) {
      return null;
    }
    final packageAssets = release.assets
        .where((asset) => asset.name == manifest.package.name)
        .toList();
    if (packageAssets.length != 1) return null;
    final packageAsset = packageAssets.single;
    if (packageAsset.size != manifest.package.size ||
        !_matchesReleaseAsset(packageAsset, release.tag)) {
      return null;
    }
    final packageSha = await _resolveChecksum(release, packageAsset);
    if (packageSha == null || packageSha != manifest.package.sha256) {
      return null;
    }
    return _DiscoveredDifferential(
      packageAsset: packageAsset,
      packageSha256: packageSha,
      manifestJson: decoded,
      manifestText: manifestResponse.body,
      manifestSha256: manifestSha,
    );
  }

  static String get _renderer =>
      const bool.fromEnvironment(
        'SUelosAR_MAPLIBRE_NATIVE',
        defaultValue: false,
      )
      ? 'maplibre-native'
      : 'flutter-map-fallback';

  static File _resolveInstallationManifest() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      throw const FileSystemException('LOCALAPPDATA is unavailable.');
    }
    return File(
      '$localAppData${Platform.pathSeparator}SuelosAR'
      '${Platform.pathSeparator}${WindowsInstallationManifestService.manifestDirectoryName}'
      '${Platform.pathSeparator}${WindowsInstallationManifestService.manifestFileName}',
    );
  }

  Future<http.Response> _get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async =>
      http.Response.fromStream(await _send(uri, headers: headers))
          .timeout(requestTimeout);

  Future<http.StreamedResponse> _send(
    Uri uri, {
    Future<void>? abortTrigger,
    Map<String, String> headers = const {},
  }) async {
    if (uri.scheme != 'https') {
      throw const _DownloadException(
        WindowsUpdateErrorCode.httpError,
        'Solo se permiten conexiones HTTPS.',
      );
    }
    var current = _routeStagingAsset(uri);
    for (var redirect = 0; redirect <= 5; redirect++) {
      final request =
          http.AbortableRequest('GET', current, abortTrigger: abortTrigger)
            ..followRedirects = false
            ..headers['User-Agent'] = _userAgent
            ..headers['Accept'] = 'application/vnd.github+json';
      request.headers.addAll(headers);
      final response = await _client.send(request).timeout(requestTimeout);
      if (response.statusCode < 300 || response.statusCode >= 400) {
        return response;
      }
      final location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null || redirect == 5) {
        throw const _DownloadException(
          WindowsUpdateErrorCode.httpError,
          'Redirección HTTPS inválida o demasiado larga.',
        );
      }
      final destination = current.resolve(location);
      if (!_isAllowedRedirect(current, destination)) {
        throw const _DownloadException(
          WindowsUpdateErrorCode.httpError,
          'El servidor intentó redirigir a un origen no autorizado.',
        );
      }
      current = destination;
    }
    throw StateError('Unreachable redirect state');
  }

  Uri _routeStagingAsset(Uri uri) {
    if (_stagingBaseUrl.isEmpty || uri.host.toLowerCase() != 'github.com') {
      return uri;
    }
    final expectedPrefix =
        '/$repositoryOwner/$repositoryName/releases/download/';
    if (!uri.path.startsWith(expectedPrefix)) return uri;
    final base = Uri.parse(_stagingBaseUrl);
    return base.replace(path: uri.path, query: uri.hasQuery ? uri.query : null);
  }

  WindowsReleaseInfo? _parseRelease(Map<String, dynamic> json) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final tag = json['tag_name'];
    final published = json['published_at'];
    final assetsJson = json['assets'];
    final htmlUrl = json['html_url'];
    final updateVersion = tag is String ? UpdateVersion.tryParse(tag) : null;
    final publishedAt = published is String
        ? DateTime.tryParse(published)
        : null;
    final releaseUri = htmlUrl is String ? Uri.tryParse(htmlUrl) : null;
    final expectedReleasePath =
        '/$repositoryOwner/$repositoryName/releases/tag/$tag';
    final isGitHubReleasePage =
        releaseUri != null &&
        _isGitHubOrigin(releaseUri) &&
        releaseUri.path == expectedReleasePath;
    final isStagingReleasePage =
        releaseUri != null &&
        _isConfiguredStagingOrigin(releaseUri) &&
        releaseUri.path == expectedReleasePath;
    if (tag is! String ||
        updateVersion == null ||
        publishedAt == null ||
        assetsJson is! List ||
        (!isGitHubReleasePage && !isStagingReleasePage)) {
      return null;
    }
    final assets = <WindowsReleaseAsset>[];
    for (final raw in assetsJson) {
      if (raw is! Map<String, dynamic>) return null;
      final name = raw['name'];
      final url = raw['browser_download_url'];
      final size = raw['size'];
      final uri = url is String ? Uri.tryParse(url) : null;
      if (name is! String ||
          uri?.scheme != 'https' ||
          size is! int ||
          size < 0) {
        return null;
      }
      assets.add(
        WindowsReleaseAsset(
          name: name,
          downloadUrl: uri!,
          size: size,
          digest: raw['digest'] is String ? raw['digest'] as String : null,
          id: raw['id'] is int ? raw['id'] as int : null,
        ),
      );
    }
    return WindowsReleaseInfo(
      tag: tag,
      version: updateVersion.semanticVersion,
      name: json['name'] is String ? json['name'] as String : tag,
      description: json['body'] is String ? json['body'] as String : '',
      publishedAt: publishedAt.toUtc(),
      assets: List.unmodifiable(assets),
      htmlUrl: releaseUri,
    );
  }

  bool _isInstaller(WindowsReleaseAsset asset, UpdateVersion version) =>
      version.isStable &&
      asset.name == 'SuelosAR-Setup-${version.assetVersion}.exe';

  bool _matchesReleaseAsset(WindowsReleaseAsset asset, String tag) {
    final uri = asset.downloadUrl;
    final expectedPath = '/$repositoryOwner/$repositoryName/releases/download/';
    return uri.scheme == 'https' &&
        !_hasUriCredentials(uri) &&
        (_isGitHubOrigin(uri) || _isConfiguredStagingOrigin(uri)) &&
        uri.pathSegments.length == 6 &&
        uri.path.startsWith(expectedPath) &&
        uri.pathSegments[4] == tag &&
        uri.pathSegments[5] == asset.name &&
        !asset.name.contains('/') &&
        !asset.name.contains('\\');
  }

  bool _isConfiguredStagingOrigin(Uri uri) {
    if (_stagingBaseUrl.isEmpty) return false;
    final stagingBase = Uri.tryParse(_stagingBaseUrl);
    return stagingBase != null &&
        uri.scheme == stagingBase.scheme &&
        !_hasUriCredentials(uri) &&
        uri.host.toLowerCase() == stagingBase.host.toLowerCase() &&
        uri.port == stagingBase.port;
  }

  bool _isGitHubOrigin(Uri uri) =>
      uri.scheme == 'https' &&
      !_hasUriCredentials(uri) &&
      uri.host.toLowerCase() == 'github.com' &&
      uri.port == 443;

  bool _isAllowedRedirect(Uri from, Uri to) {
    if (to.scheme != 'https' || _hasUriCredentials(to)) return false;
    if (_isConfiguredStagingOrigin(from)) {
      return _isConfiguredStagingOrigin(to);
    }
    if (!_isAllowedGitHubTransportOrigin(from) ||
        !_isAllowedGitHubTransportOrigin(to)) {
      return false;
    }
    final sourceHost = from.host.toLowerCase();
    final targetHost = to.host.toLowerCase();
    if (sourceHost == 'api.github.com') {
      return targetHost == 'api.github.com' || targetHost == 'github.com';
    }
    if (sourceHost == 'github.com') {
      return targetHost == 'github.com' ||
          _githubAssetHosts.contains(targetHost);
    }
    return _githubAssetHosts.contains(sourceHost) &&
        _githubAssetHosts.contains(targetHost);
  }

  bool _isAllowedGitHubTransportOrigin(Uri uri) =>
      uri.scheme == 'https' &&
      !_hasUriCredentials(uri) &&
      uri.port == 443 &&
      (uri.host.toLowerCase() == 'github.com' ||
          uri.host.toLowerCase() == 'api.github.com' ||
          _githubAssetHosts.contains(uri.host.toLowerCase()));

  static const _githubAssetHosts = <String>{
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
  };

  bool _hasUriCredentials(Uri uri) => uri.userInfo.isNotEmpty;

  Future<String?> _resolveChecksum(
    WindowsReleaseInfo release,
    WindowsReleaseAsset installer,
  ) async {
    final digest = installer.digest;
    if (digest != null) {
      final match = RegExp(r'^sha256:([a-fA-F0-9]{64})$').firstMatch(digest);
      if (match != null) return match.group(1)!.toLowerCase();
    }
    final sidecars = release.assets
        .where((asset) => asset.name == '${installer.name}.sha256')
        .toList();
    if (sidecars.length != 1 ||
        !_matchesReleaseAsset(sidecars.single, release.tag)) {
      return null;
    }
    final response = await _get(sidecars.single.downloadUrl);
    if (response.statusCode != 200) return null;
    final content = response.body.trim();
    final match = RegExp(r'^([a-fA-F0-9]{64})(?:\s+\*?([^\s]+))?$')
        .firstMatch(content);
    if (match == null ||
        (match.group(2) != null && match.group(2) != installer.name)) {
      return null;
    }
    return match.group(1)!.toLowerCase();
  }

  String _safeInstallerName(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');

  static Future<String> _readInstalledVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final version = UpdateVersion.fromPackageInfo(
      version: packageInfo.version,
      buildNumber: packageInfo.buildNumber,
    );
    return version?.toString() ?? '';
  }

  static File _resolveBundledInstallerHelper() {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    return File(
      '${executableDirectory.path}${Platform.pathSeparator}suelosar_update_helper.exe',
    );
  }

  Future<void> _startInstallerLifecycle(
    String installerPath,
    String expectedSha256,
    String version,
    String updateDirectory,
  ) async {
    final bundledHelper = _installerHelperResolver();
    if (!await bundledHelper.exists()) {
      throw ProcessException(
        bundledHelper.path,
        const [],
        'No se encontró el auxiliar de instalación incluido con SuelosAR.',
      );
    }

    final helperDirectory = await Directory.systemTemp.createTemp(
      'suelosar-update-helper-',
    );
    final helperCopy = File(
      '${helperDirectory.path}${Platform.pathSeparator}suelosar_update_helper.exe',
    );
    await bundledHelper.copy(helperCopy.path);
    final process = await Process.start(helperCopy.path, [
      installerPath,
      expectedSha256,
      version,
      _applicationExecutableResolver().path,
      updateDirectory,
      pid.toString(),
      helperDirectory.path,
    ], runInShell: false);
    unawaited(process.stderr.drain<void>());
    try {
      final status = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 45));
      if (status != 'READY') {
        final exitCode = await process.exitCode;
        throw ProcessException(
          helperCopy.path,
          const [],
          'El auxiliar rechazó el inicio seguro (estado $status, código $exitCode).',
        );
      }
    } on TimeoutException {
      // Leave the helper's bounded natural wait intact. Since the application
      // stays open on this path, the helper will refuse to start setup.
      throw ProcessException(
        helperCopy.path,
        const [],
        'El auxiliar no confirmó que estaba listo para instalar.',
      );
    }
  }

  Future<void> _startDifferentialLifecycle(
    PreparedWindowsDifferentialUpdate prepared,
    String version,
    String installationId,
  ) async {
    final currentManifest =
        await WindowsInstallationManifestService.readManifest(
          _installationManifestResolver(),
        );
    if (currentManifest == null ||
        currentManifest['installation_id'] != installationId) {
      throw const FormatException(
        'La identidad de instalación cambió durante la preparación.',
      );
    }
    final baseline = UpdateVersion.fromPackageInfo(
      version: currentManifest['app_version']! as String,
      buildNumber: '${currentManifest['build_number']}',
    );
    if (baseline == null) {
      throw const FormatException('El baseline local no es válido.');
    }
    final helperDirectory = await Directory.systemTemp.createTemp(
      'suelosar-update-helper-',
    );
    final app = _applicationExecutableResolver();
    final helperCopy = File(
      '${helperDirectory.path}${Platform.pathSeparator}suelosar_update_helper.exe',
    );
    final targetInventory = await prepared.targetVerifyList.readAsLines();
    final helperEntry = targetInventory
        .map((line) => line.split('\t'))
        .where(
          (columns) =>
              columns.length == 3 &&
              columns[0].toLowerCase() == 'suelosar_update_helper.exe',
        )
        .toList();
    if (helperEntry.length != 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(helperEntry.single[2])) {
      throw const FormatException(
        'El target no contiene el helper diferencial esperado.',
      );
    }
    var helper = File(
      '${prepared.stagingDirectory.path}${Platform.pathSeparator}'
      'suelosar_update_helper.exe',
    );
    if (!await helper.exists()) {
      helper = File(
        '${app.parent.path}${Platform.pathSeparator}'
        'suelosar_update_helper.exe',
      );
    }
    if (!await helper.exists() ||
        await helper.length() != int.parse(helperEntry.single[1]) ||
        await _fileSha256(helper) != helperEntry.single[2]) {
      throw const FormatException(
        'El helper diferencial del paquete no coincide con el inventario target.',
      );
    }
    await helper.copy(helperCopy.path);
    if (await _fileSha256(helperCopy) != helperEntry.single[2]) {
      throw const FormatException(
        'La copia temporal del helper no pasó su verificación SHA-256.',
      );
    }
    final process = await Process.start(helperCopy.path, [
      '--differential',
      prepared.applyList.parent.path,
      prepared.stagingDirectory.path,
      prepared.applyList.path,
      prepared.applyListSha256,
      prepared.removeList.path,
      prepared.removeListSha256,
      prepared.targetManifest.path,
      prepared.targetManifestSha256,
      prepared.previousManifest.path,
      prepared.previousManifestSha256,
      prepared.targetVerifyList.path,
      prepared.targetVerifyListSha256,
      prepared.previousVerifyList.path,
      prepared.previousVerifyListSha256,
      _installationManifestResolver().path,
      app.parent.path,
      app.path,
      baseline.toString(),
      version,
      installationId,
      pid.toString(),
      helperDirectory.path,
    ], runInShell: false);
    unawaited(process.stderr.drain<void>());
    try {
      final status = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 45));
      if (status != 'READY') {
        final exitCode = await process.exitCode;
        throw ProcessException(
          helperCopy.path,
          const [],
          'El auxiliar diferencial rechazó la preparación '
          '(estado $status, código $exitCode).',
        );
      }
    } on TimeoutException {
      throw ProcessException(
        helperCopy.path,
        const [],
        'El auxiliar diferencial no confirmó que estaba listo.',
      );
    }
  }

  WindowsUpdateCheckResult _checkFailure(
    WindowsUpdateStatus status,
    WindowsUpdateErrorCode code,
    String message,
  ) => WindowsUpdateCheckResult(
    status: status,
    error: WindowsUpdateError(code: code, message: message),
  );

  WindowsUpdateOperationResult _operationFailure(
    WindowsUpdateErrorCode code,
    String message,
  ) => WindowsUpdateOperationResult(
    status: WindowsUpdateOperationStatus.failed,
    error: WindowsUpdateError(code: code, message: message),
  );
}

class _DownloadException implements Exception {
  const _DownloadException(this.code, this.message);
  final WindowsUpdateErrorCode code;
  final String message;
}

class _VerifiedInstaller {
  const _VerifiedInstaller({
    required this.sha256,
    required this.version,
    this.differential,
  });

  final String sha256;
  final String version;
  final PreparedWindowsDifferentialUpdate? differential;
}

class _DiscoveredDifferential {
  const _DiscoveredDifferential({
    required this.packageAsset,
    required this.packageSha256,
    required this.manifestJson,
    required this.manifestText,
    required this.manifestSha256,
  });

  final WindowsReleaseAsset packageAsset;
  final String packageSha256;
  final Map<String, dynamic> manifestJson;
  final String manifestText;
  final String manifestSha256;
}
