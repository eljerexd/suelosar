import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/desktop_window_service.dart';

/// Provides desktop window shortcuts without coupling individual screens to
/// the native window manager.
class DesktopWindowShortcutScope extends StatelessWidget {
  const DesktopWindowShortcutScope({
    required this.service,
    required this.child,
    super.key,
  });

  final DesktopWindowService service;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!service.isSupported) return child;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            unawaited(service.toggleFullScreen()),
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
