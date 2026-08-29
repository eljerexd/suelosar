import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants/asset_paths.dart';

/// Availability of Santa Fe's soil-polygon PMTiles — Fase 11B. Unlike every
/// other GIS asset, this one isn't unconditionally bundled on Android: it
/// ships as an assets-only Flutter deferred component (Play Feature/Asset
/// Delivery under the hood), downloaded on demand. Windows keeps its own
/// copy outside this mechanism entirely (see `windows/CMakeLists.txt`), so
/// on every platform other than Android this reports `available` and never
/// downloads anything.
enum SantaFePmtilesStatus { notInstalled, downloading, available, error }

/// Single source of truth for Santa Fe PMTiles availability — both
/// `MultiCoverageRepository` (deciding whether to query Santa Fe's archive
/// at all) and the GIS screen's download banner read this same instance, so
/// there is exactly one state to keep in sync rather than two that could
/// drift apart.
class SantaFePmtilesDelivery extends ChangeNotifier {
  SantaFePmtilesDelivery._();

  static final SantaFePmtilesDelivery instance = SantaFePmtilesDelivery._();

  static const String _componentName = 'santaFePmtiles';

  SantaFePmtilesStatus _status = Platform.isAndroid
      ? SantaFePmtilesStatus.notInstalled
      : SantaFePmtilesStatus.available;

  SantaFePmtilesStatus get status => _status;

  void _setStatus(SantaFePmtilesStatus value) {
    if (_status == value) return;
    _status = value;
    notifyListeners();
  }

  /// Checks whether the component is already installed, without triggering
  /// a download. Non-Android platforms are always `available` (Windows
  /// bundles the file directly; no other platform is shipped yet).
  ///
  /// Flutter's public `DeferredComponent` API (`installDeferredComponent`/
  /// `uninstallDeferredComponent`) exposes no "is it installed" query and no
  /// download-progress callback — so the only way to tell without starting
  /// a download is to probe the asset load itself: once a deferred
  /// component is installed, its assets become loadable through the exact
  /// same `rootBundle` key they'd use if they had never been deferred.
  ///
  /// In a debug build this probe would actually succeed immediately —
  /// deferred-component assets are bundled like any other asset outside a
  /// real release/profile build (confirmed Fase 11B), so `rootBundle.load`
  /// finds Santa Fe's PMTiles regardless of any real Play Asset Delivery
  /// state. Left as a no-op under [kDebugMode] so [download]'s simulation
  /// (see below) is the only thing driving [status] there — otherwise this
  /// would flip to `available` the instant it's called and the
  /// "not downloaded" UI could never be seen with a plain `flutter run`.
  Future<void> checkStatus() async {
    if (!Platform.isAndroid) {
      _setStatus(SantaFePmtilesStatus.available);
      return;
    }
    if (kDebugMode) return;
    if (_status == SantaFePmtilesStatus.downloading) return;
    try {
      await rootBundle.load(AssetPaths.santaFeGisPmTiles);
      _setStatus(SantaFePmtilesStatus.available);
    } catch (_) {
      if (_status != SantaFePmtilesStatus.available) {
        _setStatus(SantaFePmtilesStatus.notInstalled);
      }
    }
  }

  /// Requests the download. No-op on non-Android platforms, where the data
  /// is already bundled. Writes straight to disk via Play's own delivery
  /// mechanism — this never loads the archive into memory. In a debug
  /// build, simulates the same status timeline instead (see
  /// [_simulateDevDownload]) — production and `flutter build appbundle`
  /// are completely unaffected, since [kDebugMode] is false there.
  Future<void> download() async {
    if (!Platform.isAndroid) return;
    if (_status == SantaFePmtilesStatus.downloading) return;
    if (kDebugMode) {
      await _simulateDevDownload();
      return;
    }
    _setStatus(SantaFePmtilesStatus.downloading);
    try {
      await DeferredComponent.installDeferredComponent(
        componentName: _componentName,
      );
      await checkStatus();
      if (_status != SantaFePmtilesStatus.available) {
        _setStatus(SantaFePmtilesStatus.error);
      }
    } catch (_) {
      _setStatus(SantaFePmtilesStatus.error);
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
  Future<void> uninstall() async {
    if (!Platform.isAndroid) return;
    if (_status == SantaFePmtilesStatus.downloading) return;
    if (kDebugMode) {
      _setStatus(SantaFePmtilesStatus.notInstalled);
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
    _setStatus(SantaFePmtilesStatus.available);
  }

  /// Where Windows keeps its always-bundled copy — see the matching
  /// `install(FILES ...)` in `windows/CMakeLists.txt`, which copies the same
  /// source file to this exact relative location next to the executable on
  /// every build.
  static File resolveWindowsArchiveFile() {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    return File(
      '${executableDirectory.path}${Platform.pathSeparator}data'
      '${Platform.pathSeparator}santa_fe_pmtiles'
      '${Platform.pathSeparator}santa_fe_soil_polygons.pmtiles',
    );
  }
}
