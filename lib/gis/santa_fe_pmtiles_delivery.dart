import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/asset_paths.dart';
import 'pmtiles_delivery.dart';
import 'pmtiles_delivery_channel.dart';

/// Kept as the name this file has always used — Fase 12A extracted the
/// actual enum into the shared [PmtilesDeliveryStatus] (identical values,
/// same order) once Buenos Aires needed the same shape, so every existing
/// reference to `SantaFePmtilesStatus` keeps compiling and behaving exactly
/// as before.
typedef SantaFePmtilesStatus = PmtilesDeliveryStatus;

/// Single source of truth for Santa Fe PMTiles availability — both
/// `MultiCoverageRepository` (deciding whether to query Santa Fe's archive
/// at all) and the GIS screen's download banner read this same instance, so
/// there is exactly one state to keep in sync rather than two that could
/// drift apart.
class SantaFePmtilesDelivery extends PmtilesDelivery {
  SantaFePmtilesDelivery._();

  static final SantaFePmtilesDelivery instance = SantaFePmtilesDelivery._();

  static const String _componentName = 'santaFePmtiles';

  SantaFePmtilesStatus _status = usesOnDemandPmtilesDelivery
      ? SantaFePmtilesStatus.notInstalled
      : SantaFePmtilesStatus.available;

  @override
  SantaFePmtilesStatus get status => _status;

  /// The single field both progress getters read, so the percentage and the
  /// megabytes beside it always describe the same instant.
  PmtilesDownloadBytes? _downloadBytes;

  @override
  double? get downloadProgress => _downloadBytes?.fraction;

  @override
  PmtilesDownloadBytes? get downloadBytes => _downloadBytes;

  void _setStatus(SantaFePmtilesStatus value) {
    if (_status == value) return;
    _status = value;
    notifyListeners();
  }

  void _setDownloadBytes(PmtilesDownloadBytes? value) {
    if (_downloadBytes == value) return;
    _downloadBytes = value;
    notifyListeners();
  }

  /// How long a single install request may stay outstanding before it is
  /// treated as failed.
  ///
  /// A Play session reaches a terminal state on its own or not at all: it can
  /// sit indefinitely waiting on a confirmation this app does not surface, and
  /// nothing else would ever end the wait. Without a bound that leaves the UI
  /// on a spinner with nothing to stop it. Deliberately generous: this archive
  /// is ~63 MB, so a slow connection legitimately needs several minutes.
  static const Duration _installTimeout = Duration(minutes: 10);

  /// How hard to insist that a freshly installed module is actually readable.
  /// See [BuenosAiresPmtilesDelivery] for the full reasoning — Play reports
  /// INSTALLED when it commits the install, not when the assets resolve.
  static const int _visibilityAttempts = 6;
  static const Duration _visibilityRetryDelay = Duration(milliseconds: 350);

  /// Records that the user deleted this province while Play has not actually
  /// removed the module yet. See [BuenosAiresPmtilesDelivery] for why intent
  /// has to be tracked separately from whether the files still read.
  static const String _uninstallPendingKey =
      'pmtiles_uninstall_pending_santaFePmtiles';

  Future<bool> _isUninstallPending() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_uninstallPendingKey) ?? false;
  }

  Future<void> _setUninstallPending(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    if (value) {
      await preferences.setBool(_uninstallPendingKey, true);
    } else {
      await preferences.remove(_uninstallPendingKey);
    }
  }

  /// Whether this province's deferred component is present in the running
  /// process.
  ///
  /// Probes the tiny `.sha256` companion rather than the archive itself. Both
  /// ship in the same deferred component, so their availability is identical,
  /// but the companion is ~65 bytes against the archive's ~63 MB — the
  /// previous check loaded the entire PMTiles into memory just to answer a
  /// yes/no question, which is slow at best and an out-of-memory risk on a
  /// mid-range device. Deliberately not cached: `rootBundle.load` does not
  /// memoise failures, so this keeps returning false until the component is
  /// really installed and true from then on.
  Future<bool> _isComponentInstalled() async {
    await PmtilesDeliveryChannel.ensureAssetsVisible();
    return _probeComponent();
  }

  /// The probe itself, with no refresh attached — see [_isComponentInstalled]
  /// for what it reads and why it reads the `.sha256` and not the archive.
  Future<bool> _probeComponent() async {
    try {
      await rootBundle.load(AssetPaths.santaFeGisPmTilesVersion);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Refreshes the engine's asset handle and re-probes until the archive is
  /// really readable, or [_visibilityAttempts] have gone by. See
  /// [BuenosAiresPmtilesDelivery] for why the eviction and the ordering both
  /// matter.
  Future<bool> _ensureComponentReadable() async {
    for (var attempt = 1; attempt <= _visibilityAttempts; attempt++) {
      await PmtilesDeliveryChannel.refreshAssets();
      rootBundle.evict(AssetPaths.santaFeGisPmTilesVersion);
      rootBundle.evict(AssetPaths.santaFeGisPmTiles);
      if (await _probeComponent()) return true;
      if (attempt < _visibilityAttempts) {
        await Future<void>.delayed(_visibilityRetryDelay);
      }
    }
    return false;
  }

  /// Checks whether the component is already installed, without triggering
  /// a download. Non-Android platforms are always `available` (Windows
  /// bundles the file directly). See [BuenosAiresPmtilesDelivery.checkStatus]
  /// for why this is a no-op under [kDebugMode].
  @override
  Future<void> checkStatus() async {
    if (!usesOnDemandPmtilesDelivery) {
      _setStatus(SantaFePmtilesStatus.available);
      return;
    }
    if (kDebugMode) return;
    // An in-flight download owns the status until it finishes; a concurrent
    // poll must not overwrite it. [download] deliberately does not route
    // through here for exactly that reason — it probes directly.
    if (_status == SantaFePmtilesStatus.downloading) return;
    if (await _isComponentInstalled()) {
      // Present, but the user asked for it to go and Play has not caught up
      // yet — see [_uninstallPendingKey].
      _setStatus(
        await _isUninstallPending()
            ? SantaFePmtilesStatus.notInstalled
            : SantaFePmtilesStatus.available,
      );
      return;
    }
    // Really gone now, so there is nothing left to suppress.
    await _setUninstallPending(false);
    if (_status != SantaFePmtilesStatus.available) {
      _setStatus(SantaFePmtilesStatus.notInstalled);
    }
  }

  /// Requests the download. No-op on non-Android platforms, where the data
  /// is already bundled. See [BuenosAiresPmtilesDelivery.download] for the
  /// identical debug-simulation reasoning.
  ///
  /// Goes through [PmtilesDeliveryChannel] — this app's own Play Feature
  /// Delivery bridge — rather than Flutter's `DeferredComponent` API, which
  /// reaches Play through a manager compiled against the legacy
  /// com.google.android.play:core that Google Play rejects for targetSdk 34+.
  @override
  Future<void> download() async {
    if (!usesOnDemandPmtilesDelivery) return;
    if (_status == SantaFePmtilesStatus.downloading) return;
    if (kDebugMode) {
      await _simulateDevDownload();
      return;
    }
    // The user changed their mind before Play got round to removing it, so
    // the suppression from a previous delete has to go — otherwise the probe
    // below would succeed and still be overruled.
    await _setUninstallPending(false);
    _setDownloadBytes(null);
    _setStatus(SantaFePmtilesStatus.downloading);
    try {
      // Leaves the counters on Play's final figures (downloaded == total), so
      // the UI settles on a real 100% while the engine catches up below,
      // rather than blanking out at the last moment.
      await _runInstall();
      final readable = await _ensureComponentReadable();
      // Cleared before the status flips, deliberately: listeners act on the
      // transition into `available` (the GIS map rebuilds its whole tile
      // cache on it), and clearing afterwards would fire that a second time
      // for nothing.
      _setDownloadBytes(null);
      // Deliberately not [checkStatus], which refuses to run while the status
      // is still `downloading` — as it is here. Routing through it left the
      // status untouched and the caller then read it as a failure, so a
      // perfectly successful install could never report `available`.
      _setStatus(
        readable ? SantaFePmtilesStatus.available : SantaFePmtilesStatus.error,
      );
    } catch (_) {
      // Covers a rejected install, a cancelled session and the timeout below.
      // Either way the status leaves `downloading`, so the UI can never sit on
      // a spinner with nothing left to end it.
      _setDownloadBytes(null);
      _setStatus(SantaFePmtilesStatus.error);
    }
  }

  /// Runs one install session to a terminal state.
  ///
  /// The subscription is opened *before* the install request, not after: Play
  /// can reach a terminal state almost immediately — a module already cached
  /// on the device, or bundletool's local-testing harness, both complete in
  /// well under the round trip — and a listener attached afterwards would miss
  /// that update and then wait out the full timeout.
  ///
  /// Intermediate states (`pending`, `downloading`, `installing`, and
  /// `requiresUserConfirmation` while the user answers Play's prompt) all mean
  /// "still working"; only [PmtilesInstallStatus.isTerminal] ends the wait,
  /// and the timeout bounds everything else.
  Future<void> _runInstall() async {
    final completer = Completer<void>();
    var sessionId = -1;

    void settle(PmtilesInstallUpdate update) {
      if (completer.isCompleted) return;
      if (update.status == PmtilesInstallStatus.installed) {
        completer.complete();
      } else {
        completer.completeError(
          PmtilesInstallException(update.status.name, update.errorCode),
        );
      }
    }

    // Updates that arrive before the session id is known are matched by
    // module name instead, which is what makes the early-completion case
    // above work.
    final pending = <PmtilesInstallUpdate>[];
    final subscription = PmtilesDeliveryChannel.updates.listen(
      (update) {
        if (!update.modules.contains(_componentName)) return;
        // Play's own byte counts, passed straight through — nothing here is
        // estimated or interpolated. See [BuenosAiresPmtilesDelivery] for why
        // INSTALLED is included and the other terminal states are not.
        if (!update.status.isTerminal ||
            update.status == PmtilesInstallStatus.installed) {
          _setDownloadBytes(
            PmtilesDownloadBytes.fromCounts(
              update.bytesDownloaded,
              update.totalBytesToDownload,
            ),
          );
        }
        if (sessionId == -1) {
          pending.add(update);
          if (update.status.isTerminal) settle(update);
          return;
        }
        if (update.sessionId == sessionId && update.status.isTerminal) {
          settle(update);
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );

    try {
      sessionId = await PmtilesDeliveryChannel.install(_componentName);
      // 0 means the module was already installed and Play opened no session.
      if (sessionId == 0) return;
      for (final update in pending) {
        if (update.status.isTerminal) settle(update);
      }
      await completer.future.timeout(_installTimeout);
    } finally {
      await subscription.cancel();
    }
  }

  /// Requests removal of the installed component, freeing the device
  /// storage it occupies — Fase 11D's cartography manager is the only
  /// caller today. No-op on non-Android platforms, exactly like [download]:
  /// there, Santa Fe is always bundled and never something to uninstall.
  ///
  /// Per `DeferredComponent.uninstallDeferredComponent`'s own contract,
  /// completion of the request only means the *intent* to uninstall was
  /// registered — actual removal may happen later, and there is no
  /// callback for it finishing. [status] is set to `notInstalled`
  /// optimistically as soon as the request is sent (or immediately, in a
  /// debug build — see [_simulateDevDownload]'s doc comment for why the
  /// same real-asset-is-already-present reasoning applies here) rather
  /// than waiting on a signal that never arrives.
  @override
  Future<void> uninstall() async {
    if (!usesOnDemandPmtilesDelivery) return;
    if (_status == SantaFePmtilesStatus.downloading) return;
    if (kDebugMode) {
      _setStatus(SantaFePmtilesStatus.notInstalled);
      return;
    }
    // Recorded before Play is even asked, and deliberately not conditional on
    // Play accepting: from here on the province is deleted as far as this app
    // is concerned, whatever Play's own queue does about the files.
    await _setUninstallPending(true);
    try {
      await PmtilesDeliveryChannel.uninstall(_componentName);
    } catch (_) {
      // Best-effort: the component may already be uninstalled, or the
      // request itself can fail transiently — either way there is nothing
      // actionable to surface, and the status below reflects user intent.
    }
    _setStatus(SantaFePmtilesStatus.notInstalled);
  }

  /// Dev-only stand-in for the real Play Asset Delivery round trip, so the
  /// whole "no descargada -> descargando -> disponible" UI flow (popup,
  /// positioning, progress indicator, tiles reloading) is exercisable with
  /// just `flutter run` — the real mechanism has no local backend to talk
  /// to outside an actual Play Console upload (confirmed Fase 11B/11C).
  /// Never touches Play Core, never touches any file on disk: the Santa Fe
  /// PMTiles asset is already present in a debug build regardless (same
  /// reason [checkStatus] short-circuits above), so once this reports
  /// `available`, [MultiCoverageRepository]'s existing
  /// `PmTilesGisRepository.fromAsset` path opens the real bundled dev
  /// archive for real — nothing about the GIS/download plumbing is
  /// duplicated or special-cased for this. In-memory only, so it always
  /// resets to `notInstalled` on the next hot restart or app relaunch.
  Future<void> _simulateDevDownload() async {
    _setStatus(SantaFePmtilesStatus.downloading);
    await Future<void>.delayed(const Duration(seconds: 2));
    // Deliberately leaves the byte counters null throughout, so the debug
    // build shows an indeterminate spinner. Play is what produces those
    // numbers; inventing a plausible-looking ramp here would make a fake
    // percentage indistinguishable from a real one.
    _setStatus(SantaFePmtilesStatus.available);
  }

  /// Where Windows keeps its always-bundled copy — see the matching
  /// `install(FILES ...)` in `windows/CMakeLists.txt`, which copies the same
  /// source file to this exact relative location next to the executable on
  /// every build.
  @override
  File resolveWindowsArchiveFile() {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    return File(
      '${executableDirectory.path}${Platform.pathSeparator}data'
      '${Platform.pathSeparator}santa_fe_pmtiles'
      '${Platform.pathSeparator}santa_fe_soil_polygons.pmtiles',
    );
  }
}
