import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'windows_update_models.dart';

class WindowsUpdateService {
  WindowsUpdateService({
    http.Client? client,
    InstalledVersionReader? installedVersionReader,
    InstallerStarter? installerStarter,
    InstallerLifecycleStarter? installerLifecycleStarter,
    File Function()? installerHelperResolver,
    File Function()? applicationExecutableResolver,
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
       _isWindows = isWindows ?? Platform.isWindows {
    _installerLifecycleStarter =
        installerLifecycleStarter ??
        (installerStarter == null
            ? _startInstallerLifecycle
            : (path, _, _, _) => installerStarter(path));
  }

  static const repositoryOwner = 'eljerexd';
  static const repositoryName = 'Web-SuelosAR';
  static const latestReleaseUrl =
      'https://api.github.com/repos/$repositoryOwner/$repositoryName/releases/latest';
  static const _userAgent = 'SuelosAR-Windows-Updater';
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
  final File Function() _installerHelperResolver;
  final File Function() _applicationExecutableResolver;
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
      final installed = SemanticVersion.tryParse(
        await _installedVersionReader(),
      );
      if (installed == null) {
        return _checkFailure(
          WindowsUpdateStatus.failed,
          WindowsUpdateErrorCode.invalidRelease,
          'No se pudo interpretar la versión instalada.',
        );
      }
      final response = await _get(
        Uri.parse(latestReleaseUrl),
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
      if (!release.version.isStable) {
        return _checkFailure(
          WindowsUpdateStatus.noStableRelease,
          WindowsUpdateErrorCode.noStableRelease,
          'El release más reciente no es una versión estable.',
        );
      }
      if (release.version.compareTo(installed) <= 0) {
        return WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.upToDate,
          installedVersion: installed,
          release: release,
        );
      }

      final installers = release.assets
          .where((asset) => _isInstaller(asset, release.version))
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
      final result = WindowsUpdateCheckResult(
        status: WindowsUpdateStatus.updateAvailable,
        installedVersion: installed,
        release: release,
        installer: installer,
        sha256: checksum,
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
      final filename = _safeInstallerName(check.installer!.name);
      partial = File(
        '${directory.path}${Platform.pathSeparator}$filename.part',
      );
      final response = await _send(
        check.installer!.downloadUrl,
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
          (check.installer!.size > 0 ? check.installer!.size : null);
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
      final expectedSize = check.installer!.size > 0
          ? check.installer!.size
          : total;
      if (expectedSize != null && actualLength != expectedSize) {
        throw _DownloadException(
          WindowsUpdateErrorCode.sizeMismatch,
          'La descarga quedó incompleta ($actualLength de $expectedSize bytes).',
        );
      }
      final verification = await _verifyFile(
        partial.path,
        check.sha256!,
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
      completed = true;
      _verifiedInstallers[installerFile.path] = _VerifiedInstaller(
        sha256: check.sha256!,
        version: check.release!.version.toString(),
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
        sha256: check.sha256,
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
    final parsedVersion = SemanticVersion.tryParse(version);
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
      if (!normalizedPath.startsWith('$normalizedRoot\\') ||
          file.uri.pathSegments.last.toLowerCase() !=
              'suelosar-setup-${parsedVersion.toString()}.exe' ||
          !await file.exists()) {
        return false;
      }

      final verification = await _verifyFile(
        file.path,
        expectedSha256,
        requireExeExtension: true,
        deleteMismatch: false,
      );
      if (!verification.succeeded) return false;
      _verifiedInstallers[file.path] = _VerifiedInstaller(
        sha256: expectedSha256.toLowerCase(),
        version: parsedVersion.toString(),
      );
      return true;
    } on FileSystemException {
      return false;
    }
  }

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
      requireExeExtension: true,
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
          message:
              'El instalador queda bloqueado porque faltan componentes ejecutables del ciclo seguro de actualización.',
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
      requireExeExtension: true,
      deleteMismatch: true,
    );
    if (!verification.succeeded) {
      _verifiedInstallers.remove(path);
      return verification;
    }
    try {
      // The helper validates first, then waits for this app to exit before it
      // presents Inno Setup's normal UAC and interactive installation flow.
      await _installerLifecycleStarter(
        path,
        verified.sha256,
        verified.version,
        File(path).parent.path,
      );
      return WindowsUpdateOperationResult(
        status: WindowsUpdateOperationStatus.succeeded,
        installerPath: path,
        sha256: verified.sha256,
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

  Future<http.Response> _get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async => http.Response.fromStream(
    await _send(uri, headers: headers),
  ).timeout(requestTimeout);

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
    var current = uri;
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
      current = current.resolve(location);
      if (current.scheme != 'https') {
        throw const _DownloadException(
          WindowsUpdateErrorCode.httpError,
          'GitHub intentó redirigir a una URL no segura.',
        );
      }
    }
    throw StateError('Unreachable redirect state');
  }

  WindowsReleaseInfo? _parseRelease(Map<String, dynamic> json) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final tag = json['tag_name'];
    final published = json['published_at'];
    final assetsJson = json['assets'];
    final htmlUrl = json['html_url'];
    final version = tag is String ? SemanticVersion.tryParse(tag) : null;
    final publishedAt = published is String
        ? DateTime.tryParse(published)
        : null;
    final releaseUri = htmlUrl is String ? Uri.tryParse(htmlUrl) : null;
    if (tag is! String ||
        version == null ||
        publishedAt == null ||
        assetsJson is! List ||
        releaseUri?.scheme != 'https' ||
        releaseUri?.host != 'github.com' ||
        releaseUri?.path !=
            '/$repositoryOwner/$repositoryName/releases/tag/$tag') {
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
      version: version,
      name: json['name'] is String ? json['name'] as String : tag,
      description: json['body'] is String ? json['body'] as String : '',
      publishedAt: publishedAt.toUtc(),
      assets: List.unmodifiable(assets),
      htmlUrl: releaseUri!,
    );
  }

  bool _isInstaller(WindowsReleaseAsset asset, SemanticVersion version) =>
      version.isStable &&
      asset.name ==
          'SuelosAR-Setup-${version.major}.${version.minor}.${version.patch}.exe';

  bool _matchesReleaseAsset(WindowsReleaseAsset asset, String tag) {
    final expectedPath = '/$repositoryOwner/$repositoryName/releases/download/';
    return asset.downloadUrl.host.toLowerCase() == 'github.com' &&
        asset.downloadUrl.pathSegments.length == 6 &&
        asset.downloadUrl.path.startsWith(expectedPath) &&
        asset.downloadUrl.pathSegments[4] == tag &&
        asset.downloadUrl.pathSegments[5] == asset.name &&
        !asset.name.contains('/') &&
        !asset.name.contains('\\');
  }

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
    final match = RegExp(
      r'^([a-fA-F0-9]{64})(?:\s+\*?([^\s]+))?$',
    ).firstMatch(content);
    if (match == null ||
        (match.group(2) != null && match.group(2) != installer.name)) {
      return null;
    }
    return match.group(1)!.toLowerCase();
  }

  String _safeInstallerName(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  static Future<String> _readInstalledVersion() async =>
      (await PackageInfo.fromPlatform()).version;

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
  const _VerifiedInstaller({required this.sha256, required this.version});

  final String sha256;
  final String version;
}
