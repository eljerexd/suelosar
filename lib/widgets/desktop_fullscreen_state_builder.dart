import 'package:flutter/material.dart';

import '../services/desktop_window_service.dart';

typedef DesktopFullscreenWidgetBuilder =
    Widget Function(BuildContext context, bool isFullScreen);

/// Rebuilds a desktop control from the window manager's current state.
class DesktopFullscreenStateBuilder extends StatelessWidget {
  const DesktopFullscreenStateBuilder({
    required this.service,
    required this.builder,
    super.key,
  });

  final DesktopWindowService service;
  final DesktopFullscreenWidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, child) => FutureBuilder<bool>(
        future: service.isFullScreen(),
        initialData: false,
        builder: (context, snapshot) {
          return builder(context, snapshot.data ?? false);
        },
      ),
    );
  }
}
