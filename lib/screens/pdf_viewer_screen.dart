import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app/instant_pop_material_page_route.dart';
import '../utils/app_motion.dart';
import '../widgets/app_notification.dart';
import '../widgets/responsive_desktop_shell.dart';

final Future<Set<String>> _bundledAssetPaths =
    AssetManifest.loadFromAssetBundle(
      rootBundle,
    ).then((manifest) => manifest.listAssets().toSet());

class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    required this.title,
    required this.assetPath,
    super.key,
  });

  final String title;
  final String assetPath;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  static const double _minimumZoom = 0.25;
  static const double _maximumZoom = 5;
  static const double _zoomStep = 0.25;

  late final PdfViewerController _pdfController;
  final ValueNotifier<double> _zoomLevel = ValueNotifier<double>(1);
  final ValueNotifier<bool> _mobileScrollbarVisible = ValueNotifier<bool>(
    false,
  );
  Timer? _mobileScrollbarHideTimer;

  @override
  void initState() {
    super.initState();
    _pdfController = PdfViewerController()
      ..addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    _pdfController.removeListener(_handleControllerChanged);
    _mobileScrollbarHideTimer?.cancel();
    _zoomLevel.dispose();
    _mobileScrollbarVisible.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!_pdfController.isReady) return;
    final zoom = _pdfController.currentZoom;
    if (zoom.isFinite && (_zoomLevel.value - zoom).abs() >= 0.001) {
      _zoomLevel.value = zoom;
    }
    if (_usesAutoHideScrollbar) {
      _mobileScrollbarVisible.value = true;
      _mobileScrollbarHideTimer?.cancel();
      _mobileScrollbarHideTimer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) _mobileScrollbarVisible.value = false;
      });
    }
  }

  bool get _usesAutoHideScrollbar =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _animateZoomTo(double requestedZoom) async {
    if (!_pdfController.isReady) return;
    final target = requestedZoom.clamp(_minimumZoom, _maximumZoom).toDouble();
    if ((target - _pdfController.currentZoom).abs() < 0.001) return;
    await _pdfController.setZoom(
      _pdfController.centerPosition,
      target,
      duration: AppMotion.duration(context, const Duration(milliseconds: 180)),
    );
  }

  void _zoomIn() => unawaited(_animateZoomTo(_zoomLevel.value + _zoomStep));

  void _zoomOut() => unawaited(_animateZoomTo(_zoomLevel.value - _zoomStep));

  void _restoreInitialZoom() => unawaited(_fitRecommended());

  void _fitWidth() => unawaited(_fitCurrentPage(fitWidth: true));

  Future<void> _fitRecommended() async {
    if (!_pdfController.isReady || _pdfController.pages.isEmpty) return;
    final pageNumber = _pdfController.pageNumber ?? 1;
    final page = _pdfController.pages[pageNumber - 1];
    await _fitCurrentPage(fitWidth: page.width <= page.height);
  }

  Future<void> _fitCurrentPage({required bool fitWidth}) async {
    if (!_pdfController.isReady) return;
    final pageNumber = _pdfController.pageNumber ?? 1;
    final matrix = fitWidth
        ? _pdfController.calcMatrixFitWidthForPage(pageNumber: pageNumber)
        : _pdfController.calcMatrixForFit(pageNumber: pageNumber);
    await _pdfController.goTo(
      matrix,
      duration: AppMotion.duration(context, const Duration(milliseconds: 180)),
    );
  }

  Widget _buildScrollThumb(
    BuildContext context,
    Size thumbSize, {
    required bool desktop,
  }) {
    final color = Theme.of(
      context,
    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.62);
    final thumb = Center(
      child: SizedBox(
        width: 4,
        height: thumbSize.height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
    if (desktop) return thumb;
    return ValueListenableBuilder<bool>(
      valueListenable: _mobileScrollbarVisible,
      builder: (context, visible, child) => AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 160),
        ),
        child: child,
      ),
      child: thumb,
    );
  }

  Widget _buildViewer({required bool desktop}) {
    final showScrollThumb = desktop || _usesAutoHideScrollbar;
    return PdfViewer.asset(
      widget.assetPath,
      controller: _pdfController,
      params: PdfViewerParams(
        backgroundColor: const Color(0xFFF5F5F5),
        underflowAnchor: PdfPageAnchor.center,
        sizeDelegateProvider: _SuelosArPdfSizeDelegateProvider(
          desktop: desktop,
        ),
        onViewerReady: (_, _) => _handleControllerChanged(),
        viewerOverlayBuilder: showScrollThumb
            ? (context, _, _) => [
                PdfViewerScrollThumb(
                  controller: _pdfController,
                  orientation: ScrollbarOrientation.right,
                  thumbSize: const Size(12, 64),
                  margin: 4,
                  thumbBuilder: (context, size, _, _) =>
                      _buildScrollThumb(context, size, desktop: desktop),
                ),
              ]
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = isSuelosArDesktopPlatform(context);
    final viewer = _buildViewer(desktop: desktop);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: desktop
          ? CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.digit0, control: true):
                    _restoreInitialZoom,
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(
                    color: Color(0xFFF5F5F5),
                    child: SizedBox.expand(),
                  ),
                  viewer,
                  Positioned(
                    right: 20,
                    bottom: 20,
                    child: _DesktopPdfZoomControls(
                      zoomLevel: _zoomLevel,
                      onZoomOut: _zoomOut,
                      onZoomIn: _zoomIn,
                      onFitWidth: _fitWidth,
                    ),
                  ),
                ],
              ),
            )
          : viewer,
    );
  }
}

class _SuelosArPdfSizeDelegateProvider extends PdfViewerSizeDelegateProvider {
  const _SuelosArPdfSizeDelegateProvider({required this.desktop});

  final bool desktop;

  @override
  PdfViewerSizeDelegate create() => _SuelosArPdfSizeDelegate(desktop: desktop);

  @override
  bool operator ==(Object other) =>
      other is _SuelosArPdfSizeDelegateProvider && other.desktop == desktop;

  @override
  int get hashCode => desktop.hashCode;
}

class _SuelosArPdfSizeDelegate extends PdfViewerSizeDelegateSmart {
  _SuelosArPdfSizeDelegate({required this.desktop})
    : super(
        minScale: desktop ? 0.25 : 0.01,
        maxScale: desktop ? 5 : 3,
        smartMaxScale: desktop ? 5 : 3,
        maxPagesVisible: 1,
        onePassRenderingScaleThreshold: 200 / 72,
      );

  final bool desktop;
  PdfViewerController? _controller;

  static const double _desktopMinimumZoom = 0.25;
  static const double _desktopMaximumZoom = 5;
  static const double _mobileMaximumZoom = 3;
  static const double _desktopInitialScaleFactor = 0.9;

  @override
  void init(PdfViewerController controller) {
    super.init(controller);
    _controller = controller;
  }

  @override
  void dispose() {
    _controller = null;
    super.dispose();
  }

  @override
  PdfViewerLayoutMetrics calculateMetrics({
    required Size viewSize,
    required PdfPageLayout? layout,
    required int? pageNumber,
    required double pageMargin,
    required EdgeInsets? boundaryMargin,
  }) {
    final base = super.calculateMetrics(
      viewSize: viewSize,
      layout: layout,
      pageNumber: pageNumber,
      pageMargin: pageMargin,
      boundaryMargin: boundaryMargin,
    );
    if (desktop || layout == null || layout.pageLayouts.isEmpty) {
      return PdfViewerLayoutMetrics(
        minScale: desktop ? _desktopMinimumZoom : base.minScale,
        maxScale: desktop ? _desktopMaximumZoom : _mobileMaximumZoom,
        coverScale: base.coverScale,
        alternativeFitScale: base.alternativeFitScale,
      );
    }

    final page = layout.pageLayouts.first;
    final openingScale = _openingScale(
      viewSize: viewSize,
      page: page,
      pageMargin: pageMargin,
      boundaryMargin: boundaryMargin,
    ).clamp(0.01, _mobileMaximumZoom).toDouble();
    return PdfViewerLayoutMetrics(
      minScale: openingScale,
      maxScale: _mobileMaximumZoom,
      coverScale: base.coverScale,
      alternativeFitScale: base.alternativeFitScale,
    );
  }

  @override
  void onLayoutInitialized({
    required PdfViewerLayoutSnapshot state,
    required int initialPageNumber,
    required double coverScale,
    required double? alternativeFitScale,
    required PdfPageLayout layout,
    required PdfDocument document,
  }) {
    final controller = _controller;
    if (controller == null || document.pages.isEmpty) return;
    final pageIndex = (initialPageNumber - 1).clamp(
      0,
      document.pages.length - 1,
    );
    final page = document.pages[pageIndex];
    final fittedScale = page.width > page.height
        ? alternativeFitScale ?? coverScale
        : coverScale;
    final initialScale = desktop
        ? (fittedScale * _desktopInitialScaleFactor).clamp(
            _desktopMinimumZoom,
            _desktopMaximumZoom,
          )
        : fittedScale.clamp(state.minScale, _mobileMaximumZoom);
    unawaited(
      controller.setZoom(
        Offset.zero,
        initialScale.toDouble(),
        duration: Duration.zero,
      ),
    );
  }

  static double _openingScale({
    required Size viewSize,
    required Rect page,
    required double pageMargin,
    required EdgeInsets? boundaryMargin,
  }) {
    final horizontalBoundary =
        boundaryMargin == null || boundaryMargin.horizontal.isInfinite
        ? 0.0
        : boundaryMargin.horizontal;
    final verticalBoundary =
        boundaryMargin == null || boundaryMargin.vertical.isInfinite
        ? 0.0
        : boundaryMargin.vertical;
    final horizontalScale =
        viewSize.width / (page.width + horizontalBoundary + pageMargin * 2);
    if (page.width <= page.height) return horizontalScale;
    final verticalScale =
        viewSize.height / (page.height + verticalBoundary + pageMargin * 2);
    return math.min(horizontalScale, verticalScale);
  }
}

class _DesktopPdfZoomControls extends StatelessWidget {
  const _DesktopPdfZoomControls({
    required this.zoomLevel,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFitWidth,
  });

  final ValueListenable<double> zoomLevel;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onFitWidth;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      elevation: 5,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.22),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 200,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Alejar',
              onPressed: onZoomOut,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: ValueListenableBuilder<double>(
                valueListenable: zoomLevel,
                builder: (context, value, _) => Text(
                  '${(value * 100).round()}%',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Acercar',
              onPressed: onZoomIn,
              icon: const Icon(Icons.add),
            ),
            SizedBox(
              height: 24,
              child: VerticalDivider(
                width: 1,
                color: colorScheme.outlineVariant,
              ),
            ),
            IconButton(
              tooltip: 'Ajustar al ancho',
              onPressed: onFitWidth,
              icon: const Icon(Icons.fit_screen),
            ),
          ],
        ),
      ),
    );
  }
}

Future<bool> openLocalPdfViewer(
  BuildContext context, {
  required String title,
  required String assetPath,
  required String unavailableMessage,
}) async {
  if (isSuelosArCompactAndroidPortrait(context)) {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }
  final availableAssets = await _bundledAssetPaths;
  if (!availableAssets.contains(assetPath)) {
    if (context.mounted) {
      AppNotification.show(
        context,
        message: unavailableMessage,
        type: AppNotificationType.error,
      );
    }
    return false;
  }

  if (!context.mounted) return false;
  await Navigator.of(context).push(
    InstantPopMaterialPageRoute<void>(
      builder: (_) => PdfViewerScreen(title: title, assetPath: assetPath),
    ),
  );
  return true;
}
