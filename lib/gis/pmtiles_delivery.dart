import 'dart:io';

import 'package:flutter/foundation.dart';

/// Availability of an on-demand provincial PMTiles archive — shared shape
/// for every province delivered this way (Santa Fe, Buenos Aires). Unlike
/// most other GIS assets, these aren't unconditionally bundled on Android:
/// each ships as its own assets-only Flutter deferred component (Play
/// Feature/Asset Delivery under the hood), downloaded on demand. Windows
/// keeps its own copy of every province outside this mechanism entirely
/// (see `windows/CMakeLists.txt`), so on every platform other than Android
/// this reports `available` and never downloads anything.
enum PmtilesDeliveryStatus { notInstalled, downloading, available, error }

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
  PmtilesDeliveryStatus get status;

  /// Checks whether the component is already installed, without triggering
  /// a download.
  Future<void> checkStatus();

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
