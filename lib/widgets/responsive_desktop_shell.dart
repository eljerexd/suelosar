import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The supported viewport ranges for the SuelosAR responsive shell.
enum SuelosArViewport { phone, tablet, desktop }

enum SuelosArDesktopDensity { compact, comfortable, spacious }

bool isSuelosArDesktopPlatform(BuildContext context) {
  if (kIsWeb) return false;
  return switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
}

bool isSuelosArCompactAndroidPortrait(BuildContext context) {
  if (kIsWeb || Theme.of(context).platform != TargetPlatform.android) {
    return false;
  }
  final size = MediaQuery.sizeOf(context);
  return size.height > size.width && size.shortestSide < 600;
}

bool isSuelosArAndroidPhoneLandscape(BuildContext context) {
  if (kIsWeb || Theme.of(context).platform != TargetPlatform.android) {
    return false;
  }
  final size = MediaQuery.sizeOf(context);
  return size.width > size.height && size.shortestSide < 600;
}

/// Layout metrics derived from the current viewport width.
///
/// Phone values deliberately mirror the existing Android spacing. Tablet and
/// desktop values only apply when a screen opts into this shell.
@immutable
class SuelosArResponsiveLayout {
  const SuelosArResponsiveLayout._(this.viewport, this.desktopDensity);

  factory SuelosArResponsiveLayout.fromWidth(
    double width, {
    bool desktopPlatform = false,
  }) {
    if (desktopPlatform) {
      final density = width < 900
          ? SuelosArDesktopDensity.compact
          : width < 1440
          ? SuelosArDesktopDensity.comfortable
          : SuelosArDesktopDensity.spacious;
      return SuelosArResponsiveLayout._(SuelosArViewport.desktop, density);
    }
    if (width < phoneBreakpoint) {
      return const SuelosArResponsiveLayout._(
        SuelosArViewport.phone,
        SuelosArDesktopDensity.comfortable,
      );
    }
    if (width <= tabletBreakpoint) {
      return const SuelosArResponsiveLayout._(
        SuelosArViewport.tablet,
        SuelosArDesktopDensity.comfortable,
      );
    }
    return SuelosArResponsiveLayout.fromWidth(width, desktopPlatform: true);
  }

  factory SuelosArResponsiveLayout.fromContext(BuildContext context) =>
      SuelosArResponsiveLayout.fromWidth(
        MediaQuery.sizeOf(context).width,
        desktopPlatform: isSuelosArDesktopPlatform(context),
      );

  static const double phoneBreakpoint = 700;
  static const double tabletBreakpoint = 1200;

  final SuelosArViewport viewport;
  final SuelosArDesktopDensity desktopDensity;

  bool get isPhone => viewport == SuelosArViewport.phone;
  bool get isTablet => viewport == SuelosArViewport.tablet;
  bool get isDesktop => viewport == SuelosArViewport.desktop;

  double get pageInset => switch ((viewport, desktopDensity)) {
    (SuelosArViewport.phone, _) => 14,
    (SuelosArViewport.tablet, _) => 24,
    (SuelosArViewport.desktop, SuelosArDesktopDensity.compact) => 10,
    (SuelosArViewport.desktop, SuelosArDesktopDensity.comfortable) => 14,
    (SuelosArViewport.desktop, SuelosArDesktopDensity.spacious) => 18,
  };

  double get panelGap => switch (viewport) {
    SuelosArViewport.phone => 12,
    SuelosArViewport.tablet => 16,
    SuelosArViewport.desktop => 20,
  };

  EdgeInsets get pagePadding => EdgeInsets.all(pageInset);

  EdgeInsets get panelPadding => switch ((viewport, desktopDensity)) {
    (SuelosArViewport.phone, _) => const EdgeInsets.all(18),
    (SuelosArViewport.tablet, _) => const EdgeInsets.all(20),
    (SuelosArViewport.desktop, SuelosArDesktopDensity.compact) =>
      const EdgeInsets.all(14),
    (SuelosArViewport.desktop, _) => const EdgeInsets.all(18),
  };

  double get sidePanelMaxWidth => switch ((viewport, desktopDensity)) {
    (SuelosArViewport.phone, _) => 360,
    (SuelosArViewport.tablet, _) => 380,
    (SuelosArViewport.desktop, SuelosArDesktopDensity.compact) => 236,
    (SuelosArViewport.desktop, SuelosArDesktopDensity.comfortable) => 272,
    (SuelosArViewport.desktop, SuelosArDesktopDensity.spacious) => 300,
  };

  double get informationPanelMaxWidth => switch ((viewport, desktopDensity)) {
    (SuelosArViewport.phone, _) => 520,
    (SuelosArViewport.tablet, _) => 560,
    (SuelosArViewport.desktop, SuelosArDesktopDensity.compact) => 340,
    (SuelosArViewport.desktop, SuelosArDesktopDensity.comfortable) => 360,
    (SuelosArViewport.desktop, SuelosArDesktopDensity.spacious) => 380,
  };
}

typedef SuelosArResponsiveBuilder =
    Widget Function(BuildContext context, SuelosArResponsiveLayout layout);

/// Supplies the current responsive layout without coupling a page to a
/// platform or device type.
class SuelosArResponsivePage extends StatelessWidget {
  const SuelosArResponsivePage({
    required this.builder,
    this.useSafeArea = false,
    super.key,
  });

  final SuelosArResponsiveBuilder builder;
  final bool useSafeArea;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = SuelosArResponsiveLayout.fromWidth(
          constraints.maxWidth,
          desktopPlatform: isSuelosArDesktopPlatform(context),
        );
        final child = builder(context, layout);
        return useSafeArea ? SafeArea(child: child) : child;
      },
    );
  }
}

/// A floating Material 3 surface for panels layered over a page or map.
class SuelosArFloatingPanel extends StatelessWidget {
  const SuelosArFloatingPanel({
    required this.child,
    this.padding,
    this.constraints,
    this.elevation = 3,
    this.shadowAlpha = 0.18,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BoxConstraints? constraints;
  final double elevation;
  final double shadowAlpha;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final layout = SuelosArResponsiveLayout.fromContext(context);
    return Material(
      color: Colors.white,
      elevation: elevation,
      shadowColor: colorScheme.shadow.withValues(alpha: shadowAlpha),
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: constraints ?? const BoxConstraints(),
        child: Padding(padding: padding ?? layout.panelPadding, child: child),
      ),
    );
  }
}

/// A standard left-side floating panel for desktop and tablet compositions.
class SuelosArFloatingSidePanel extends StatelessWidget {
  const SuelosArFloatingSidePanel({
    required this.child,
    this.padding,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final layout = SuelosArResponsiveLayout.fromContext(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: layout.sidePanelMaxWidth),
      child: SuelosArFloatingPanel(
        padding: padding,
        elevation: 5,
        shadowAlpha: 0.22,
        child: child,
      ),
    );
  }
}

/// A standard floating information surface for map details and summaries.
class SuelosArFloatingInformationPanel extends StatelessWidget {
  const SuelosArFloatingInformationPanel({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final layout = SuelosArResponsiveLayout.fromContext(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: layout.informationPanelMaxWidth),
      child: SuelosArFloatingPanel(
        elevation: 5,
        shadowAlpha: 0.22,
        child: child,
      ),
    );
  }
}

/// Composes a desktop or tablet page around floating panels while returning
/// its phone child untouched. Existing Android screens can adopt it safely.
class SuelosArDesktopPageScaffold extends StatelessWidget {
  const SuelosArDesktopPageScaffold({
    required this.child,
    this.sidePanel,
    this.informationPanel,
    this.informationAlignment = Alignment.bottomCenter,
    this.showPanelsOnTablet = false,
    this.panelTopInset = 0,
    this.sidePanelVerticalInset = 0,
    super.key,
  });

  final Widget child;
  final Widget? sidePanel;
  final Widget? informationPanel;
  final Alignment informationAlignment;
  final bool showPanelsOnTablet;
  final double panelTopInset;
  final double sidePanelVerticalInset;

  @override
  Widget build(BuildContext context) {
    return SuelosArResponsivePage(
      builder: (context, layout) {
        if (layout.isPhone) return child;
        final showPanels = layout.isDesktop || showPanelsOnTablet;
        if (!showPanels || (sidePanel == null && informationPanel == null)) {
          return child;
        }

        return Stack(
          children: [
            Positioned.fill(child: child),
            Positioned.fill(
              child: SafeArea(
                child: Padding(
                  padding: layout.pagePadding.add(
                    EdgeInsets.only(top: panelTopInset),
                  ),
                  child: Stack(
                    children: [
                      if (sidePanel != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: sidePanelVerticalInset,
                            ),
                            child: sidePanel!,
                          ),
                        ),
                      if (informationPanel != null)
                        Align(
                          alignment: informationAlignment,
                          child: informationPanel!,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
