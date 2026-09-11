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

/// Play's own byte counters for an in-flight download, exactly as reported.
///
/// Only ever constructed when Play has given a real total (see
/// [fromCounts]) — there is no such thing as an estimated instance. Both the
/// fraction and the rendered label come from these two numbers, so a screen
/// cannot show a percentage that disagrees with the megabytes beside it, and
/// the two screens cannot disagree with each other.
@immutable
class PmtilesDownloadBytes {
  const PmtilesDownloadBytes({required this.downloaded, required this.total});

  /// Null when Play has not reported a usable total — the first updates of a
  /// session carry zeroes. Null is the instruction to stay indeterminate:
  /// no percentage, no megabytes, just a spinner.
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

  /// `106.4 MB / 158.6 MB`. Rendered here rather than at each call site so
  /// the GIS download card and the provincial maps manager are literally
  /// showing the same string. MiB, matching every other size in the app.
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

  /// How far the current download has got, in 0..1, or null when there is
  /// nothing meaningful to show — no download running, or Play has not
  /// reported a total yet (its first updates of a session carry zeroes).
  ///
  /// Null is the instruction to stay indeterminate. Callers must not
  /// substitute a guess for it: a fabricated percentage is worse than an
  /// honest spinner. Every surface that shows progress reads it from this
  /// one object, so the map banner and the provincial maps manager cannot
  /// disagree about what percentage the same download is at.
  double? get downloadProgress;

  /// The byte counts [downloadProgress] is derived from, for surfaces that
  /// also show them. Non-null exactly when [downloadProgress] is, because
  /// both read the same field.
  PmtilesDownloadBytes? get downloadBytes;

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
