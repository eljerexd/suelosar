import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants/asset_paths.dart';
import 'pmtiles_delivery.dart';

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

  PmtilesDeliveryStatus _status = Platform.isAndroid
      ? PmtilesDeliveryStatus.notInstalled
      : PmtilesDeliveryStatus.available;

  @override
  PmtilesDeliveryStatus get status => _status;

  void _setStatus(PmtilesDeliveryStatus value) {
    if (_status == value) return;
    _status = value;
    notifyListeners();
  }
  /// How long a single install request may stay outstanding before it is
  /// treated as failed.
  ///
  /// [DeferredComponent.installDeferredComponent]'s future resolves only when
  /// Play finishes the whole install, and it never resolves at all if the
  /// session stalls — for example when Play is waiting on a confirmation this
  /// app does not surface. Without a bound, that leaves the UI on a spinner
  /// with nothing to end it. Deliberately generous: this archive is ~151 MB,
  /// so a slow connection legitimately needs several minutes.
  static const Duration _installTimeout = Duration(minutes: 10);

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
    try {
      await rootBundle.load(AssetPaths.gisPmTilesVersion);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Checks whether the component is already installed, without triggering
  /// a download. Non-Android platforms are always `available` (Windows
  /// bundles the file directly). See [SantaFePmtilesDelivery.checkStatus]
  /// for why this is a no-op under [kDebugMode].
  @override
  Future<void> checkStatus() async {
    if (!Platform.isAndroid) {
      _setStatus(PmtilesDeliveryStatus.available);
      return;
    }
    if (kDebugMode) return;
    // An in-flight download owns the status until it finishes; a concurrent
    // poll must not overwrite it. [download] deliberately does not route
    // through here for exactly that reason — it probes directly.
    if (_status == PmtilesDeliveryStatus.downloading) return;
    if (await _isComponentInstalled()) {
      _setStatus(PmtilesDeliveryStatus.available);
    } else if (_status != PmtilesDeliveryStatus.available) {
      _setStatus(PmtilesDeliveryStatus.notInstalled);
    }
  }

  /// Requests the download. No-op on non-Android platforms, where the data
  /// is already bundled. See [SantaFePmtilesDelivery.download] for the
  /// identical debug-simulation reasoning.
  @override
  Future<void> download() async {
    if (!Platform.isAndroid) return;
    if (_status == PmtilesDeliveryStatus.downloading) return;
    if (kDebugMode) {
      await _simulateDevDownload();
      return;
    }
    _setStatus(PmtilesDeliveryStatus.downloading);
    try {
      await DeferredComponent.installDeferredComponent(
        componentName: _componentName,
      ).timeout(_installTimeout);
      // Probed directly rather than through [checkStatus], which refuses to
      // run while the status is still `downloading` — as it is here. Routing
      // through it left the status untouched and the caller then read it as
      // a failure, so a perfectly successful install could never report
      // `available`.
      _setStatus(
        await _isComponentInstalled()
            ? PmtilesDeliveryStatus.available
            : PmtilesDeliveryStatus.error,
      );
    } catch (_) {
      // Covers both a rejected install and the timeout above. Either way the
      // status leaves `downloading`, so the UI can never sit on a spinner
      // with nothing left to end it.
      _setStatus(PmtilesDeliveryStatus.error);
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
    if (!Platform.isAndroid) return;
    if (_status == PmtilesDeliveryStatus.downloading) return;
    if (kDebugMode) {
      _setStatus(PmtilesDeliveryStatus.notInstalled);
      return;
    }
    try {
      await DeferredComponent.uninstallDeferredComponent(
        componentName: _componentName,
      );
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
