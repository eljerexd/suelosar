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
}
