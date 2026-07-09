import 'package:flutter/material.dart';

import '../app/app_routes.dart';
import '../constants/app_icons.dart';
import '../utils/app_motion.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Color.alphaBlend(
        colorScheme.primary.withValues(alpha: 0.025),
        Theme.of(context).scaffoldBackgroundColor,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Center(child: _OfficialSuelosArLogo()),
                        const SizedBox(height: 8),
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: Text(
                              'Cartografía de Suelos de la '
                              'Provincia de Buenos Aires',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                    height: 1.35,
                                  ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 50),
                        _ModuleCard(
                          key: const ValueKey('module-gis-map'),
                          icon: AppIcons.map,
                          title: 'Mapa de Suelos',
                          subtitle: 'Explorar el visor GIS interactivo.',
                          primary: true,
                          onTap: () =>
                              Navigator.of(context).pushNamed(AppRoutes.gisMap),
                        ),
                        const SizedBox(height: 18),
                        LayoutBuilder(
                          builder: (context, gridConstraints) {
                            final useSingleColumn =
                                gridConstraints.maxWidth < 620;
                            final cardWidth = useSingleColumn
                                ? gridConstraints.maxWidth
                                : (gridConstraints.maxWidth - 18) / 2;
                            return Wrap(
                              spacing: 18,
                              runSpacing: 18,
                              children: [
                                SizedBox(
                                  width: cardWidth,
                                  child: _ModuleCard(
                                    key: const ValueKey('module-soil-maps'),
                                    icon: AppIcons.pdf,
                                    title: 'Cartas de Suelo',
                                    subtitle:
                                        'Buscar y consultar cartas descriptivas en PDF.',
                                    onTap: () => Navigator.of(
                                      context,
                                    ).pushNamed(AppRoutes.soilMaps),
                                  ),
                                ),
                                SizedBox(
                                  width: cardWidth,
                                  child: _ModuleCard(
                                    key: const ValueKey(
                                      'module-personal-markers',
                                    ),
                                    icon: AppIcons.location,
                                    title: 'Marcadores',
                                    subtitle:
                                        'Registrar y administrar observaciones de campo.',
                                    onTap: () => Navigator.of(
                                      context,
                                    ).pushNamed(AppRoutes.personalMarkers),
                                  ),
                                ),
                                SizedBox(
                                  width: cardWidth,
                                  child: _ModuleCard(
                                    key: const ValueKey('module-settings'),
                                    icon: AppIcons.settings,
                                    title: 'Configuración',
                                    subtitle: 'Preferencias de la aplicación.',
                                    subdued: true,
                                    onTap: () => Navigator.of(
                                      context,
                                    ).pushNamed(AppRoutes.settings),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _OfficialSuelosArLogo extends StatelessWidget {
  const _OfficialSuelosArLogo();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(240.0, 560.0);

        return Semantics(
          image: true,
          label: 'SuelosAR',
          child: Image.asset(
            'assets/images/logoapp.png',
            width: width,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            excludeFromSemantics: true,
          ),
        );
      },
    );
  }
}

class _ModuleCard extends StatefulWidget {
  const _ModuleCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
    this.subdued = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;
  final bool subdued;

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  static const double _restingElevation = 1;
  static const double _hoverElevation = 4;

  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final cardHeight = widget.primary ? 134.0 : 136.0;
    final motionDuration = AppMotion.duration(
      context,
      const Duration(milliseconds: 180),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedSlide(
        offset: Offset(0, _hovered ? -0.015 : 0),
        duration: motionDuration,
        curve: Curves.easeOutCubic,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: _hovered ? _hoverElevation : _restingElevation),
          duration: motionDuration,
          curve: Curves.easeOutCubic,
          builder: (context, elevation, child) {
            return Card(
              margin: EdgeInsets.zero,
              elevation: elevation,
              shadowColor: colorScheme.shadow.withValues(alpha: 0.16),
              color: widget.primary
                  ? colorScheme.primaryContainer.withValues(alpha: 0.24)
                  : widget.subdued
                  ? colorScheme.surfaceContainerLowest
                  : colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onTap,
                child: SizedBox(
                  height: cardHeight,
                  child: Padding(
                    padding: widget.primary
                        ? const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          )
                        : const EdgeInsets.fromLTRB(20, 12, 16, 12),
                    child: _buildCardContent(context, colorScheme),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCardContent(BuildContext context, ColorScheme colorScheme) {
    if (widget.primary) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return Center(
            child: Row(
              key: const ValueKey('primary-card-content'),
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildIcon(colorScheme, size: 54),
                const SizedBox(width: 16),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth - 70,
                  ),
                  child: _buildText(
                    context,
                    colorScheme,
                    alignment: CrossAxisAlignment.start,
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    return Row(
      children: [
        _buildIcon(colorScheme, size: 50),
        const SizedBox(width: 16),
        Expanded(
          child: _buildText(
            context,
            colorScheme,
            alignment: CrossAxisAlignment.start,
          ),
        ),
        const SizedBox(width: 12),
        const Padding(
          padding: EdgeInsets.only(right: 4),
          child: Icon(AppIcons.chevronRight, size: 20),
        ),
      ],
    );
  }

  Widget _buildIcon(ColorScheme colorScheme, {required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: widget.primary
            ? colorScheme.primaryContainer
            : widget.subdued
            ? colorScheme.surfaceContainerHigh
            : colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        widget.icon,
        size: widget.primary ? 32 : 28,
        color: widget.primary
            ? colorScheme.onPrimaryContainer
            : widget.subdued
            ? colorScheme.onSurfaceVariant
            : colorScheme.onSecondaryContainer,
      ),
    );
  }

  Widget _buildText(
    BuildContext context,
    ColorScheme colorScheme, {
    required CrossAxisAlignment alignment,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: [
        Text(
          widget.title,
          textAlign: TextAlign.start,
          style:
              (widget.primary
                      ? Theme.of(context).textTheme.titleLarge
                      : Theme.of(context).textTheme.titleMedium)
                  ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          widget.subtitle,
          textAlign: TextAlign.start,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
