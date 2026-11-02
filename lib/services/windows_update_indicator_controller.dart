import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'windows_update_service.dart';
import 'windows_update_preview_mode.dart';

typedef WindowsUpdateCheck = Future<WindowsUpdateCheckResult> Function();
typedef WindowsUpdatePreferencesLoader = Future<SharedPreferences> Function();
typedef InstalledAppVersionReader = Future<String> Function();
typedef WindowsUpdateDownloadRunner =
    Future<WindowsUpdateOperationResult> Function(
      WindowsUpdateCheckResult check, {
      void Function(WindowsUpdateProgress progress)? onProgress,
    });
typedef WindowsUpdateDownloadCanceller = void Function();

enum WindowsUpdateIndicatorState { checking, upToDate, updateAvailable, error }

enum WindowsUpdateDownloadState {
  idle,
  downloading,
  cancelling,
  completed,
  cancelled,
  failed,
}

/// Owns the Windows update indicator state and its durable release snapshot.
///
/// A persisted release is informational only. Downloads still require a fresh
/// [WindowsUpdateCheckResult] issued by the same [WindowsUpdateService]
/// instance, as enforced by the Phase 1 service.
class WindowsUpdateIndicatorController extends ChangeNotifier {
  WindowsUpdateIndicatorController({
    required this.isWindows,
    required this._checkForUpdates,
    WindowsUpdatePreferencesLoader? preferencesLoader,
    InstalledAppVersionReader? installedVersionReader,
    this.downloadRunner,
    this.downloadCanceller,
    DateTime Function()? clock,
    this._onDispose,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _installedVersionReader =
           installedVersionReader ?? _readInstalledVersion,
       _clock = clock ?? DateTime.now,
       _developmentPreviewRelease = null;

  WindowsUpdateIndicatorController._developmentPreview()
    : isWindows = true,
      _checkForUpdates = _previewCheckMustNotRun,
      _preferencesLoader = _previewPreferencesMustNotLoad,
      _installedVersionReader = _readInstalledVersion,
      downloadRunner = null,
      downloadCanceller = null,
      _clock = DateTime.now,
      _developmentPreviewRelease = _createDevelopmentPreviewRelease(),
      _onDispose = null;

  factory WindowsUpdateIndicatorController.forDevelopmentPreview() {
    if (!updatePreviewModeEnabled) {
      throw StateError(
        'Update preview is available only in debug preview mode.',
      );
    }
    return WindowsUpdateIndicatorController._developmentPreview();
  }

  factory WindowsUpdateIndicatorController.forWindows() {
    final service = WindowsUpdateService(isWindows: true);
    return WindowsUpdateIndicatorController(
      isWindows: true,
      checkForUpdates: service.checkForUpdates,
      downloadRunner: service.downloadUpdate,
      downloadCanceller: service.cancelDownload,
      onDispose: service.close,
    );
  }

  static const automaticCheckInterval = Duration(hours: 24);
  static const lastAttemptedAtKey = 'windows_update.last_attempted_at';
  static const lastSuccessfulAtKey = 'windows_update.last_successful_at';
  static const lastStatusKey = 'windows_update.last_status';
  static const lastReleaseKey = 'windows_update.last_release';
  static const pendingReleaseKey = 'windows_update.pending_release';
  static const dismissedVersionKey = 'windows_update.dismissed_version';

  final bool isWindows;
  final WindowsUpdateCheck _checkForUpdates;
  final WindowsUpdatePreferencesLoader _preferencesLoader;
  final InstalledAppVersionReader _installedVersionReader;
  final WindowsUpdateDownloadRunner? downloadRunner;
  final WindowsUpdateDownloadCanceller? downloadCanceller;
  final DateTime Function() _clock;
  final WindowsReleaseInfo? _developmentPreviewRelease;
  final VoidCallback? _onDispose;
  final StreamController<WindowsReleaseInfo> _selectionEvents =
      StreamController<WindowsReleaseInfo>.broadcast();

  WindowsUpdateIndicatorState _state = WindowsUpdateIndicatorState.checking;
  WindowsReleaseInfo? _latestAvailableRelease;
  WindowsReleaseInfo? _lastStableRelease;
  WindowsReleaseInfo? _startupPromptRelease;
  WindowsUpdateCheckResult? _latestCheckResult;
  DateTime? _lastAttemptedAt;
  DateTime? _lastSuccessfulAt;
  String? _dismissedVersion;
  WindowsUpdateDownloadState _downloadState = WindowsUpdateDownloadState.idle;
  bool _downloadPopupExpanded = true;
  WindowsUpdateProgress? _downloadProgress;
  double? _downloadSpeedBytesPerSecond;
  String? _downloadErrorMessage;
  Stopwatch? _downloadStopwatch;
  int _lastProgressBytes = 0;
  Duration _lastProgressAt = Duration.zero;
  Timer? _previewDownloadTimer;
  Timer? _previewCancelTimer;
  Future<void>? _initialization;
  Future<WindowsUpdateCheckResult?>? _activeCheck;
  bool _initialized = false;
  bool _checking = false;
  bool _startupPromptTaken = false;
  bool _hadPendingReleaseAtLaunch = false;
  bool _disposed = false;
  SharedPreferences? _preferences;

  WindowsUpdateIndicatorState get state => _state;
  WindowsReleaseInfo? get latestAvailableRelease => _latestAvailableRelease;
  WindowsReleaseInfo? get lastStableRelease => _lastStableRelease;
  WindowsUpdateCheckResult? verifiedCheckFor(WindowsReleaseInfo release) {
    final result = _latestCheckResult;
    if (result?.release?.tag != release.tag ||
        result?.release?.version.compareTo(release.version) != 0) {
      return null;
    }
    return result;
  }

  DateTime? get lastAttemptedAt => _lastAttemptedAt;
  DateTime? get lastSuccessfulAt => _lastSuccessfulAt;
  bool get isChecking => _checking;
  bool get isInitialized => _initialized;
  bool get isDevelopmentPreview => _developmentPreviewRelease != null;
  WindowsUpdateDownloadState get downloadState => _downloadState;
  bool get isDownloadPopupExpanded => _downloadPopupExpanded;
  WindowsUpdateProgress? get downloadProgress => _downloadProgress;
  double? get downloadSpeedBytesPerSecond => _downloadSpeedBytesPerSecond;
  String? get downloadErrorMessage => _downloadErrorMessage;
  bool get hasDownloadPopup =>
      _downloadState != WindowsUpdateDownloadState.idle;
  Future<String> get installedVersion => isDevelopmentPreview
      ? Future<String>.value('1.7.0')
      : _installedVersionReader();
  Future<void> get checkCompletion async {
    await _activeCheck;
  }

  Stream<WindowsReleaseInfo> get onUpdateAvailableSelected =>
      _selectionEvents.stream;

  /// Initializes from local state, then checks online only when due.
  /// Callers should not await this during application startup.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final previewRelease = _developmentPreviewRelease;
    if (previewRelease != null) {
      _latestAvailableRelease = previewRelease;
      _lastStableRelease = previewRelease;
      _state = WindowsUpdateIndicatorState.updateAvailable;
      _initialized = true;
      _notify();
      return;
    }

    if (!isWindows) {
      _initialized = true;
      _state = WindowsUpdateIndicatorState.error;
      _notify();
      return;
    }

    try {
      _preferences = await _preferencesLoader();
      final preferences = _preferences!;
      _lastAttemptedAt = _parseDate(preferences.getString(lastAttemptedAtKey));
      _lastSuccessfulAt = _parseDate(
        preferences.getString(lastSuccessfulAtKey),
      );
      _dismissedVersion = preferences.getString(dismissedVersionKey);
      _lastStableRelease = _decodeRelease(
        preferences.getString(lastReleaseKey),
      );
      _latestAvailableRelease = _decodeRelease(
        preferences.getString(pendingReleaseKey),
      );
      _hadPendingReleaseAtLaunch = _latestAvailableRelease != null;
      _startupPromptRelease = _latestAvailableRelease;

      if (_latestAvailableRelease != null) {
        _state = WindowsUpdateIndicatorState.updateAvailable;
      } else {
        _state = _stateFromStorage(preferences.getString(lastStatusKey));
      }
    } catch (_) {
      _state = WindowsUpdateIndicatorState.checking;
    }

    _initialized = true;
    _notify();

    if (_isAutomaticCheckDue()) {
      _activeCheck = _runCheck(manual: false);
      unawaited(_activeCheck);
    }
  }

  Future<WindowsUpdateCheckResult?> checkManually() {
    if (!isWindows || !_initialized || _checking || isDevelopmentPreview) {
      return Future<WindowsUpdateCheckResult?>.value();
    }
    _activeCheck = _runCheck(manual: true);
    return _activeCheck!;
  }

  Future<void> startDownload({WindowsUpdateCheckResult? check}) async {
    if (_downloadState == WindowsUpdateDownloadState.downloading ||
        _downloadState == WindowsUpdateDownloadState.cancelling) {
      return;
    }
    if (isDevelopmentPreview) {
      if (updatePreviewModeEnabled) _startPreviewDownload();
      return;
    }
    final runner = downloadRunner;
    if (check == null || !check.canDownload || runner == null) {
      _downloadState = WindowsUpdateDownloadState.failed;
      _downloadErrorMessage =
          'No se pudo iniciar la descarga verificada de esta versión.';
      _notify();
      return;
    }

    _previewDownloadTimer?.cancel();
    _previewCancelTimer?.cancel();
    _downloadState = WindowsUpdateDownloadState.downloading;
    _downloadProgress = WindowsUpdateProgress(
      downloadedBytes: 0,
      totalBytes: check.installer?.size,
    );
    _downloadSpeedBytesPerSecond = null;
    _downloadErrorMessage = null;
    _downloadStopwatch = Stopwatch()..start();
    _lastProgressBytes = 0;
    _lastProgressAt = Duration.zero;
    _notify();

    try {
      final result = await runner(check, onProgress: _acceptDownloadProgress);
      switch (result.status) {
        case WindowsUpdateOperationStatus.succeeded:
          _downloadState = WindowsUpdateDownloadState.completed;
        case WindowsUpdateOperationStatus.cancelled:
          _downloadState = WindowsUpdateDownloadState.cancelled;
        case WindowsUpdateOperationStatus.failed ||
            WindowsUpdateOperationStatus.unsupportedPlatform ||
            WindowsUpdateOperationStatus.lifecycleUnavailable:
          _downloadState = WindowsUpdateDownloadState.failed;
          _downloadErrorMessage =
              result.error?.message ?? 'No se pudo completar la descarga.';
      }
    } catch (error) {
      _downloadState = WindowsUpdateDownloadState.failed;
      _downloadErrorMessage = 'No se pudo completar la descarga: $error';
    } finally {
      _downloadStopwatch?.stop();
      _downloadStopwatch = null;
      _notify();
    }
  }

  void cancelDownload() {
    if (_downloadState != WindowsUpdateDownloadState.downloading) return;
    if (isDevelopmentPreview) {
      _previewDownloadTimer?.cancel();
      _downloadState = WindowsUpdateDownloadState.cancelling;
      _notify();
      _previewCancelTimer?.cancel();
      _previewCancelTimer = Timer(const Duration(milliseconds: 550), () {
        _previewCancelTimer = null;
        _downloadState = WindowsUpdateDownloadState.cancelled;
        _notify();
      });
      return;
    }
    _downloadState = WindowsUpdateDownloadState.cancelling;
    _downloadErrorMessage = null;
    downloadCanceller?.call();
    _notify();
  }

  void toggleDownloadPopup() {
    if (!hasDownloadPopup) return;
    _downloadPopupExpanded = !_downloadPopupExpanded;
    _notify();
  }

  void dismissDownloadPopup() {
    if (_downloadState == WindowsUpdateDownloadState.downloading ||
        _downloadState == WindowsUpdateDownloadState.cancelling) {
      return;
    }
    _downloadState = WindowsUpdateDownloadState.idle;
    _downloadProgress = null;
    _downloadSpeedBytesPerSecond = null;
    _downloadErrorMessage = null;
    _downloadPopupExpanded = true;
    _notify();
  }

  void _acceptDownloadProgress(WindowsUpdateProgress progress) {
    final stopwatch = _downloadStopwatch;
    if (stopwatch != null) {
      final now = stopwatch.elapsed;
      final elapsed = now - _lastProgressAt;
      if (_downloadProgress != null && elapsed.inMicroseconds > 0) {
        final bytes = progress.downloadedBytes - _lastProgressBytes;
        if (bytes >= 0) {
          _downloadSpeedBytesPerSecond =
              bytes * Duration.microsecondsPerSecond / elapsed.inMicroseconds;
        }
      }
      _lastProgressAt = now;
      _lastProgressBytes = progress.downloadedBytes;
    }
    _downloadProgress = progress;
    _notify();
  }

  void _startPreviewDownload() {
    _previewDownloadTimer?.cancel();
    _previewCancelTimer?.cancel();
    const totalBytes = 66500000;
    const speedBytesPerSecond = 5500000.0;
    const duration = Duration(milliseconds: 12100);
    const tick = Duration(milliseconds: 100);
    _downloadState = WindowsUpdateDownloadState.downloading;
    _downloadProgress = const WindowsUpdateProgress(
      downloadedBytes: 0,
      totalBytes: totalBytes,
    );
    _downloadSpeedBytesPerSecond = speedBytesPerSecond;
    _downloadErrorMessage = null;
    _notify();
    _previewDownloadTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      final elapsedMilliseconds = timer.tick * tick.inMilliseconds;
      final fraction = (elapsedMilliseconds / duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      final downloaded = (totalBytes * fraction).round();
      _downloadProgress = WindowsUpdateProgress(
        downloadedBytes: downloaded,
        totalBytes: totalBytes,
      );
      if (fraction >= 1) {
        timer.cancel();
        _previewDownloadTimer = null;
        _downloadState = WindowsUpdateDownloadState.completed;
      }
      _notify();
    });
  }

  Future<WindowsUpdateCheckResult?> _runCheck({required bool manual}) async {
    if (_checking || !isWindows) return null;
    if (!manual && !_isAutomaticCheckDue()) return null;

    _checking = true;
    _state = WindowsUpdateIndicatorState.checking;
    _lastAttemptedAt = _clock().toUtc();
    _notify();
    try {
      await _persistAttempt();
    } catch (_) {
      // A local storage failure must not suppress a manual or startup check.
    }

    try {
      WindowsUpdateCheckResult result;
      try {
        result = await _checkForUpdates();
      } catch (_) {
        await _applyFailure(manual: manual);
        return null;
      }

      try {
        await _applyCheckResult(result, manual: manual);
      } catch (_) {
        // A valid network result remains authoritative if local persistence fails.
      }
      return result;
    } finally {
      _checking = false;
      _notify();
    }
  }

  Future<void> _applyCheckResult(
    WindowsUpdateCheckResult result, {
    required bool manual,
  }) async {
    _latestCheckResult = result;
    final release = result.release;
    if (release != null) _lastStableRelease = release;

    if (result.updateAvailable && release != null) {
      final previousVersion = _latestAvailableRelease?.version.toString();
      _latestAvailableRelease = release;
      _state = WindowsUpdateIndicatorState.updateAvailable;
      if (previousVersion != release.version.toString()) {
        _dismissedVersion = null;
      }
      if (_hadPendingReleaseAtLaunch && !_startupPromptTaken) {
        _startupPromptRelease = release;
      }
      _lastSuccessfulAt = _clock().toUtc();
      await _persistSuccessfulRelease(release, pending: release);
      return;
    }

    final releaseIsObsolete =
        release != null &&
        result.installedVersion != null &&
        release.version.compareTo(result.installedVersion!) <= 0;
    if (result.status == WindowsUpdateStatus.upToDate || releaseIsObsolete) {
      _state = WindowsUpdateIndicatorState.upToDate;
      _latestAvailableRelease = null;
      _startupPromptRelease = null;
      _dismissedVersion = null;
      _lastSuccessfulAt = _clock().toUtc();
      await _persistUpToDate(release);
      return;
    }

    if (!manual && _latestAvailableRelease != null) {
      _state = WindowsUpdateIndicatorState.updateAvailable;
      await _persistStatus(_state);
      return;
    }
    _state = WindowsUpdateIndicatorState.error;
    await _persistStatus(_state);
  }

  Future<void> _applyFailure({required bool manual}) async {
    _latestCheckResult = null;
    if (!manual && _latestAvailableRelease != null) {
      _state = WindowsUpdateIndicatorState.updateAvailable;
    } else {
      _state = WindowsUpdateIndicatorState.error;
    }
    try {
      await _persistStatus(_state);
    } catch (_) {
      // Keep the retryable in-memory state even if preferences are unavailable.
    }
  }

  /// Emits the Phase 2B hand-off event; it intentionally does not show a dialog.
  void selectAvailableUpdate() {
    final release = _latestAvailableRelease;
    if (_state != WindowsUpdateIndicatorState.updateAvailable ||
        release == null ||
        _selectionEvents.isClosed) {
      return;
    }
    _selectionEvents.add(release);
  }

  /// Returns the previous-session update prompt at most once in this session.
  /// A release discovered for the first time now is intentionally not a startup
  /// prompt until the next application launch.
  Future<WindowsReleaseInfo?> takeStartupPrompt() async {
    await initialize();
    if (_startupPromptTaken) return null;
    _startupPromptTaken = true;

    final release = _startupPromptRelease;
    if (release == null || _dismissedVersion == release.version.toString()) {
      return null;
    }
    _notify();
    try {
      final installed = SemanticVersion.tryParse(
        await _installedVersionReader(),
      );
      if (installed != null && release.version.compareTo(installed) <= 0) {
        await _clearPendingRelease();
        _latestAvailableRelease = null;
        _startupPromptRelease = null;
        _state = WindowsUpdateIndicatorState.upToDate;
        _notify();
        return null;
      }
    } catch (_) {
      // Retain the persisted prompt if local package metadata is unavailable.
    }
    return release;
  }

  /// Records the user's future “Later” choice without clearing the update.
  Future<void> markUpdateDismissedForLater(String version) async {
    if (_latestAvailableRelease?.version.toString() != version) return;
    _dismissedVersion = version;
    await _preferencesOrLoad().then(
      (preferences) => preferences.setString(dismissedVersionKey, version),
    );
    _notify();
  }

  bool get hasPendingStartupPrompt {
    final release = _startupPromptRelease;
    return !_startupPromptTaken &&
        release != null &&
        _dismissedVersion != release.version.toString();
  }

  bool _isAutomaticCheckDue() {
    final lastAttempt = _lastAttemptedAt;
    if (lastAttempt == null) return true;
    return _clock().toUtc().difference(lastAttempt).inMicroseconds >=
        automaticCheckInterval.inMicroseconds;
  }

  Future<void> _persistAttempt() async {
    final preferences = await _preferencesOrLoad();
    await preferences.setString(
      lastAttemptedAtKey,
      _lastAttemptedAt!.toIso8601String(),
    );
  }

  Future<void> _persistSuccessfulRelease(
    WindowsReleaseInfo release, {
    required WindowsReleaseInfo pending,
  }) async {
    final preferences = await _preferencesOrLoad();
    await preferences.setString(
      lastSuccessfulAtKey,
      _clock().toUtc().toIso8601String(),
    );
    await preferences.setString(lastStatusKey, 'updateAvailable');
    await preferences.setString(
      lastReleaseKey,
      jsonEncode(_encodeRelease(release)),
    );
    await preferences.setString(
      pendingReleaseKey,
      jsonEncode(_encodeRelease(pending)),
    );
    if (_dismissedVersion == null) {
      await preferences.remove(dismissedVersionKey);
    } else {
      await preferences.setString(dismissedVersionKey, _dismissedVersion!);
    }
  }

  Future<void> _persistUpToDate(WindowsReleaseInfo? release) async {
    final preferences = await _preferencesOrLoad();
    await preferences.setString(
      lastSuccessfulAtKey,
      _clock().toUtc().toIso8601String(),
    );
    await preferences.setString(lastStatusKey, 'upToDate');
    if (release != null) {
      await preferences.setString(
        lastReleaseKey,
        jsonEncode(_encodeRelease(release)),
      );
    }
    await preferences.remove(pendingReleaseKey);
    await preferences.remove(dismissedVersionKey);
  }

  Future<void> _persistStatus(WindowsUpdateIndicatorState state) async {
    final preferences = await _preferencesOrLoad();
    await preferences.setString(lastStatusKey, state.name);
    if (_latestAvailableRelease != null) {
      await preferences.setString(
        pendingReleaseKey,
        jsonEncode(_encodeRelease(_latestAvailableRelease!)),
      );
    }
  }

  Future<void> _clearPendingRelease() async {
    final preferences = await _preferencesOrLoad();
    await preferences.remove(pendingReleaseKey);
    await preferences.remove(dismissedVersionKey);
    await preferences.setString(lastStatusKey, 'upToDate');
  }

  Future<SharedPreferences> _preferencesOrLoad() async =>
      _preferences ??= await _preferencesLoader();

  WindowsUpdateIndicatorState _stateFromStorage(String? value) =>
      switch (value) {
        'upToDate' => WindowsUpdateIndicatorState.upToDate,
        'error' => WindowsUpdateIndicatorState.error,
        _ => WindowsUpdateIndicatorState.checking,
      };

  DateTime? _parseDate(String? value) {
    if (value == null) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  WindowsReleaseInfo? _decodeRelease(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) return null;
      final version = SemanticVersion.tryParse(
        decoded['version'] as String? ?? '',
      );
      final publishedAt = DateTime.tryParse(
        decoded['publishedAt'] as String? ?? '',
      );
      final tag = decoded['tag'] as String?;
      final htmlUrl = Uri.tryParse(decoded['htmlUrl'] as String? ?? '');
      if (version == null ||
          !version.isStable ||
          publishedAt == null ||
          tag == null ||
          htmlUrl == null ||
          !htmlUrl.hasScheme) {
        return null;
      }
      final rawAssets = decoded['assets'];
      final assets = <WindowsReleaseAsset>[];
      if (rawAssets is List) {
        for (final rawAsset in rawAssets) {
          if (rawAsset is! Map<String, dynamic>) continue;
          final name = rawAsset['name'] as String?;
          final url = Uri.tryParse(rawAsset['downloadUrl'] as String? ?? '');
          final size = rawAsset['size'];
          if (name == null || url == null || !url.hasScheme || size is! int) {
            continue;
          }
          assets.add(
            WindowsReleaseAsset(
              name: name,
              downloadUrl: url,
              size: size,
              digest: rawAsset['digest'] as String?,
              id: rawAsset['id'] as int?,
            ),
          );
        }
      }
      return WindowsReleaseInfo(
        tag: tag,
        version: version,
        name: decoded['name'] as String? ?? '',
        description: decoded['description'] as String? ?? '',
        publishedAt: publishedAt.toUtc(),
        assets: List.unmodifiable(assets),
        htmlUrl: htmlUrl,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _encodeRelease(WindowsReleaseInfo release) => {
    'tag': release.tag,
    'version': release.version.toString(),
    'name': release.name,
    'description': release.description,
    'publishedAt': release.publishedAt.toUtc().toIso8601String(),
    'htmlUrl': release.htmlUrl.toString(),
    'assets': [
      for (final asset in release.assets)
        {
          'name': asset.name,
          'downloadUrl': asset.downloadUrl.toString(),
          'size': asset.size,
          if (asset.digest != null) 'digest': asset.digest,
          if (asset.id != null) 'id': asset.id,
        },
    ],
  };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _previewDownloadTimer?.cancel();
    _previewCancelTimer?.cancel();
    if (_downloadState == WindowsUpdateDownloadState.downloading ||
        _downloadState == WindowsUpdateDownloadState.cancelling) {
      downloadCanceller?.call();
    }
    _selectionEvents.close();
    _onDispose?.call();
    super.dispose();
  }
}

Future<String> _readInstalledVersion() async =>
    (await PackageInfo.fromPlatform()).version;

Future<WindowsUpdateCheckResult> _previewCheckMustNotRun() async =>
    throw StateError('The preview must never invoke an update check.');

Future<SharedPreferences> _previewPreferencesMustNotLoad() async =>
    throw StateError('The preview must never load persistent preferences.');

WindowsReleaseInfo _createDevelopmentPreviewRelease() => WindowsReleaseInfo(
  tag: 'v1.8.0',
  version: SemanticVersion.tryParse('1.8.0')!,
  name: 'SuelosAR 1.8.0',
  description: 'Correcciones, mejoras y novedades de esta versión.',
  publishedAt: DateTime.utc(2026, 11, 1),
  assets: const [],
  htmlUrl: Uri.parse(
    'https://github.com/eljerexd/suelosar/releases/tag/v1.8.0',
  ),
);
