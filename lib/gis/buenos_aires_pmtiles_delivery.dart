import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/asset_paths.dart';
import 'pmtiles_delivery.dart';
import 'pmtiles_delivery_channel.dart';

/// Single source of truth for Buenos Aires PMTiles availability — Fase 12A,
/// following exactly the same pattern already validated for Santa Fe (Fase
/// 11B): both `MultiCoverageRepository` (deciding whether to query Buenos
/// Aires' archive at all) and the GIS screen's download banner/settings
/// screen card read this same instance, so there is exactly one state to
/// keep in sync rather than two that could drift apart. See
/// [SantaFePmtilesDelivery] for the identical, previously-validated
/// implementation this mirrors; the two share their status enum and
/// interface via [PmtilesDelivery]/[PmtilesDeliveryStatus] rather than any
/// code being duplicated at the type level, but each keeps its own
/// singleton instance and component name.
class BuenosAiresPmtilesDelivery extends PmtilesDelivery {
  BuenosAiresPmtilesDelivery._();

  static final BuenosAiresPmtilesDelivery instance =
      BuenosAiresPmtilesDelivery._();

  static const String _componentName = 'buenosAiresPmtiles';

  PmtilesDeliveryStatus _status = usesOnDemandPmtilesDelivery
      ? PmtilesDeliveryStatus.notInstalled
      : PmtilesDeliveryStatus.available;

  @override
  PmtilesDeliveryStatus get status => _status;

  /// The single field both progress getters read, so the percentage and the
  /// megabytes beside it always describe the same instant.
  PmtilesDownloadBytes? _downloadBytes;

  @override
  double? get downloadProgress => _downloadBytes?.fraction;

  @override
  PmtilesDownloadBytes? get downloadBytes => _downloadBytes;

  void _setStatus(PmtilesDeliveryStatus value) {
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
  /// is ~151 MB, so a slow connection legitimately needs several minutes.
  static const Duration _installTimeout = Duration(minutes: 10);

  /// How hard to insist that a freshly installed module is actually readable.
  ///
  /// Play reports INSTALLED once it has committed the install, which is not
  /// necessarily the instant the assets resolve — the engine's asset handle
  /// has to be replaced first, and on a real device that can lag the callback
  /// slightly. Bounded on purpose: roughly two seconds of trying, then the
  /// download is reported as failed and the user gets the retry action, which
  /// is far better than a spinner that never ends.
  static const int _visibilityAttempts = 6;
  static const Duration _visibilityRetryDelay = Duration(milliseconds: 350);

  /// Records that the user has deleted this province while Play has not
  /// actually removed the module yet.
  ///
  /// `deferredUninstall` is deferred by design: Play accepts the request and
  /// frees the space at some idle moment of its own choosing, which can be
  /// minutes or hours away. Until then the module is still installed and its
  /// assets still read perfectly — so the probe in [checkStatus] would answer
  /// "installed", overwrite the deletion, and put the province back on the
  /// map. That is the whole "I deleted it and it is still there, then it
  /// disappears on its own later" behaviour: nothing was stale, the probe was
  /// simply answering a different question from the one being asked.
  ///
  /// So intent is recorded separately from presence, and outlives the process
  /// because Play's removal does too.
  static const String _uninstallPendingKey =
      'pmtiles_uninstall_pending_buenosAiresPmtiles';

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
  /// but the companion is ~65 bytes against the archive's ~151 MB — the
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
      await rootBundle.load(AssetPaths.gisPmTilesVersion);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Refreshes the engine's asset handle and re-probes until the archive is
  /// really readable, or [_visibilityAttempts] have gone by.
  ///
  /// Each attempt is refresh-then-probe in that order: probing first would
  /// just re-read the stale handle. [rootBundle] is evicted in between
  /// because it memoises futures per key — including failed ones — so a probe
  /// from before the download would otherwise keep answering for the rest of
  /// the process, which is exactly what made the province need an app restart
  /// even once its files were in place.
  Future<bool> _ensureComponentReadable() async {
    for (var attempt = 1; attempt <= _visibilityAttempts; attempt++) {
      await PmtilesDeliveryChannel.refreshAssets();
      rootBundle.evict(AssetPaths.gisPmTilesVersion);
      rootBundle.evict(AssetPaths.gisPmTiles);
      if (await _probeComponent()) return true;
      if (attempt < _visibilityAttempts) {
        await Future<void>.delayed(_visibilityRetryDelay);
      }
    }
    return false;
  }

  /// Checks whether the component is already installed, without triggering
  /// a download. Non-Android platforms are always `available` (Windows
  /// bundles the file directly). See [SantaFePmtilesDelivery.checkStatus]
  /// for why this is a no-op under [kDebugMode].
  @override
  Future<void> checkStatus() async {
    if (!usesOnDemandPmtilesDelivery) {
      _setStatus(PmtilesDeliveryStatus.available);
      return;
    }
    if (kDebugMode) return;
    // An in-flight download owns the status until it finishes; a concurrent
    // poll must not overwrite it. [download] deliberately does not route
    // through here for exactly that reason — it probes directly.
    if (_status == PmtilesDeliveryStatus.downloading) return;
    if (await _isComponentInstalled()) {
      // Present, but the user asked for it to go and Play has not caught up
      // yet — see [_uninstallPendingKey]. Deleted is what the user decided;
      // still-readable is only where Play's queue happens to be.
      _setStatus(
        await _isUninstallPending()
            ? PmtilesDeliveryStatus.notInstalled
            : PmtilesDeliveryStatus.available,
      );
      return;
    }
    // Really gone now, so there is nothing left to suppress.
    await _setUninstallPending(false);
    if (_status != PmtilesDeliveryStatus.available) {
      _setStatus(PmtilesDeliveryStatus.notInstalled);
    }
  }

  /// Requests the download. No-op on non-Android platforms, where the data
  /// is already bundled. See [SantaFePmtilesDelivery.download] for the
  /// identical debug-simulation reasoning.
  ///
  /// Goes through [PmtilesDeliveryChannel] — this app's own Play Feature
  /// Delivery bridge — rather than Flutter's `DeferredComponent` API, which
  /// reaches Play through a manager compiled against the legacy
  /// com.google.android.play:core that Google Play rejects for targetSdk 34+.
  @override
  Future<void> download() async {
    if (!usesOnDemandPmtilesDelivery) return;
    if (_status == PmtilesDeliveryStatus.downloading) return;
    if (kDebugMode) {
      await _simulateDevDownload();
      return;
    }
    // The user changed their mind before Play got round to removing it, so
    // the suppression from a previous delete has to go — otherwise the probe
    // below would succeed and still be overruled.
    await _setUninstallPending(false);
    _setDownloadBytes(null);
    _setStatus(PmtilesDeliveryStatus.downloading);
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
        readable
            ? PmtilesDeliveryStatus.available
            : PmtilesDeliveryStatus.error,
      );
    } catch (_) {
      // Covers a rejected install, a cancelled session and the timeout below.
      // Either way the status leaves `downloading`, so the UI can never sit on
      // a spinner with nothing left to end it.
      _setDownloadBytes(null);
      _setStatus(PmtilesDeliveryStatus.error);
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
        // estimated or interpolated, and the UI moves exactly when Play says
        // something moved. Null until it reports a total, which keeps the UI
        // indeterminate rather than showing a percentage of an unknown.
        // INSTALLED is included so the counters settle on the real final
        // figures; the other terminal states are failures with nothing worth
        // reporting.
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
  /// storage it occupies. No-op on non-Android platforms, exactly like
  /// [download]: there, Buenos Aires is always bundled and never something
  /// to uninstall. See [SantaFePmtilesDelivery.uninstall] for why [status]
  /// is set optimistically rather than waiting on a completion signal that
  /// never arrives.
  @override
  Future<void> uninstall() async {
    if (!usesOnDemandPmtilesDelivery) return;
    if (_status == PmtilesDeliveryStatus.downloading) return;
    if (kDebugMode) {
      _setStatus(PmtilesDeliveryStatus.notInstalled);
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
    _setStatus(PmtilesDeliveryStatus.notInstalled);
  }

  /// Dev-only stand-in for the real Play Asset Delivery round trip — see
  /// [SantaFePmtilesDelivery._simulateDevDownload] for the full reasoning,
  /// identical here: never touches Play Core or disk, always resets to
  /// `notInstalled` on the next hot restart or app relaunch.
  Future<void> _simulateDevDownload() async {
    _setStatus(PmtilesDeliveryStatus.downloading);
    await Future<void>.delayed(const Duration(seconds: 2));
    // Deliberately leaves the byte counters null throughout, so the debug
    // build shows an indeterminate spinner. Play is what produces those
    // numbers; inventing a plausible-looking ramp here would make a fake
    // percentage indistinguishable from a real one.
    _setStatus(PmtilesDeliveryStatus.available);
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
      '${Platform.pathSeparator}buenos_aires_pmtiles'
      '${Platform.pathSeparator}soil_polygons.pmtiles',
    );
  }
}
