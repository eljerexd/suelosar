import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../constants/app_icons.dart';
import '../utils/app_motion.dart';

class FloatingAppBarCard extends StatelessWidget {
  const FloatingAppBarCard({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.elevation = 3,
    this.shadowAlpha = 0.18,
    this.side,
    super.key,
  });

  static const double height = 64;

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double elevation;
  final double shadowAlpha;
  final BorderSide? side;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.white,
      elevation: elevation,
      shadowColor: colorScheme.shadow.withValues(alpha: shadowAlpha),
      surfaceTintColor: Colors.transparent,
      borderRadius: side == null ? BorderRadius.circular(24) : null,
      shape: side == null
          ? null
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: side!,
            ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: height),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class FloatingHeaderScaffold extends StatelessWidget {
  const FloatingHeaderScaffold({
    required this.header,
    required this.body,
    this.bottomPadding = 0,
    super.key,
  });

  final Widget header;
  final Widget body;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            FloatingAppBarLayout.horizontalMargin,
            FloatingAppBarLayout.topGap,
            FloatingAppBarLayout.horizontalMargin,
            bottomPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: FloatingAppBarCard(child: header),
              ),
              const SizedBox(height: FloatingAppBarLayout.contentGap),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FloatingAppBarLayout.contentHorizontalInset,
                  ),
                  child: body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

abstract final class FloatingAppBarLayout {
  static const double horizontalMargin = 14;
  static const double contentHorizontalInset = 6;
  static const double topGap = 12;
  static const double contentGap = 18;
}

class FloatingAppBarBackButton extends StatefulWidget {
  const FloatingAppBarBackButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  State<FloatingAppBarBackButton> createState() =>
      _FloatingAppBarBackButtonState();
}

class FloatingAppBarTitle extends StatelessWidget {
  const FloatingAppBarTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _FloatingAppBarBackButtonState extends State<FloatingAppBarBackButton> {
  static const _duration = Duration(milliseconds: 180);

  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors =
        theme.extension<SuelosArMapControlColors>() ??
        const SuelosArMapControlColors(
          background: Color(0xFF9B7657),
          foreground: Color(0xFFFFF9F0),
          activeAccent: Color(0xFF71805A),
        );
    final scale = _pressed ? 0.96 : (_hovered ? 1.02 : 1.0);
    final duration = AppMotion.duration(context, _duration);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: Material(
            color: colors.background,
            elevation: _hovered ? 3 : 1,
            shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.16),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: SizedBox.square(
              dimension: 44,
              child: IconButton(
                tooltip: 'Volver',
                onPressed: widget.onPressed,
                padding: EdgeInsets.zero,
                iconSize: 21,
                icon: Icon(AppIcons.arrowBack, color: colors.foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
