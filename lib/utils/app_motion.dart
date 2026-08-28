import 'package:flutter/material.dart';

import '../services/settings_service.dart';

abstract final class AppMotion {
  /// Whether animations should be shortened — either because the OS-level
  /// accessibility "reduce motion" preference is on, or because the user
  /// turned on SuelosAR's own "Reducir animaciones" setting. Previously only
  /// the OS preference was checked here, so that in-app setting only ever
  /// affected page-route transitions (its own separate wiring in
  /// AppTheme.light/dark) and did nothing for every other animation that
  /// goes through this helper — its name promised more than it did.
  static bool _reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      SettingsService.instance.reduceAnimations;

  static Duration duration(
    BuildContext context,
    Duration normal, {
    Duration reduced = Duration.zero,
  }) {
    return _reduced(context) ? reduced : normal;
  }
}
