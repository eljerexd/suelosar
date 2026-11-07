import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/app_icons.dart';

enum UpdateFeedbackType { success, error, checking }

class UpdateFeedbackPresenter {
  Future<void> _queue = Future<void>.value();
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _current;
  ScaffoldMessengerState? _messenger;
  UpdateFeedbackType? _currentType;
  bool _disposed = false;

  Future<void> show(BuildContext context, UpdateFeedbackType type) {
    if (!context.mounted) return Future<void>.value();
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return Future<void>.value();
    final width = (MediaQuery.sizeOf(context).width - 32)
        .clamp(160.0, 420.0)
        .toDouble();
    final reduceAnimations = MediaQuery.disableAnimationsOf(context);
    _queue = _queue
        .catchError((Object _) {})
        .then((_) => _present(messenger, width, reduceAnimations, type));
    return _queue;
  }

  Future<void> dismiss() {
    _queue = _queue.catchError((Object _) {}).then((_) => _closeCurrent());
    return _queue;
  }

  Future<void> _present(
    ScaffoldMessengerState messenger,
    double width,
    bool reduceAnimations,
    UpdateFeedbackType type,
  ) async {
    if (_disposed || !messenger.mounted) return;
    if (_current != null &&
        _currentType == type &&
        _messenger?.mounted == true) {
      return;
    }
    await _closeCurrent();
    if (_disposed || !messenger.mounted) return;
    final controller = messenger.showSnackBar(
      SnackBar(
        key: ValueKey('update-feedback-${type.name}'),
        content: UpdateFeedbackNotification(
          key: const ValueKey('update-feedback-content'),
          type: type,
          reduceAnimations: reduceAnimations,
        ),
        behavior: SnackBarBehavior.floating,
        width: width,
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        duration: _durationFor(type),
      ),
      snackBarAnimationStyle: reduceAnimations
          ? AnimationStyle.noAnimation
          : null,
    );
    _messenger = messenger;
    _current = controller;
    _currentType = type;
    controller.closed.then((_) {
      if (identical(_current, controller)) {
        _current = null;
        _currentType = null;
      }
    });
  }

  Future<void> _closeCurrent() async {
    final current = _current;
    if (current == null) return;
    final messenger = _messenger;
    _current = null;
    _messenger = null;
    _currentType = null;
    if (messenger == null || !messenger.mounted) return;
    messenger.removeCurrentSnackBar();
    await current.closed;
  }

  static Duration _durationFor(UpdateFeedbackType type) => switch (type) {
    UpdateFeedbackType.success => const Duration(milliseconds: 2800),
    UpdateFeedbackType.error => const Duration(seconds: 4),
    UpdateFeedbackType.checking => const Duration(seconds: 22),
  };

  void dispose() {
    _disposed = true;
    _current = null;
    _messenger = null;
    _currentType = null;
  }
}

class UpdateFeedbackNotification extends StatelessWidget {
  const UpdateFeedbackNotification({
    required this.type,
    required this.reduceAnimations,
    super.key,
  });

  final UpdateFeedbackType type;
  final bool reduceAnimations;

  String get message => switch (type) {
    UpdateFeedbackType.success => 'Ya tenés la última versión.',
    UpdateFeedbackType.error => 'No se pudo comprobar si hay actualizaciones.',
    UpdateFeedbackType.checking => 'Buscando actualizaciones...',
  };

  @override
  Widget build(BuildContext context) {
    final colors = _colors(type);
    final content = Semantics(
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: Material(
          key: const ValueKey('update-feedback-surface'),
          color: colors.background,
          elevation: 5,
          shadowColor: const Color(0x263D4536),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: colors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  key: const ValueKey('update-feedback-icon-container'),
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: colors.iconSurface,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: type == UpdateFeedbackType.checking
                      ? reduceAnimations
                            ? Icon(
                                AppIcons.refresh,
                                key: const ValueKey('update-feedback-icon'),
                                size: 18,
                                color: colors.accent,
                              )
                            : SizedBox.square(
                                dimension: 17,
                                child: CircularProgressIndicator(
                                  key: const ValueKey(
                                    'update-feedback-progress',
                                  ),
                                  strokeWidth: 2,
                                  color: colors.accent,
                                ),
                              )
                      : Icon(
                          type == UpdateFeedbackType.success
                              ? AppIcons.success
                              : Icons.cloud_off_outlined,
                          key: const ValueKey('update-feedback-icon'),
                          size: 18,
                          color: colors.accent,
                        ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    message,
                    key: const ValueKey('update-feedback-message'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.foreground,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (reduceAnimations) return content;
    return TweenAnimationBuilder<double>(
      key: const ValueKey('update-feedback-transition'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 7),
          child: child,
        ),
      ),
      child: content,
    );
  }

  _UpdateFeedbackColors _colors(UpdateFeedbackType type) => switch (type) {
    UpdateFeedbackType.success => const _UpdateFeedbackColors(
      background: Color(0xFFF1F5EC),
      foreground: Color(0xFF3E5232),
      accent: Color(0xFF547A3A),
      iconSurface: Color(0xFFE2EBDD),
      border: Color(0xFFD5E0CC),
    ),
    UpdateFeedbackType.error => const _UpdateFeedbackColors(
      background: Color(0xFFF4F2EC),
      foreground: Color(0xFF4D5149),
      accent: Color(0xFF777B6F),
      iconSurface: Color(0xFFE9E8E1),
      border: Color(0xFFDEDED6),
    ),
    UpdateFeedbackType.checking => const _UpdateFeedbackColors(
      background: Color(0xFFF6F4EE),
      foreground: Color(0xFF53574E),
      accent: Color(0xFF687654),
      iconSurface: Color(0xFFECEBE3),
      border: Color(0xFFE0DFD6),
    ),
  };
}

class _UpdateFeedbackColors {
  const _UpdateFeedbackColors({
    required this.background,
    required this.foreground,
    required this.accent,
    required this.iconSurface,
    required this.border,
  });

  final Color background;
  final Color foreground;
  final Color accent;
  final Color iconSurface;
  final Color border;
}
