import 'dart:async';

import 'package:flutter/services.dart';

/// Where a Play Feature Delivery session currently is, mirrored one-to-one
/// from `SplitInstallSessionStatus` by the Android bridge.
enum PmtilesInstallStatus {
  pending,
  requiresUserConfirmation,
  downloading,
  downloaded,
  installing,
  installed,
  failed,
  canceling,
  canceled,
  unknown;

  /// Whether the session has reached a state it will not move on from by
  /// itself. Anything else means Play is still working and the caller should
  /// keep waiting.
  bool get isTerminal =>
      this == installed ||
      this == failed ||
      this == canceled ||
      this == unknown;
}

/// One update about an in-flight install, as reported by Play.
class PmtilesInstallUpdate {
  const PmtilesInstallUpdate({
    required this.sessionId,
    required this.status,
    required this.errorCode,
    required this.bytesDownloaded,
    required this.totalBytesToDownload,
    required this.modules,
  });

  factory PmtilesInstallUpdate._fromMap(Map<Object?, Object?> map) {
    return PmtilesInstallUpdate(
      sessionId: (map['sessionId'] as num?)?.toInt() ?? -1,
      status: PmtilesInstallStatus.values.firstWhere(
        (value) => value.name == map['status'],
        orElse: () => PmtilesInstallStatus.unknown,
      ),
      errorCode: (map['errorCode'] as num?)?.toInt() ?? 0,
      bytesDownloaded: (map['bytesDownloaded'] as num?)?.toInt() ?? 0,
      totalBytesToDownload: (map['totalBytesToDownload'] as num?)?.toInt() ?? 0,
      modules: <String>[
        for (final module in (map['modules'] as List<Object?>? ?? const []))
          if (module != null) module.toString(),
      ],
    );
  }

  final int sessionId;
  final PmtilesInstallStatus status;
  final int errorCode;
  final int bytesDownloaded;
  final int totalBytesToDownload;
  final List<String> modules;

  /// Download progress in 0..1, or null before Play reports a total — the
  /// first updates of a session usually carry zeroes.
  double? get progress => totalBytesToDownload <= 0
      ? null
      : (bytesDownloaded / totalBytesToDownload).clamp(0.0, 1.0);
}

/// Thrown when Play refuses to start or finish an install. [code] is Play's
/// own `SplitInstallErrorCode` when it provided one.
class PmtilesInstallException implements Exception {
  const PmtilesInstallException(this.message, this.code);

  final String message;
  final int? code;

  @override
  String toString() =>
      'PmtilesInstallException($message${code == null ? '' : ', code $code'})';
}

/// Dart side of the Play Feature Delivery bridge in
/// `android/app/src/main/kotlin/ar/com/suelosar/PmtilesDeliveryBridge.kt`.
///
/// Replaces Flutter's own `DeferredComponent` API, which reaches Play through
/// a manager compiled against the legacy com.google.android.play:core —
/// rejected by Google Play for targetSdk 34+. This channel talks to the modern
/// feature-delivery library instead. It is Android-only; every caller already
/// gates on `Platform.isAndroid` because other platforms bundle the archives
/// outright.
abstract final class PmtilesDeliveryChannel {
  static const MethodChannel _methods = MethodChannel(
    'ar.com.suelosar/pmtiles_delivery',
  );
  static const EventChannel _events = EventChannel(
    'ar.com.suelosar/pmtiles_delivery/events',
  );

  /// Session updates for every module, straight from
  /// `SplitInstallStateUpdatedListener`. Callers filter by module name.
  static Stream<PmtilesInstallUpdate> get updates => _events
      .receiveBroadcastStream()
      .map(
        (event) => PmtilesInstallUpdate._fromMap(event as Map<Object?, Object?>),
      );

  static Future<void>? _assetsVisible;

  /// Makes the assets of modules installed in an *earlier* session readable
  /// through `rootBundle`, and does it once per process.
  ///
  /// A module installed while the app is running is handled on the Android
  /// side, as part of the install. A module that was already there at launch
  /// is not: the engine takes its asset handle when it executes the Dart
  /// entrypoint, which is after every hook the Android side could use, so the
  /// request has to come from here — before the first `rootBundle` read of a
  /// province archive, or that read fails and the province looks uninstalled.
  ///
  /// Failures are swallowed deliberately. The worst case is the state the
  /// caller was already in, and turning a launch-time refresh into an error
  /// would only hide the real answer, which is whatever the probe that
  /// follows finds.
  static Future<void> ensureAssetsVisible() {
    return _assetsVisible ??= refreshAssets();
  }

  /// Re-points the engine at an AssetManager that includes everything Play
  /// has installed, unconditionally.
  ///
  /// [ensureAssetsVisible] answers the launch-time question once and caches
  /// it; this is the one to call after an install, where the whole point is
  /// that the answer has just changed. Returns whether the Android side
  /// managed it — false means the caller should retry rather than conclude
  /// the module is missing.
  static Future<bool> refreshAssets() async {
    try {
      return await _methods.invokeMethod<bool>('refreshAssets') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether Play reports [module] as installed right now.
  static Future<bool> isInstalled(String module) async {
    final installed = await _methods.invokeMethod<bool>('isInstalled', {
      'module': module,
    });
    return installed ?? false;
  }

  /// Asks Play to install [module], returning the session id. Resolving only
  /// means the request was accepted — completion arrives on [updates].
  /// Returns 0 when the module was already installed and no session was
  /// opened.
  static Future<int> install(String module) async {
    try {
      final sessionId = await _methods.invokeMethod<int>('install', {
        'module': module,
      });
      return sessionId ?? 0;
    } on PlatformException catch (error) {
      throw PmtilesInstallException(
        error.message ?? 'install failed',
        error.details is int ? error.details as int : null,
      );
    }
  }

  /// Requests removal of [module]. Play defers the actual deletion to an idle
  /// moment, so this resolving means the request was accepted, not that the
  /// files are already gone.
  static Future<void> uninstall(String module) async {
    try {
      await _methods.invokeMethod<bool>('uninstall', {'module': module});
    } on PlatformException catch (error) {
      throw PmtilesInstallException(
        error.message ?? 'uninstall failed',
        null,
      );
    }
  }

  /// Cancels an in-flight session. Returns false when Play would not cancel
  /// it, which happens once the session is past the point of no return.
  static Future<bool> cancel(int sessionId) async {
    final cancelled = await _methods.invokeMethod<bool>('cancel', {
      'sessionId': sessionId,
    });
    return cancelled ?? false;
  }
}
