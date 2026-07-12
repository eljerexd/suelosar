import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../constants/app_icons.dart';

enum AppNotificationType { success, information, warning, error }

abstract final class AppNotification {
  static OverlayEntry? _activeEntry;
  static Completer<void>? _activeCompleter;

  static Future<void> show(
    BuildContext context, {
    required String message,
    AppNotificationType type = AppNotificationType.information,
    double bottomOffset = 24,
  }) {
    dismiss();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return Future<void>.value();

    final mediaQuery = MediaQuery.of(context);
    final isDesktop =
        mediaQuery.size.width >= 700 &&
        (kIsWeb ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    final completer = Completer<void>();
    _activeCompleter = completer;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => _NotificationOverlay(
        message: message,
        type: type,
        isDesktop: isDesktop,
        bottom: bottomOffset + mediaQuery.padding.bottom,
        duration: _durationFor(type),
        onComplete: () => _finishEntry(entry, remove: true),
        onDispose: () => _finishEntry(entry, remove: false),
      ),
    );
    _activeEntry = entry;
    overlay.insert(entry);
    return completer.future;
  }

  static void dismiss() {
    final entry = _activeEntry;
    if (entry == null) return;
    _finishEntry(entry, remove: true);
  }

  static void _finishEntry(OverlayEntry entry, {required bool remove}) {
    if (!identical(_activeEntry, entry)) return;
    _activeEntry = null;
    final completer = _activeCompleter;
    _activeCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
    if (remove && entry.mounted) entry.remove();
  }

  static Duration _durationFor(AppNotificationType type) => switch (type) {
    AppNotificationType.success => const Duration(seconds: 2),
    AppNotificationType.information => const Duration(seconds: 2),
    AppNotificationType.warning => const Duration(milliseconds: 2500),
    AppNotificationType.error => const Duration(seconds: 3),
  };
}

class _NotificationOverlay extends StatefulWidget {
  const _NotificationOverlay({
    required this.message,
    required this.type,
    required this.isDesktop,
    required this.bottom,
    required this.duration,
    required this.onComplete,
    required this.onDispose,
  });

  final String message;
  final AppNotificationType type;
  final bool isDesktop;
  final double bottom;
  final Duration duration;
  final VoidCallback onComplete;
  final VoidCallback onDispose;

  @override
  State<_NotificationOverlay> createState() => _NotificationOverlayState();
}

class _NotificationOverlayState extends State<_NotificationOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _entrance;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onComplete();
      });
    _entrance = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.09, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    widget.onDispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _colors(widget.type, Theme.of(context).colorScheme);
    final notification = AnimatedBuilder(
      animation: _entrance,
      builder: (context, child) => Opacity(
        opacity: _entrance.value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - _entrance.value)),
          child: child,
        ),
      ),
      child: Material(
        color: colors.background,
        elevation: 5,
        shadowColor: Theme.of(
          context,
        ).colorScheme.shadow.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(colors.icon, size: 19, color: colors.foreground),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  widget.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Positioned(
      left: 20,
      right: widget.isDesktop ? null : 20,
      bottom: widget.bottom,
      child: widget.isDesktop
          ? notification
          : Align(alignment: Alignment.bottomCenter, child: notification),
    );
  }

  _NotificationColors _colors(
    AppNotificationType type,
    ColorScheme colorScheme,
  ) => switch (type) {
    AppNotificationType.success => _NotificationColors(
      background: const Color(0xFFF1F5EB),
      foreground: const Color(0xFF445538),
      border: const Color(0xFFB9C8AA),
      icon: AppIcons.success,
    ),
    AppNotificationType.information => _NotificationColors(
      background: colorScheme.surfaceContainerLow,
      foreground: colorScheme.onSurface,
      border: colorScheme.outlineVariant,
      icon: AppIcons.information,
    ),
    AppNotificationType.warning => const _NotificationColors(
      background: Color(0xFFFFF6E8),
      foreground: Color(0xFF725119),
      border: Color(0xFFE4C78E),
      icon: AppIcons.warning,
    ),
    AppNotificationType.error => const _NotificationColors(
      background: Color(0xFFFFF0ED),
      foreground: Color(0xFF7B352E),
      border: Color(0xFFE0B0A9),
      icon: AppIcons.error,
    ),
  };
}

class _NotificationColors {
  const _NotificationColors({
    required this.background,
    required this.foreground,
    required this.border,
    required this.icon,
  });

  final Color background;
  final Color foreground;
  final Color border;
  final IconData icon;
}
