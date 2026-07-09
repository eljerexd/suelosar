import 'package:flutter/material.dart';

abstract final class AppMotion {
  static Duration duration(
    BuildContext context,
    Duration normal, {
    Duration reduced = Duration.zero,
  }) {
    return MediaQuery.disableAnimationsOf(context) ? reduced : normal;
  }
}
