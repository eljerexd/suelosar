import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// TEMPORARY — instrumentation for the real-Play investigation of province
/// PMTiles that install successfully and still do not render.
///
/// Remove this file, and every `PmtilesDiagnostics.log` call, once the root
/// cause is known. It exists only to answer questions that cannot be answered
/// on a development machine: bundletool's `--local-testing` harness drives
/// FakeSplitInstallManager, a different code path from the one Google Play
/// actually uses, and every one of these flows already passes there.
///
/// Routed through the Android bridge rather than `debugPrint` so that Dart and
/// native diagnostics land in logcat under one tag (`SuelosArDiag`) and can be
/// filtered with a single `adb logcat -s SuelosArDiag`. Deliberately
/// fire-and-forget and failure-swallowing: diagnostics must never change the
/// behaviour being diagnosed.
abstract final class PmtilesDiagnostics {
  static const MethodChannel _channel = MethodChannel(
    'ar.com.suelosar/pmtiles_delivery',
  );

  static void log(String message) {
    if (!Platform.isAndroid) return;
    unawaited(
      _channel
          .invokeMethod<void>('diag', {'message': message})
          .catchError((Object _) {}),
    );
  }

  /// Asks the Android side whether its own AssetManager can open [assetPath],
  /// independently of anything Flutter's `rootBundle` thinks.
  ///
  /// This is the one comparison that separates "the split's assets are not
  /// visible to the process" from "they are visible and the Dart-side read is
  /// what fails" — the two candidate explanations this build exists to
  /// distinguish.
  static Future<String> probeAsset(String assetPath) async {
    if (!Platform.isAndroid) return 'skipped: not android';
    try {
      final result = await _channel.invokeMethod<String>('probeAsset', {
        'asset': assetPath,
      });
      return result ?? 'null';
    } catch (error) {
      return 'probe failed: $error';
    }
  }
}
