import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

bool get usesOnDemandPmtilesDelivery => usesOnDemandPmtilesDeliveryFor(
  isAndroid: Platform.isAndroid,
  flavor: appFlavor,
);

@visibleForTesting
bool usesOnDemandPmtilesDeliveryFor({
  required bool isAndroid,
  required String? flavor,
}) => isAndroid && flavor != 'web';

/// Availability of an on-demand provincial PMTiles archive — shared shape
/// for every province delivered this way (Santa Fe, Buenos Aires). Unlike
/// most other GIS assets, these aren't unconditionally bundled on Android:
/// each ships as its own assets-only Flutter deferred component (Play
/// Feature/Asset Delivery under the hood), downloaded on demand. Windows
/// keeps its own copy of every province outside this mechanism entirely
/// (see `windows/CMakeLists.txt`), so on every platform other than Android
/// this reports `available` and never downloads anything.
enum PmtilesDeliveryStatus { notInstalled, downloading, available, error }

@immutable
class PmtilesDownloadBytes {
  const PmtilesDownloadBytes({required this.downloaded, required this.total});

  static PmtilesDownloadBytes? fromCounts(int downloaded, int total) {
    if (total <= 0) return null;
    return PmtilesDownloadBytes(
      downloaded: downloaded.clamp(0, total),
      total: total,
    );
  }

  final int downloaded;
  final int total;

  double get fraction => downloaded / total;
  int get percent => (fraction * 100).round();
  String get label => '${_megabytes(downloaded)} / ${_megabytes(total)}';

  static String _megabytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  bool operator ==(Object other) =>
      other is PmtilesDownloadBytes &&
      other.downloaded == downloaded &&
      other.total == total;

  @override
  int get hashCode => Object.hash(downloaded, total);
}

/// Lets Android Debug sessions exercise the real deferred PMTiles assets
/// bundled by Flutter for development, without changing the normal simulated
/// download flow or any Release behavior.
const bool useLocalPmtilesAssetsInDebug = bool.fromEnvironment(
  'SUelosAR_DEBUG_LOCAL_PMTILES',
  defaultValue: false,
);

/// Common contract for a province's on-demand PMTiles delivery object — one
/// singleton per province (e.g. [SantaFePmtilesDelivery.instance],
/// [BuenosAiresPmtilesDelivery.instance]), each a [ChangeNotifier] so
/// `MultiCoverageRepository`'s availability check and the GIS screen's
/// download banner/settings-screen card can all read the exact same live
/// state instead of drifting apart.
///
/// Extracted from Santa Fe's original implementation (Fase 11B) once Buenos
/// Aires needed the identical mechanism (Fase 12A), so the widget/screen
/// code that drives the download banner and the provincial maps manager can
/// be written once against this interface instead of once per province.
abstract class PmtilesDelivery extends ChangeNotifier {
  int _statusCheckRevision = 0;

  PmtilesDeliveryStatus get status;
  double? get downloadProgress => null;
  PmtilesDownloadBytes? get downloadBytes => null;

  /// Checks whether the component is already installed, without triggering
  /// a download.
  Future<void> checkStatus();

  /// Invalidates a pending installed-state probe when a newer user operation
  /// takes ownership of this delivery's state.
  @protected
  void invalidateStatusChecks() => _statusCheckRevision++;

  /// Starts a fresh probe and makes every older pending probe obsolete.
  @protected
  int beginStatusCheck() => ++_statusCheckRevision;

  @protected
  bool isStatusCheckCurrent(int revision) => revision == _statusCheckRevision;

  @protected
  Future<void> reconcileInstalledModule({
    required Future<bool> Function() isComponentInstalled,
    required Future<bool> Function() isUninstallPending,
    required Future<void> Function() clearUninstallPending,
    required ValueChanged<PmtilesDeliveryStatus> setStatus,
  }) async {
    final revision = beginStatusCheck();
    final installed = await isComponentInstalled();
    if (!isStatusCheckCurrent(revision) ||
        status == PmtilesDeliveryStatus.downloading) {
      return;
    }

    if (installed) {
      final uninstallPending = await isUninstallPending();
      if (!isStatusCheckCurrent(revision) ||
          status == PmtilesDeliveryStatus.downloading) {
        return;
      }
      setStatus(
        uninstallPending
            ? PmtilesDeliveryStatus.notInstalled
            : PmtilesDeliveryStatus.available,
      );
      return;
    }

    await clearUninstallPending();
    if (isStatusCheckCurrent(revision) &&
        status != PmtilesDeliveryStatus.downloading) {
      setStatus(PmtilesDeliveryStatus.notInstalled);
    }
  }

  /// Requests the download (a no-op on non-Android platforms, where the
  /// data is already bundled).
  Future<void> download();

  /// Requests removal of the installed component, freeing the device
  /// storage it occupies (a no-op on non-Android platforms).
  Future<void> uninstall();

  /// Where Windows keeps its always-bundled copy of this province's
  /// archive — see the matching `install(FILES ...)` in
  /// `windows/CMakeLists.txt`.
  File resolveWindowsArchiveFile();
}

Future<void> simulateDevelopmentPmtilesDownload({
  required int totalBytes,
  required ValueChanged<PmtilesDeliveryStatus> setStatus,
  required ValueChanged<PmtilesDownloadBytes?> setDownloadBytes,
  Duration stepDelay = const Duration(milliseconds: 400),
}) async {
  if (totalBytes <= 0) {
    throw ArgumentError.value(totalBytes, 'totalBytes', 'must be positive');
  }
  setDownloadBytes(null);
  setStatus(PmtilesDeliveryStatus.downloading);
  for (final percent in [20, 40, 60, 80, 100]) {
    await Future<void>.delayed(stepDelay);
    setDownloadBytes(
      PmtilesDownloadBytes.fromCounts(totalBytes * percent ~/ 100, totalBytes),
    );
  }
  setDownloadBytes(null);
  setStatus(PmtilesDeliveryStatus.available);
}
