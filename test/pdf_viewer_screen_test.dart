import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:suelosar/screens/pdf_viewer_screen.dart';

void main() {
  const assetPath = 'assets/pdfs/Junín.pdf';

  testWidgets('desktop PDF viewer shows zoom controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const PdfViewerScreen(title: 'Junín', assetPath: assetPath),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byTooltip('Alejar'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data?.endsWith('%') ?? false),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Acercar'), findsOneWidget);
    expect(find.byTooltip('Ajustar al ancho'), findsOneWidget);
    expect(find.text('Ajustar al ancho'), findsNothing);
    expect(
      find.ancestor(
        of: find.byType(PdfViewer),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byType(PdfViewer),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
    expect(viewer.params.backgroundColor, const Color(0xFFF5F5F5));
    expect(viewer.params.underflowAnchor, PdfPageAnchor.center);
    expect(viewer.params.viewerOverlayBuilder, isNotNull);
    final sizeDelegate = viewer.params.sizeDelegateProvider!.create();
    final metrics = sizeDelegate.calculateMetrics(
      viewSize: const Size(1200, 800),
      layout: PdfPageLayout(
        pageLayouts: const [Rect.fromLTWH(8, 8, 600, 800)],
        documentSize: const Size(616, 816),
      ),
      pageNumber: 1,
      pageMargin: 8,
      boundaryMargin: null,
    );
    expect(metrics.minScale, 0.25);
    expect(metrics.maxScale, 5);
    sizeDelegate.dispose();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Alejar'),
      ),
      findsNothing,
    );
  });

  testWidgets('mobile PDF viewer keeps desktop zoom controls hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const PdfViewerScreen(title: 'Junín', assetPath: assetPath),
      ),
    );

    expect(find.byTooltip('Alejar'), findsNothing);
    expect(find.text('100%'), findsNothing);
    expect(find.byTooltip('Acercar'), findsNothing);
    expect(find.byTooltip('Ajustar al ancho'), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));

    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
    expect(viewer.params.viewerOverlayBuilder, isNotNull);
    final sizeDelegate = viewer.params.sizeDelegateProvider!.create();
    final metrics = sizeDelegate.calculateMetrics(
      viewSize: const Size(400, 700),
      layout: PdfPageLayout(
        pageLayouts: const [Rect.fromLTWH(8, 8, 600, 800)],
        documentSize: const Size(616, 816),
      ),
      pageNumber: 1,
      pageMargin: 8,
      boundaryMargin: null,
    );
    expect(metrics.minScale, closeTo(400 / 616, 0.0001));
    expect(metrics.maxScale, 3);
    sizeDelegate.dispose();
  });

  testWidgets(
    'initialPage/lastPage are additive: omitting them keeps existing '
    'Buenos Aires behavior (no initial page jump attempted)',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const PdfViewerScreen(title: 'Junín', assetPath: assetPath),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      final screen = tester.widget<PdfViewerScreen>(
        find.byType(PdfViewerScreen),
      );
      expect(screen.initialPage, isNull);
      expect(screen.lastPage, isNull);
    },
  );

  testWidgets(
    'initialPage/lastPage/onPageChanged are stored on the widget and wired '
    'into PdfViewerParams.onPageChanged',
    (tester) async {
      final pageEvents = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: PdfViewerScreen(
            title: 'Rafaela (Santa Fe)',
            assetPath: assetPath,
            initialPage: 493,
            lastPage: 496,
            onPageChanged: pageEvents.add,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      final screen = tester.widget<PdfViewerScreen>(
        find.byType(PdfViewerScreen),
      );
      expect(screen.initialPage, 493);
      expect(screen.lastPage, 496);

      final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
      expect(viewer.params.onPageChanged, isNotNull);
      // Drive the same callback pdfrx would call on a real page change, to
      // confirm it reaches the widget's onPageChanged without needing a
      // real PDF document to load in the test harness.
      viewer.params.onPageChanged!(493);
      expect(pageEvents, [493]);
    },
  );

  testWidgets(
    'initialPage/lastPage omitted keeps normalizeMatrix null (Buenos Aires '
    'unaffected)',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const PdfViewerScreen(title: 'Junín', assetPath: assetPath),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
      expect(viewer.params.normalizeMatrix, isNull);
    },
  );

  testWidgets(
    'initialPage/lastPage clamp the pan matrix to that page range, like '
    "Santa Fe's per-series view into the consolidated PDF",
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const PdfViewerScreen(
            title: 'Rafaela (Santa Fe)',
            assetPath: assetPath,
            initialPage: 493,
            lastPage: 496,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
      final normalizeMatrix = viewer.params.normalizeMatrix;
      expect(normalizeMatrix, isNotNull);

      // A synthetic layout standing in for the consolidated PDF: pages are
      // 1-indexed, so page 493 is pageLayouts[492], matching how
      // SeriesPdfLocation.startPage/endPage flow into initialPage/lastPage
      // in lib/gis/gis_map_screen.dart.
      const pageHeight = 800.0;
      const pageWidth = 600.0;
      final pageLayouts = List<Rect>.generate(
        640,
        (i) => Rect.fromLTWH(0, i * pageHeight, pageWidth, pageHeight),
      );
      final layout = PdfPageLayout(
        pageLayouts: pageLayouts,
        documentSize: Size(pageWidth, 640 * pageHeight),
      );
      const viewSize = Size(400, 700);
      const zoom = 1.0;
      final rangeTop = pageLayouts[492].top; // page 493
      final rangeBottom = pageLayouts[495].bottom; // page 496

      Matrix4 matrixAt(Offset position) {
        final m = Matrix4.identity()..scaleByDouble(zoom, zoom, zoom, 1.0);
        m.xZoomed = -position.dx * zoom + viewSize.width / 2;
        m.yZoomed = -position.dy * zoom + viewSize.height / 2;
        return m;
      }

      // Attempt to scroll deep into page 497, outside [493, 496].
      final pastEnd = matrixAt(Offset(pageWidth / 2, pageLayouts[500].bottom));
      final clampedPastEnd = normalizeMatrix!(pastEnd, viewSize, layout, null);
      final positionPastEnd = clampedPastEnd.calcPosition(viewSize);
      expect(positionPastEnd.dy, lessThanOrEqualTo(rangeBottom + 0.5));
      expect(positionPastEnd.dy, greaterThanOrEqualTo(rangeTop - 0.5));

      // Attempt to scroll above the top of page 493, before initialPage.
      final beforeStart = matrixAt(Offset(pageWidth / 2, rangeTop - 5000));
      final clampedBeforeStart = normalizeMatrix(
        beforeStart,
        viewSize,
        layout,
        null,
      );
      final positionBeforeStart = clampedBeforeStart.calcPosition(viewSize);
      expect(positionBeforeStart.dy, greaterThanOrEqualTo(rangeTop - 0.5));
      expect(positionBeforeStart.dy, lessThanOrEqualTo(rangeBottom + 0.5));

      // A position already inside the series' own range is left untouched.
      final insideRange = matrixAt(
        Offset(pageWidth / 2, pageLayouts[493].center.dy),
      );
      final clampedInside = normalizeMatrix(insideRange, viewSize, layout, null);
      expect(clampedInside.calcPosition(viewSize).dy, insideRange.calcPosition(viewSize).dy);
    },
  );
}
