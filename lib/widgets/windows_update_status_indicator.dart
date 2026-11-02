import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_icons.dart';
import '../services/windows_update_indicator_controller.dart';
import '../services/windows_update_models.dart';
import 'windows_update_status_popover.dart';

class WindowsUpdateStatusIndicator extends StatefulWidget {
  const WindowsUpdateStatusIndicator({
    required this.controller,
    this.layerLink,
    super.key,
  });

  final WindowsUpdateIndicatorController controller;
  final LayerLink? layerLink;

  @override
  State<WindowsUpdateStatusIndicator> createState() =>
      _WindowsUpdateStatusIndicatorState();
}

class _WindowsUpdateStatusIndicatorState
    extends State<WindowsUpdateStatusIndicator> {
  final OverlayPortalController _popoverController = OverlayPortalController();
  final LayerLink _localIndicatorLink = LayerLink();
  final GlobalKey _indicatorKey = GlobalKey();
  WindowsUpdatePopoverState? _popoverState;
  String? _installedVersion;

  LayerLink get _indicatorLink => widget.layerLink ?? _localIndicatorLink;

  @override
  void dispose() {
    super.dispose();
  }

  void _showPopover(WindowsUpdatePopoverState state) {
    setState(() => _popoverState = state);
    if (!_popoverController.isShowing) _popoverController.show();
  }

  void _dismissPopover() {
    if (!_popoverController.isShowing) return;
    _popoverController.hide();
    if (mounted) setState(() => _popoverState = null);
  }

  Future<void> _activate(BuildContext context) async {
    final controller = widget.controller;
    if (controller.state == WindowsUpdateIndicatorState.updateAvailable) {
      controller.selectAvailableUpdate();
      return;
    }
    await _runManualCheck(context);
  }

  Future<void> _runManualCheck(BuildContext context) async {
    final controller = widget.controller;
    _showPopover(WindowsUpdatePopoverState.checking);
    final result = await controller.checkManually();
    if (!mounted || !context.mounted) return;
    if (result?.status == WindowsUpdateStatus.upToDate) {
      final version = await controller.installedVersion;
      if (!mounted || !context.mounted) return;
      setState(() {
        _installedVersion = version;
        _popoverState = WindowsUpdatePopoverState.upToDate;
      });
      return;
    }
    if (controller.state == WindowsUpdateIndicatorState.error) {
      setState(() => _popoverState = WindowsUpdatePopoverState.error);
    } else if (controller.state ==
        WindowsUpdateIndicatorState.updateAvailable) {
      _dismissPopover();
      controller.selectAvailableUpdate();
    }
  }

  Widget _buildPopoverOverlay(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final indicatorBox =
        _indicatorKey.currentContext?.findRenderObject() as RenderBox?;
    final indicatorOffset = indicatorBox?.localToGlobal(Offset.zero);
    const edgeInset = 16.0;
    final popoverWidth = math.max(
      0.0,
      math.min(340.0, viewport.width - edgeInset * 2),
    );
    final preferredLeft = indicatorOffset?.dx ?? edgeInset;
    final maxLeft = math.max(
      edgeInset,
      viewport.width - edgeInset - popoverWidth,
    );
    final popoverLeft = preferredLeft.clamp(edgeInset, maxLeft).toDouble();
    final horizontalOffset = popoverLeft - preferredLeft;
    final anchorX = (((indicatorOffset?.dx ?? popoverLeft) - popoverLeft) + 26)
        .clamp(16.0, math.max(16.0, popoverWidth - 16))
        .toDouble();
    final indicatorBottom =
        (indicatorOffset?.dy ?? 0) + (indicatorBox?.size.height ?? 44);
    final availableHeight = math.max(
      0.0,
      viewport.height - indicatorBottom - 12,
    );

    final reduceAnimations = MediaQuery.disableAnimationsOf(context);
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _dismissPopover();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              button: true,
              label: 'Cerrar aviso de actualización',
              child: GestureDetector(
                key: const ValueKey('update-popover-outside-dismiss'),
                behavior: HitTestBehavior.opaque,
                onTap: _dismissPopover,
                child: const SizedBox.expand(),
              ),
            ),
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: reduceAnimations
                ? Duration.zero
                : const Duration(milliseconds: 170),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) => Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, -4 * (1 - value)),
                child: child,
              ),
            ),
            child: CompositedTransformFollower(
              link: _indicatorLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: Offset(horizontalOffset, 3),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: popoverWidth,
                  maxHeight: availableHeight,
                ),
                child: SingleChildScrollView(
                  child: WindowsUpdateStatusPopover(
                    state: _popoverState!,
                    installedVersion: _installedVersion,
                    reduceAnimations: reduceAnimations,
                    anchorX: anchorX,
                    onCheck: () => _runManualCheck(context),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final presentation = _presentation(context, controller);
        final isChecking =
            controller.state == WindowsUpdateIndicatorState.checking;
        final hasDownloadPopup = controller.hasDownloadPopup;
        final isDownloadRunning =
            controller.downloadState ==
                WindowsUpdateDownloadState.downloading ||
            controller.downloadState == WindowsUpdateDownloadState.cancelling;
        final reduceAnimations = MediaQuery.disableAnimationsOf(context);
        final actionLabel = hasDownloadPopup
            ? controller.isDownloadPopupExpanded
                  ? 'Descarga en curso. Minimizar progreso.'
                  : 'Descarga en curso. Mostrar progreso.'
            : presentation.semanticLabel;
        return OverlayPortal(
          controller: _popoverController,
          overlayChildBuilder: _buildPopoverOverlay,
          child: CompositedTransformTarget(
            link: _indicatorLink,
            child: Semantics(
              key: const ValueKey('windows-update-status-indicator'),
              button: !isChecking,
              label: actionLabel,
              child: Material(
                key: _indicatorKey,
                color: presentation.background,
                elevation: 1,
                shadowColor: const Color(0x1A3F4638),
                shape: StadiumBorder(
                  side: BorderSide(color: presentation.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: isChecking
                      ? null
                      : hasDownloadPopup
                      ? controller.toggleDownloadPopup
                      : () => _activate(context),
                  customBorder: const StadiumBorder(),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 40,
                      maxHeight: 44,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if ((isChecking || isDownloadRunning) &&
                              !reduceAnimations)
                            SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                key: isDownloadRunning
                                    ? const ValueKey(
                                        'windows-update-download-indicator-spinner',
                                      )
                                    : null,
                                strokeWidth: 2,
                                color: presentation.foreground,
                              ),
                            )
                          else if (isDownloadRunning)
                            Icon(
                              Icons.downloading_rounded,
                              key: const ValueKey(
                                'windows-update-download-indicator-static',
                              ),
                              size: 17,
                              color: presentation.foreground,
                            )
                          else if (hasDownloadPopup)
                            Icon(
                              switch (controller.downloadState) {
                                WindowsUpdateDownloadState.completed =>
                                  Icons.check_circle_outline_rounded,
                                WindowsUpdateDownloadState.cancelled =>
                                  Icons.download_done_rounded,
                                WindowsUpdateDownloadState.failed =>
                                  Icons.error_outline_rounded,
                                _ => presentation.icon,
                              },
                              size: 17,
                              color: presentation.foreground,
                            )
                          else
                            Icon(
                              isChecking ? AppIcons.refresh : presentation.icon,
                              size: 17,
                              color: presentation.foreground,
                            ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              presentation.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: presentation.foreground,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  _WindowsUpdatePresentation _presentation(
    BuildContext context,
    WindowsUpdateIndicatorController controller,
  ) {
    final release = controller.latestAvailableRelease;
    return switch (controller.state) {
      WindowsUpdateIndicatorState.checking => const _WindowsUpdatePresentation(
        label: 'Buscando actualizaciones...',
        semanticLabel: 'Buscando actualizaciones.',
        icon: AppIcons.refresh,
        background: Color(0xFFF0EFE8),
        foreground: Color(0xFF686B5D),
        border: Color(0xFFDCDDD2),
      ),
      WindowsUpdateIndicatorState.upToDate => const _WindowsUpdatePresentation(
        label: 'Aplicación actualizada',
        semanticLabel: 'Aplicación actualizada. Comprobar de nuevo.',
        icon: AppIcons.success,
        background: Color(0xFFE8EFE2),
        foreground: Color(0xFF4E693A),
        border: Color(0xFFD3DFCA),
      ),
      WindowsUpdateIndicatorState.updateAvailable => _WindowsUpdatePresentation(
        label: 'Nueva versión ${release?.version ?? ''}',
        semanticLabel:
            'Nueva versión ${release?.version ?? 'disponible'}. Ver detalles.',
        icon: AppIcons.downloadArrow,
        background: const Color(0xFF687654),
        foreground: Colors.white,
        border: const Color(0xFF687654),
      ),
      WindowsUpdateIndicatorState.error => const _WindowsUpdatePresentation(
        label: 'No se pudo comprobar',
        semanticLabel: 'No se pudo comprobar. Reintentar.',
        icon: Icons.cloud_off_outlined,
        background: Color(0xFFEEEEE9),
        foreground: Color(0xFF686B66),
        border: Color(0xFFDADBD4),
      ),
    };
  }
}

class _WindowsUpdatePresentation {
  const _WindowsUpdatePresentation({
    required this.label,
    required this.semanticLabel,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.border,
  });

  final String label;
  final String semanticLabel;
  final IconData icon;
  final Color background;
  final Color foreground;
  final Color border;
}
