import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

/// Visual shell for the future map tools migration.
class ExpandableToolsFab extends StatefulWidget {
  const ExpandableToolsFab({
    required this.onMeasureDistance,
    required this.onMeasureArea,
    required this.onMarkers,
    required this.onFavorites,
    this.onExitMeasurement,
    this.embedded = false,
    super.key,
  });

  final VoidCallback onMeasureDistance;
  final VoidCallback onMeasureArea;
  final VoidCallback onMarkers;
  final VoidCallback onFavorites;
  final VoidCallback? onExitMeasurement;
  final bool embedded;

  @override
  State<ExpandableToolsFab> createState() => _ExpandableToolsFabState();
}

class _ExpandableToolsFabState extends State<ExpandableToolsFab>
    with SingleTickerProviderStateMixin {
  static const Duration _motionDuration = Duration(milliseconds: 200);
  late final AnimationController _controller;
  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _layerLink = LayerLink();
  bool _isOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _motionDuration,
      reverseDuration: const Duration(milliseconds: 180),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _isOpen = !_isOpen);
    if (_isOpen) {
      _overlayController.show();
      _controller.forward();
    } else {
      _controller.reverse().whenComplete(_overlayController.hide);
    }
  }

  void _close() {
    if (!_isOpen) return;
    setState(() => _isOpen = false);
    _controller.reverse().whenComplete(_overlayController.hide);
  }

  void _run(VoidCallback action) {
    _close();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mapControlColors =
        Theme.of(context).extension<SuelosArMapControlColors>() ??
        const SuelosArMapControlColors(
          background: Color(0xFF9B7657),
          foreground: Color(0xFFFFF9F0),
          activeAccent: Color(0xFF71805A),
        );
    final tools = [
      _ToolAction(
        'Medir distancia',
        Icons.straighten,
        widget.onMeasureDistance,
      ),
      _ToolAction(
        'Medir área',
        Icons.square_foot_rounded,
        widget.onMeasureArea,
      ),
      _ToolAction('Marcadores', Icons.pin_drop_outlined, widget.onMarkers),
      _ToolAction('Favoritos', Icons.star_rounded, widget.onFavorites),
      if (widget.onExitMeasurement case final onExit?)
        _ToolAction('Salir de medición', Icons.close_rounded, onExit),
    ];
    if (widget.embedded) {
      return OverlayPortal(
        controller: _overlayController,
        overlayChildBuilder: (context) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              targetAnchor: Alignment.topCenter,
              followerAnchor: Alignment.bottomCenter,
              offset: const Offset(0, -10),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = tools.length - 1; index >= 0; index--) ...[
                      _AnimatedCircularToolButton(
                        animation: _controller,
                        staggerIndex: index,
                        tool: tools[index],
                        onPressed: () => _run(tools[index].onPressed),
                      ),
                      if (index != 0) const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
        child: CompositedTransformTarget(
          link: _layerLink,
          child: Tooltip(
            message: 'Herramientas',
            child: Material(
              elevation: _isOpen ? 3 : 1,
              shadowColor: colorScheme.shadow.withValues(alpha: 0.16),
              color:
                  (_isOpen
                          ? mapControlColors.activeAccent
                          : mapControlColors.background)
                      .withValues(alpha: 0.97),
              surfaceTintColor: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _toggle,
                child: SizedBox.square(
                  dimension: 44,
                  child: RotationTransition(
                    turns: Tween<double>(begin: 0, end: 0.125).animate(
                      CurvedAnimation(
                        parent: _controller,
                        curve: Curves.easeOutCubic,
                      ),
                    ),
                    child: Icon(
                      Icons.widgets_outlined,
                      size: 21,
                      color: mapControlColors.foreground,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final expandedMenuHeight = tools.length * 54.0 + 44;
        final bottomClearance =
            constraints.maxHeight >= expandedMenuHeight + 148 ? 132.0 : 16.0;

        return Stack(
          children: [
            if (_isOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                  child: ColoredBox(
                    color: colorScheme.scrim.withValues(alpha: 0.10),
                  ),
                ),
              ),
            SafeArea(
              minimum: EdgeInsets.fromLTRB(16, 16, 16, bottomClearance),
              child: Align(
                alignment: Alignment.bottomRight,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IgnorePointer(
                      ignoring: !_isOpen,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (
                            var index = tools.length - 1;
                            index >= 0;
                            index--
                          ) ...[
                            _AnimatedCircularToolButton(
                              animation: _controller,
                              staggerIndex: index,
                              tool: tools[index],
                              onPressed: () => _run(tools[index].onPressed),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ],
                      ),
                    ),
                    Tooltip(
                      message: 'Herramientas',
                      child: Material(
                        elevation: _isOpen ? 3 : 1,
                        shadowColor: colorScheme.shadow.withValues(alpha: 0.16),
                        color:
                            (_isOpen
                                    ? mapControlColors.activeAccent
                                    : mapControlColors.background)
                                .withValues(alpha: 0.97),
                        surfaceTintColor: Colors.transparent,
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _toggle,
                          child: SizedBox.square(
                            dimension: 44,
                            child: RotationTransition(
                              turns: Tween<double>(begin: 0, end: 0.125)
                                  .animate(
                                    CurvedAnimation(
                                      parent: _controller,
                                      curve: Curves.easeOutCubic,
                                    ),
                                  ),
                              child: Icon(
                                Icons.widgets_outlined,
                                size: 21,
                                color: mapControlColors.foreground,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AnimatedCircularToolButton extends StatelessWidget {
  const _AnimatedCircularToolButton({
    required this.animation,
    required this.staggerIndex,
    required this.tool,
    required this.onPressed,
  });

  final Animation<double> animation;
  final int staggerIndex;
  final _ToolAction tool;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final start = staggerIndex * 0.06;
    final itemAnimation = CurvedAnimation(
      parent: animation,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      reverseCurve: Curves.easeInCubic,
    );
    final colorScheme = Theme.of(context).colorScheme;
    final mapControlColors =
        Theme.of(context).extension<SuelosArMapControlColors>() ??
        const SuelosArMapControlColors(
          background: Color(0xFF9B7657),
          foreground: Color(0xFFFFF9F0),
          activeAccent: Color(0xFF71805A),
        );

    return FadeTransition(
      opacity: itemAnimation,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.9, end: 1).animate(itemAnimation),
        child: Tooltip(
          message: tool.label,
          child: Material(
            elevation: 1,
            shadowColor: colorScheme.shadow.withValues(alpha: 0.16),
            color: mapControlColors.background.withValues(alpha: 0.97),
            surfaceTintColor: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: SizedBox.square(
                dimension: 44,
                child: Icon(
                  tool.icon,
                  size: 22,
                  color: mapControlColors.foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolAction {
  const _ToolAction(this.label, this.icon, this.onPressed);

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}
