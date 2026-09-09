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
    if (_status == PmtilesDeliveryStatus.downloading) return;
    try {
      await rootBundle.load(AssetPaths.gisPmTiles);
      _setStatus(PmtilesDeliveryStatus.available);
    } catch (_) {
      if (_status != PmtilesDeliveryStatus.available) {
        _setStatus(PmtilesDeliveryStatus.notInstalled);
      }
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
      );
      await checkStatus();
      if (_status != PmtilesDeliveryStatus.available) {
        _setStatus(PmtilesDeliveryStatus.error);
      }
    } catch (_) {
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
