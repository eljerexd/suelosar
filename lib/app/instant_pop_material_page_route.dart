import 'package:flutter/material.dart';

/// Preserves the standard forward Material transition while making Back instant.
class InstantPopMaterialPageRoute<T> extends MaterialPageRoute<T> {
  InstantPopMaterialPageRoute({
    required super.builder,
    super.settings,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
  });

  @override
  Duration get reverseTransitionDuration => Duration.zero;
}
