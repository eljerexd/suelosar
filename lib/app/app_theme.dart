import 'package:flutter/material.dart';

class AppTheme {
  const AppTheme._();

  static ThemeData light({bool reduceAnimations = false}) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF687654),
    ).copyWith(surface: const Color(0xFFFBFAF5));

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      pageTransitionsTheme: reduceAnimations
          ? const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: _NoPageTransitionsBuilder(),
                TargetPlatform.iOS: _NoPageTransitionsBuilder(),
                TargetPlatform.macOS: _NoPageTransitionsBuilder(),
                TargetPlatform.windows: _NoPageTransitionsBuilder(),
                TargetPlatform.linux: _NoPageTransitionsBuilder(),
              },
            )
          : const PageTransitionsTheme(),
      scaffoldBackgroundColor: const Color(0xFFF2F4EC),
      cardTheme: CardThemeData(
        elevation: 1,
        shadowColor: colorScheme.shadow.withValues(alpha: 0.16),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFFFBFAF5),
        surfaceTintColor: Colors.transparent,
        modalElevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      extensions: const [
        SuelosArMapControlColors(
          background: Color(0xFF9B7657),
          foreground: Color(0xFFFFF9F0),
          activeAccent: Color(0xFF71805A),
        ),
      ],
    );
  }
}

class _NoPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

@immutable
class SuelosArMapControlColors
    extends ThemeExtension<SuelosArMapControlColors> {
  const SuelosArMapControlColors({
    required this.background,
    required this.foreground,
    required this.activeAccent,
  });

  final Color background;
  final Color foreground;
  final Color activeAccent;

  @override
  SuelosArMapControlColors copyWith({
    Color? background,
    Color? foreground,
    Color? activeAccent,
  }) {
    return SuelosArMapControlColors(
      background: background ?? this.background,
      foreground: foreground ?? this.foreground,
      activeAccent: activeAccent ?? this.activeAccent,
    );
  }

  @override
  SuelosArMapControlColors lerp(
    covariant SuelosArMapControlColors? other,
    double t,
  ) {
    if (other == null) return this;
    return SuelosArMapControlColors(
      background: Color.lerp(background, other.background, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      activeAccent: Color.lerp(activeAccent, other.activeAccent, t)!,
    );
  }
}
