import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/app_icons.dart';
import '../../services/settings_service.dart';
import '../../utils/app_motion.dart';
import '../pmtiles_delivery.dart';
import '../province_config.dart';

const Duration _provinceTransitionDuration = Duration(milliseconds: 300);
const Duration _provinceExpansionDuration = Duration(milliseconds: 360);
const Curve _provinceTransitionCurve = Curves.easeInOutCubic;

double _expandedProvinceCardHeight(Size screenSize) =>
    mathMin(248, screenSize.height * 0.45);

Offset _provinceIndicatorVisualOffset(String id) => switch (id) {
  'santa_fe' => const Offset(39, 0),
  'cordoba' => const Offset(-15, 0),
  'buenos_aires' => const Offset(14, 0),
  _ => Offset.zero,
};

/// Data needed to display one province's on-demand download.
class ProvinceDownloadMapItem {
  const ProvinceDownloadMapItem({
    required this.id,
    required this.name,
    required this.resolveScreenPosition,
    required this.delivery,
    required this.onDownload,
    required this.metadata,
    this.sizeBytes,
  });

  final String id;
  final String name;

  /// Projects this province's geographic anchor through the current map camera.
  final Offset? Function() resolveScreenPosition;
  final PmtilesDelivery delivery;
  final VoidCallback onDownload;
  final ProvinceDownloadMetadata metadata;
  final int? sizeBytes;
}

/// Geographic province indicators projected through the live map camera.
/// Each indicator expands in place and download state remains owned by its
/// [PmtilesDelivery].
class ProvinceDownloadMapOverlay extends StatefulWidget {
  const ProvinceDownloadMapOverlay({
    super.key,
    required this.items,
    required this.cameraChanges,
    required this.onDismiss,
  });

  final List<ProvinceDownloadMapItem> items;
  final Listenable cameraChanges;
  final void Function(String id, PmtilesDeliveryStatus status) onDismiss;

  @override
  State<ProvinceDownloadMapOverlay> createState() =>
      _ProvinceDownloadMapOverlayState();
}

class _ProvinceDownloadMapOverlayState extends State<ProvinceDownloadMapOverlay>
    with SingleTickerProviderStateMixin {
  static const String _chevronHintShownKey =
      'onboarding.province_indicator_chevron_hint_shown';
  static const double _topOverlayClearance = 204;
  static const Duration _successHold = Duration(milliseconds: 620);
  static const Duration _successLeave = Duration(milliseconds: 320);
  static const Duration _chevronHintDuration = Duration(milliseconds: 2250);

  final Map<String, PmtilesDeliveryStatus> _lastStatuses = {};
  final Map<String, VoidCallback> _listeners = {};
  String? _selectedId;
  double? _selectedCardWidth;
  double _selectedHorizontalOffset = 0;
  bool _selectedExpandUp = false;
  bool _showSuccess = false;
  bool _isLeaving = false;
  bool _isCollapsing = false;
  bool _chevronHintDecisionStarted = false;
  late final AnimationController _chevronHintController;
  late final Animation<double> _chevronOffset;
  Timer? _transitionTimer;

  @override
  void initState() {
    super.initState();
    _chevronHintController = AnimationController(
      vsync: this,
      duration: _chevronHintDuration,
    );
    _chevronOffset = _chevronHintController.drive(
      TweenSequence<double>([
        for (var pulse = 0; pulse < 3; pulse++) ...[
          TweenSequenceItem(
            tween: Tween<double>(
              begin: 0,
              end: 7.5,
            ).chain(CurveTween(curve: Curves.easeInOut)),
            weight: 12,
          ),
          TweenSequenceItem(
            tween: Tween<double>(
              begin: 7.5,
              end: 0,
            ).chain(CurveTween(curve: Curves.easeInOut)),
            weight: 12,
          ),
          TweenSequenceItem(tween: ConstantTween<double>(0), weight: 8),
        ],
      ]),
    );
    _syncDeliveryListeners(const []);
  }

  void _maybePlayChevronHint(BuildContext context, Size screenSize) {
    if (_chevronHintDecisionStarted ||
        !_hasVisibleCompactIndicator(screenSize)) {
      return;
    }
    _chevronHintDecisionStarted = true;
    unawaited(
      _loadAndPlayChevronHint(MediaQuery.disableAnimationsOf(context), context),
    );
  }

  bool _hasVisibleCompactIndicator(Size screenSize) {
    for (final item in widget.items) {
      if (item.id == _selectedId ||
          item.delivery.status == PmtilesDeliveryStatus.available) {
        continue;
      }
      final projectedAnchor = item.resolveScreenPosition();
      final anchor = projectedAnchor == null
          ? null
          : projectedAnchor + _provinceIndicatorVisualOffset(item.id);
      if (anchor == null || !anchor.dx.isFinite || !anchor.dy.isFinite) {
        continue;
      }
      final compactRect = Rect.fromLTWH(
        anchor.dx - 84,
        anchor.dy - 22,
        168,
        44,
      );
      if (_edgeOpacity(compactRect, screenSize) > 0) return true;
    }
    return false;
  }

  Future<void> _loadAndPlayChevronHint(
    bool reduceForAccessibility,
    BuildContext context,
  ) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (preferences.getBool(_chevronHintShownKey) == true) return;
      if (!mounted || !context.mounted) return;
      if (!_hasVisibleCompactIndicator(MediaQuery.sizeOf(context))) {
        _chevronHintDecisionStarted = false;
        return;
      }

      if (reduceForAccessibility || SettingsService.instance.reduceAnimations) {
        await preferences.setBool(_chevronHintShownKey, true);
        return;
      }

      // Persist before animation so an interruption cannot replay the hint.
      final persisted = await preferences.setBool(_chevronHintShownKey, true);
      if (!persisted || !mounted || !context.mounted) return;
      if (!_hasVisibleCompactIndicator(MediaQuery.sizeOf(context))) {
        await preferences.setBool(_chevronHintShownKey, false);
        _chevronHintDecisionStarted = false;
        setState(() {});
        return;
      }
      _chevronHintController.forward();
    } catch (_) {
      // Fail closed if the preference store is unavailable.
    }
  }

  @override
  void didUpdateWidget(covariant ProvinceDownloadMapOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDeliveryListeners(oldWidget.items);
    if (!_containsSelectedItem) {
      _cancelTransition();
      _selectedId = null;
      _selectedCardWidth = null;
      _selectedHorizontalOffset = 0;
      _selectedExpandUp = false;
      _showSuccess = false;
      _isLeaving = false;
      _isCollapsing = false;
    }
  }

  bool get _containsSelectedItem =>
      _selectedId == null || widget.items.any((item) => item.id == _selectedId);

  void _syncDeliveryListeners(List<ProvinceDownloadMapItem> oldItems) {
    final currentById = {for (final item in widget.items) item.id: item};
    for (final oldItem in oldItems) {
      final current = currentById[oldItem.id];
      if (current == null || !identical(current.delivery, oldItem.delivery)) {
        final listener = _listeners.remove(oldItem.id);
        if (listener != null) oldItem.delivery.removeListener(listener);
        _lastStatuses.remove(oldItem.id);
      }
    }
    for (final item in widget.items) {
      if (_listeners.containsKey(item.id)) continue;
      _lastStatuses[item.id] = item.delivery.status;
      void listener() => _handleDeliveryChanged(item.id, item.delivery);
      _listeners[item.id] = listener;
      item.delivery.addListener(listener);
    }
  }

  void _handleDeliveryChanged(String id, PmtilesDelivery delivery) {
    if (!mounted) return;
    final previous = _lastStatuses[id];
    final current = delivery.status;
    _lastStatuses[id] = current;
    if (_selectedId == id &&
        !_isLeaving &&
        !_isCollapsing &&
        !_showSuccess &&
        previous != PmtilesDeliveryStatus.available &&
        current == PmtilesDeliveryStatus.available) {
      _startSuccessTransition();
      return;
    }
    setState(() {});
  }

  void _select(String id) {
    if (_selectedId == id) {
      if (_isLeaving && _showSuccess) return;
      if (_isCollapsing) {
        _cancelTransition();
        setState(() => _isCollapsing = false);
        return;
      }
      _cancelTransition();
      if (_isLeaving) {
        setState(() => _isLeaving = false);
        return;
      }
      _closeSelected(persistDismissal: true);
      return;
    }
    if (_isCollapsing && _selectedId != null) {
      final closingId = _selectedId!;
      final closingStatus = widget.items
          .firstWhere((candidate) => candidate.id == closingId)
          .delivery
          .status;
      widget.onDismiss(closingId, closingStatus);
    }
    _cancelTransition();
    final screenSize = MediaQuery.sizeOf(context);
    final projectedAnchor = widget.items
        .firstWhere((candidate) => candidate.id == id)
        .resolveScreenPosition();
    final anchor = projectedAnchor == null
        ? null
        : projectedAnchor + _provinceIndicatorVisualOffset(id);
    final maxCardHeight = _expandedProvinceCardHeight(screenSize);
    const horizontalMargin = 12.0;
    final maxWidth = mathMin(288, screenSize.width - 24);
    final centeredRoom = anchor == null
        ? maxWidth
        : 2 *
              mathMin(
                anchor.dx - horizontalMargin,
                screenSize.width - horizontalMargin - anchor.dx,
              );
    final minimumCardWidth = mathMin(192, maxWidth);
    final selectedWidth = mathMin(
      maxWidth,
      mathMax(minimumCardWidth, centeredRoom),
    );
    final idealLeft = (anchor?.dx ?? screenSize.width / 2) - selectedWidth / 2;
    final boundedLeft = idealLeft.clamp(
      horizontalMargin,
      screenSize.width - horizontalMargin - selectedWidth,
    );
    setState(() {
      _selectedId = id;
      _selectedCardWidth = selectedWidth;
      _selectedHorizontalOffset = boundedLeft - (anchor?.dx ?? 0);
      _selectedExpandUp =
          anchor != null && anchor.dy > screenSize.height - maxCardHeight - 22;
      _showSuccess = false;
      _isLeaving = false;
      _isCollapsing = false;
    });
  }

  void _closeSelected({required bool persistDismissal}) {
    final id = _selectedId;
    if (id == null || _isLeaving) return;
    final item = widget.items.firstWhere((candidate) => candidate.id == id);
    final status = item.delivery.status;
    setState(() => _isCollapsing = true);
    final duration = AppMotion.duration(context, _provinceTransitionDuration);
    _transitionTimer = Timer(duration, () {
      if (!mounted) return;
      if (persistDismissal) widget.onDismiss(id, status);
      setState(() {
        _selectedId = null;
        _selectedCardWidth = null;
        _selectedHorizontalOffset = 0;
        _selectedExpandUp = false;
        _showSuccess = false;
        _isLeaving = false;
        _isCollapsing = false;
      });
    });
  }

  void _startSuccessTransition() {
    setState(() {
      _showSuccess = true;
      _isLeaving = false;
      _isCollapsing = false;
    });
    _transitionTimer?.cancel();
    _transitionTimer = Timer(_successHold, () {
      if (!mounted) return;
      setState(() => _isLeaving = true);
      final duration = AppMotion.duration(context, _successLeave);
      _transitionTimer = Timer(duration, () {
        if (!mounted) return;
        setState(() {
          _selectedId = null;
          _selectedCardWidth = null;
          _selectedHorizontalOffset = 0;
          _selectedExpandUp = false;
          _showSuccess = false;
          _isLeaving = false;
          _isCollapsing = false;
        });
      });
    });
  }

  void _cancelTransition() {
    _transitionTimer?.cancel();
    _transitionTimer = null;
  }

  @override
  void dispose() {
    _cancelTransition();
    _chevronHintController.dispose();
    for (final item in widget.items) {
      final listener = _listeners[item.id];
      if (listener != null) item.delivery.removeListener(listener);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.cameraChanges,
      builder: (context, child) {
        final size = MediaQuery.sizeOf(context);
        _maybePlayChevronHint(context, size);
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            for (final item in widget.items)
              if (item.delivery.status != PmtilesDeliveryStatus.available ||
                  item.id == _selectedId)
                _positionIndicator(item, size),
          ],
        );
      },
    );
  }

  Widget _positionIndicator(ProvinceDownloadMapItem item, Size screenSize) {
    final projectedAnchor = item.resolveScreenPosition();
    if (projectedAnchor == null ||
        !projectedAnchor.dx.isFinite ||
        !projectedAnchor.dy.isFinite) {
      return const SizedBox.shrink();
    }
    final anchor = projectedAnchor + _provinceIndicatorVisualOffset(item.id);
    final centerX = anchor.dx;
    final centerY = anchor.dy;
    final hasSelectedFrame = item.id == _selectedId;
    final selected = hasSelectedFrame && !_isCollapsing;
    final maxWidth = mathMin(332, screenSize.width - 24);
    final maxCardHeight = _expandedProvinceCardHeight(screenSize);
    final expandUp = hasSelectedFrame && _selectedExpandUp;
    final cardWidth = hasSelectedFrame
        ? mathMin(_selectedCardWidth ?? mathMin(288, maxWidth), maxWidth)
        : null;
    final selectedLeft = centerX + _selectedHorizontalOffset;
    final contentHeight = hasSelectedFrame ? maxCardHeight : 44.0;
    final visibleRect = Rect.fromLTWH(
      hasSelectedFrame ? selectedLeft : centerX - 84,
      hasSelectedFrame
          ? expandUp
                ? centerY + 25 - contentHeight
                : centerY - 25
          : centerY - 22,
      hasSelectedFrame ? cardWidth! : 168,
      contentHeight,
    );
    final edgeOpacity = _edgeOpacity(visibleRect, screenSize);
    final frameLeft = hasSelectedFrame && !_isCollapsing
        ? selectedLeft - (maxWidth - cardWidth!) / 2
        : centerX - maxWidth / 2;
    final frameTop = hasSelectedFrame
        ? expandUp
              ? centerY + (_isCollapsing ? 22 : 25) - maxCardHeight
              : centerY - (_isCollapsing ? 22 : 25)
        : centerY - maxCardHeight / 2;
    return AnimatedPositioned(
      key: ValueKey('province-download-card-position-${item.id}'),
      duration: _isCollapsing
          ? AppMotion.duration(context, _provinceTransitionDuration)
          : Duration.zero,
      curve: _isCollapsing ? _provinceTransitionCurve : Curves.easeOutCubic,
      left: frameLeft,
      top: frameTop,
      child: SizedBox(
        width: maxWidth,
        height: maxCardHeight,
        child: IgnorePointer(
          ignoring: edgeOpacity < 0.45,
          child: Opacity(
            opacity: edgeOpacity,
            child: Align(
              alignment: hasSelectedFrame
                  ? expandUp
                        ? Alignment.bottomCenter
                        : Alignment.topCenter
                  : Alignment.center,
              child: _ProvinceDownloadIndicator(
                key: ValueKey('province-download-indicator-${item.id}'),
                item: item,
                selected: selected,
                expandUp: expandUp,
                maxWidth: maxWidth,
                selectedWidth: cardWidth,
                isLeaving: selected && _isLeaving,
                showSuccess: selected && _showSuccess,
                isCollapsing: _isCollapsing && item.id == _selectedId,
                chevronOffset: _chevronOffset,
                onTap: () => _select(item.id),
                onClose: () => _closeSelected(persistDismissal: true),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _edgeOpacity(Rect rect, Size screenSize) {
    final clippedDistance = mathMax(
      mathMax(
        mathMax(0, -rect.left),
        mathMax(0, _topOverlayClearance - rect.top),
      ),
      mathMax(
        mathMax(0, rect.right - screenSize.width),
        mathMax(
          mathMax(0, -rect.top),
          mathMax(0, rect.bottom - screenSize.height),
        ),
      ),
    );
    return (1 - clippedDistance / 56).clamp(0.0, 1.0).toDouble();
  }
}

class _ProvinceDownloadIndicator extends StatelessWidget {
  const _ProvinceDownloadIndicator({
    super.key,
    required this.item,
    required this.selected,
    required this.expandUp,
    required this.maxWidth,
    required this.selectedWidth,
    required this.isLeaving,
    required this.showSuccess,
    required this.isCollapsing,
    required this.chevronOffset,
    required this.onTap,
    required this.onClose,
  });

  final ProvinceDownloadMapItem item;
  final bool selected;
  final bool expandUp;
  final double maxWidth;
  final double? selectedWidth;
  final bool isLeaving;
  final bool showSuccess;
  final bool isCollapsing;
  final Animation<double> chevronOffset;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = colors.primary;
    final headerSelected = selected || (isCollapsing && !expandUp);
    final keepExpandedOrder = selected || isCollapsing;
    final compactWidth = _compactIndicatorWidth(context, item, maxWidth);
    final isDownloading =
        item.delivery.status == PmtilesDeliveryStatus.downloading;
    final isAvailable = item.delivery.status == PmtilesDeliveryStatus.available;
    final details = selected || isCollapsing
        ? SizedBox(
            width: mathMax(0, selectedWidth! - 27),
            child: Padding(
              padding: expandUp
                  ? const EdgeInsets.only(top: 40)
                  : EdgeInsets.zero,
              child: _ProvinceDownloadDetails(
                item: item,
                isDownloading: isDownloading,
                isAvailable: isAvailable,
                showSuccess: showSuccess,
                maxWidth: selectedWidth!,
              ),
            ),
          )
        : const SizedBox.shrink();
    final motionDuration = AppMotion.duration(
      context,
      isCollapsing ? _provinceTransitionDuration : _provinceExpansionDuration,
      reduced: const Duration(milliseconds: 1),
    );
    final motionCurve = _provinceTransitionCurve;
    Widget closeButton() => SizedBox(
      key: const ValueKey('close-control'),
      width: 40,
      height: 40,
      child: IconButton(
        key: ValueKey('province-download-card-close-${item.id}'),
        tooltip: 'Cerrar opciones de descarga',
        visualDensity: VisualDensity.standard,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        onPressed: onClose,
        icon: Icon(AppIcons.close, size: 16, color: colors.onSurfaceVariant),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '${item.name}, ${_formatDownloadSize(item.sizeBytes)}',
      hint: selected ? 'Cerrar opciones' : 'Ver opciones de descarga',
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: isLeaving ? 0 : 1,
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 160),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('province-download-indicator-tap-${item.id}'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(selected ? 18 : 24),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(
                begin: selectedWidth ?? compactWidth,
                end: selected ? selectedWidth! : compactWidth,
              ),
              duration: isCollapsing ? motionDuration : Duration.zero,
              curve: motionCurve,
              builder: (context, width, child) =>
                  SizedBox(width: selected ? null : width, child: child),
              child: AnimatedContainer(
                key: ValueKey('province-download-card-${item.id}'),
                duration: motionDuration,
                curve: motionCurve,
                constraints: BoxConstraints(
                  minHeight: 44,
                  maxWidth: maxWidth,
                  maxHeight: _expandedProvinceCardHeight(
                    MediaQuery.sizeOf(context),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(selected ? 18 : 24),
                  border: Border.all(
                    color: selected
                        ? accent.withValues(alpha: 0.38)
                        : colors.outlineVariant,
                    width: selected ? 1 : 0.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: 0.11),
                      blurRadius: 7,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: AnimatedSize(
                  duration: motionDuration,
                  curve: motionCurve,
                  alignment: isCollapsing
                      ? expandUp
                            ? Alignment.bottomLeft
                            : Alignment.topLeft
                      : expandUp
                      ? Alignment.bottomCenter
                      : Alignment.topCenter,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final header = _ProvinceIndicatorHeader(
                        item: item,
                        selected: headerSelected,
                        showClose: !expandUp,
                        isCollapsing: isCollapsing,
                        transitionDuration: motionDuration,
                        contentWidth: headerSelected
                            ? mathMin(
                                mathMax(0, selectedWidth! - 27),
                                constraints.maxWidth,
                              )
                            : null,
                        chevronOffset: chevronOffset,
                        onClose: onClose,
                      );
                      final revealedDetails = IgnorePointer(
                        ignoring: !selected,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: selected ? 1 : 0),
                          duration: motionDuration,
                          curve: motionCurve,
                          builder: (context, reveal, child) => ClipRect(
                            child: Align(
                              alignment: Alignment.topCenter,
                              widthFactor: 1,
                              heightFactor: reveal,
                              child: Opacity(
                                key: ValueKey(
                                  'province-download-content-reveal-${item.id}',
                                ),
                                opacity: reveal,
                                child: child,
                              ),
                            ),
                          ),
                          child: details,
                        ),
                      );
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (expandUp && keepExpandedOrder) ...[
                            Stack(
                              children: [
                                revealedDetails,
                                if (selected)
                                  Positioned(
                                    top: 0,
                                    right: 0,
                                    child: closeButton(),
                                  ),
                              ],
                            ),
                            header,
                          ] else ...[
                            header,
                            revealedDetails,
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double _compactIndicatorWidth(
  BuildContext context,
  ProvinceDownloadMapItem item,
  double maxWidth,
) {
  final textTheme = Theme.of(context).textTheme;
  final titleStyle = textTheme.labelMedium?.copyWith(
    fontWeight: FontWeight.w600,
  );
  final sizeStyle = textTheme.labelSmall?.copyWith(height: 1.05);
  double measure(String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout(maxWidth: maxWidth);
    return painter.width;
  }

  final textWidth = mathMax(
    measure(item.name, titleStyle),
    measure(_formatDownloadSize(item.sizeBytes), sizeStyle),
  );
  const compactChromeWidth = 19 + 7 + 5 + 18 + 24 + 1.6;
  return mathMin(maxWidth, compactChromeWidth + textWidth);
}

class _ProvinceIndicatorHeader extends StatelessWidget {
  const _ProvinceIndicatorHeader({
    required this.item,
    required this.selected,
    required this.showClose,
    required this.isCollapsing,
    required this.transitionDuration,
    required this.contentWidth,
    required this.chevronOffset,
    required this.onClose,
  });

  final ProvinceDownloadMapItem item;
  final bool selected;
  final bool showClose;
  final bool isCollapsing;
  final Duration transitionDuration;
  final double? contentWidth;
  final Animation<double> chevronOffset;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final titleContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          key: ValueKey('province-download-card-title-${item.id}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
        Text(
          _formatDownloadSize(item.sizeBytes),
          key: ValueKey('province-download-card-size-${item.id}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            height: 1.05,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
    return SizedBox(
      key: ValueKey('province-download-header-${item.id}'),
      width: contentWidth,
      child: AnimatedContainer(
        height: selected ? 40 : 34,
        duration: transitionDuration,
        curve: _provinceTransitionCurve,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Row(
                mainAxisSize: selected ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  Icon(AppIcons.location, size: 19, color: colors.primary),
                  const SizedBox(width: 7),
                  if (selected)
                    Expanded(child: titleContent)
                  else
                    Flexible(fit: FlexFit.loose, child: titleContent),
                  if (!selected) const SizedBox(width: 5),
                  selected
                      ? const SizedBox(
                          key: ValueKey('close-control-space'),
                          width: 18,
                          height: 34,
                        )
                      : SizedBox(
                          key: const ValueKey('expand-control'),
                          width: 18,
                          height: 34,
                          child: Center(
                            child: AnimatedBuilder(
                              animation: chevronOffset,
                              builder: (context, child) {
                                final hintIsRunning =
                                    chevronOffset.status ==
                                    AnimationStatus.forward;
                                return Transform.translate(
                                  key: ValueKey(
                                    'province-chevron-motion-${item.id}',
                                  ),
                                  offset: Offset(0, chevronOffset.value),
                                  child: Icon(
                                    Icons.keyboard_arrow_down,
                                    size: 18,
                                    weight: hintIsRunning ? 700 : null,
                                    color: colors.onSurfaceVariant,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                ],
              ),
            ),
            if (selected && showClose && !isCollapsing)
              Positioned(
                top: 0,
                right: 0,
                child: SizedBox(
                  key: const ValueKey('close-control'),
                  width: 40,
                  height: 40,
                  child: IconButton(
                    key: ValueKey('province-download-card-close-${item.id}'),
                    tooltip: 'Cerrar opciones de descarga',
                    visualDensity: VisualDensity.standard,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                    onPressed: onClose,
                    icon: Icon(
                      AppIcons.close,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProvinceDownloadDetails extends StatelessWidget {
  const _ProvinceDownloadDetails({
    required this.item,
    required this.isDownloading,
    required this.isAvailable,
    required this.showSuccess,
    required this.maxWidth,
  });

  final ProvinceDownloadMapItem item;
  final bool isDownloading;
  final bool isAvailable;
  final bool showSuccess;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final progress = item.delivery.downloadProgress;
    final bytes = item.delivery.downloadBytes;
    final completed = showSuccess && isAvailable;
    final hasError = item.delivery.status == PmtilesDeliveryStatus.error;
    final stage = isDownloading
        ? 'progress'
        : completed
        ? 'success'
        : hasError
        ? 'error'
        : 'button';
    final stageDuration = AppMotion.duration(
      context,
      Duration(
        milliseconds: isDownloading
            ? 440
            : completed
            ? 390
            : 440,
      ),
      reduced: const Duration(milliseconds: 1),
    );
    final Widget stageContent;
    if (isDownloading) {
      stageContent = Column(
        key: const ValueKey('progress-stage'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 7),
          Text(
            'Descargando mapas...',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    key: const ValueKey('province-download-linear-progress'),
                    value: progress,
                    minHeight: 6,
                    color: colors.primary,
                    backgroundColor: colors.primary.withValues(alpha: 0.16),
                  ),
                ),
              ),
              if (progress != null) ...[
                const SizedBox(width: 8),
                Text(
                  '${(progress * 100).round()}%',
                  key: const ValueKey('province-download-percent'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
          if (bytes != null) ...[
            const SizedBox(height: 3),
            Text(
              bytes.label,
              key: const ValueKey('province-download-byte-label'),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      );
    } else if (completed) {
      stageContent = Column(
        key: const ValueKey('success-stage'),
        mainAxisSize: MainAxisSize.min,
        children: [const SizedBox(height: 10), const _AvailableAction()],
      );
    } else {
      stageContent = Column(
        key: ValueKey(hasError ? 'error-stage' : 'button-stage'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Transform.translate(
            offset: const Offset(-11, 0),
            child: Align(
              alignment: Alignment.center,
              child: SizedBox(
                width: mathMin(130, mathMax(0, maxWidth - 46)),
                height: 36,
                child: FilledButton.icon(
                  key: const ValueKey('province-download-action'),
                  onPressed: isAvailable ? null : item.onDownload,
                  icon: const Icon(AppIcons.downloadArrow, size: 16),
                  label: Text(hasError ? 'Reintentar' : 'Descargar'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    fixedSize: const Size(130, 36),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(99),
                    ),
                    textStyle: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final infoStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: colors.onSurfaceVariant,
      height: 1.1,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 0, 7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cartografía de suelos',
            key: const ValueKey('province-download-description'),
            style: infoStyle,
          ),
          Text(
            'Sin conexión tras la descarga',
            key: const ValueKey('province-download-offline'),
            style: infoStyle,
          ),
          const SizedBox(height: 3),
          AnimatedSize(
            duration: stageDuration,
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final targetWidth = isDownloading
                    ? constraints.maxWidth
                    : completed
                    ? mathMin(constraints.maxWidth, 180)
                    : mathMin(constraints.maxWidth, 130);
                return Align(
                  alignment: Alignment.center,
                  child: AnimatedContainer(
                    key: const ValueKey('province-download-stage-container'),
                    duration: stageDuration,
                    curve: Curves.easeOutCubic,
                    width: targetWidth,
                    alignment: Alignment.center,
                    child: AnimatedSwitcher(
                      duration: stageDuration,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.97,
                            end: 1,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(stage),
                        child: stageContent,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AvailableAction extends StatelessWidget {
  const _AvailableAction();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('province-download-success'),
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.check, size: 16, color: colors.onPrimaryContainer),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Disponible offline',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDownloadSize(int? bytes) {
  if (bytes == null) return 'Tamaño disponible';
  final mebibytes = bytes / (1024 * 1024);
  return '${mebibytes.toStringAsFixed(1)} MB';
}

double mathMin(num a, num b) => a < b ? a.toDouble() : b.toDouble();

double mathMax(num a, num b) => a > b ? a.toDouble() : b.toDouble();
