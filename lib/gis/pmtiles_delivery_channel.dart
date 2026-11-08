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
  static final Stream<PmtilesInstallUpdate> _updates = _events
      .receiveBroadcastStream()
      .map(
        (event) =>
            PmtilesInstallUpdate._fromMap(event as Map<Object?, Object?>),
      );
  static Future<void> _installQueue = Future<void>.value();
  static final Map<String, Future<void>> _moduleInstalls = {};

  /// Session updates for every module, straight from
  /// `SplitInstallStateUpdatedListener`. This must stay one shared stream:
  /// each call to `receiveBroadcastStream()` installs a platform handler for
  /// the same channel name, while the native bridge owns a single EventSink.
  /// Callers subscribe here and filter by module/session without replacing
  /// each other's native listener.
  static Stream<PmtilesInstallUpdate> get updates => _updates;

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

  /// Starts one module install and waits for the matching Play session to
  /// reach a terminal state. Multiple modules can observe the shared event
  /// stream concurrently; every update is matched against both module and the
  /// session id returned by `startInstall`.
  static Future<void> installAndWait({
    required String module,
    required void Function(PmtilesInstallUpdate update) onUpdate,
    required Duration timeout,
  }) {
    final existing = _moduleInstalls[module];
    if (existing != null) return existing;

    final previous = _installQueue;
    final releaseQueue = Completer<void>();
    _installQueue = releaseQueue.future;
    final request = () async {
      await previous;
      try {
        await _installAndWaitNow(
          module: module,
          onUpdate: onUpdate,
          timeout: timeout,
        );
      } finally {
        releaseQueue.complete();
      }
    }();
    _moduleInstalls[module] = request;
    unawaited(
      request.then<void>(
        (_) => _clearModuleInstall(module, request),
        onError: (Object _, StackTrace _) =>
            _clearModuleInstall(module, request),
      ),
    );
    return request;
  }

  static void _clearModuleInstall(String module, Future<void> request) {
    if (identical(_moduleInstalls[module], request)) {
      _moduleInstalls.remove(module);
    }
  }

  static Future<void> _installAndWaitNow({
    required String module,
    required void Function(PmtilesInstallUpdate update) onUpdate,
    required Duration timeout,
  }) async {
    final completed = Completer<void>();
    int? sessionId;
    final pending = <PmtilesInstallUpdate>[];
    Object? pendingStreamError;
    StackTrace? pendingStreamStack;

    void process(PmtilesInstallUpdate update) {
      final serviceDied =
          update.sessionId == -1 &&
          update.status == PmtilesInstallStatus.failed;
      if (completed.isCompleted ||
          (!serviceDied && update.sessionId != sessionId)) {
        return;
      }
      try {
        onUpdate(update);
      } catch (error, stackTrace) {
        completed.completeError(error, stackTrace);
        return;
      }
      if (!update.status.isTerminal) return;
      if (update.status == PmtilesInstallStatus.installed) {
        completed.complete();
      } else {
        completed.completeError(
          PmtilesInstallException(update.status.name, update.errorCode),
        );
      }
    }

    final subscription = updates.listen(
      (update) {
        final serviceDied =
            update.sessionId == -1 &&
            update.status == PmtilesInstallStatus.failed;
        if (!serviceDied && !update.modules.contains(module)) return;
        final activeSessionId = sessionId;
        if (activeSessionId == null) {
          pending.add(update);
        } else if (serviceDied || update.sessionId == activeSessionId) {
          process(update);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (sessionId == null) {
          pendingStreamError = error;
          pendingStreamStack = stackTrace;
        } else if (!completed.isCompleted) {
          completed.completeError(error, stackTrace);
        }
      },
    );

    try {
      sessionId = await install(module);
      // Zero means Play found the module already installed and opened no
      // session, so no event can be required to complete this request.
      if (sessionId == 0) return;
      if (pendingStreamError != null && !completed.isCompleted) {
        completed.completeError(
          pendingStreamError!,
          pendingStreamStack ?? StackTrace.current,
        );
      }
      for (final update in pending) {
        if (update.sessionId == sessionId ||
            (update.sessionId == -1 &&
                update.status == PmtilesInstallStatus.failed)) {
          process(update);
        }
      }
      await completed.future.timeout(timeout);
    } finally {
      await subscription.cancel();
    }
  }

  /// Requests removal of [module]. Play defers the actual deletion to an idle
  /// moment, so this resolving means the request was accepted, not that the
  /// files are already gone.
  static Future<void> uninstall(String module) async {
    try {
      await _methods.invokeMethod<bool>('uninstall', {'module': module});
    } on PlatformException catch (error) {
      throw PmtilesInstallException(error.message ?? 'uninstall failed', null);
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
