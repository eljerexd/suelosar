import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:suelosar/repositories/santa_fe_series_repository.dart';
import 'package:suelosar/screens/pdf_viewer_screen.dart';

/// Real-device verification (Santa Fe Fase 1, sección 8): opens the actual
/// consolidated PDF asset through pdfrx's real native decoder — no mocks —
/// and confirms it settles on the exact physical page the audited index
/// says each series starts at.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final repository = SantaFeSeriesRepository();

  Future<void> verifyOpensAtStartPage(
    WidgetTester tester,
    String code,
  ) async {
    final entry = await repository.findByCode(code);
    expect(entry, isNotNull, reason: '$code must resolve via the real index');

    final pdfAsset = await repository.pdfAsset;
    final observedPages = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewerScreen(
          title: entry!.name,
          assetPath: pdfAsset,
          initialPage: entry.startPage,
          lastPage: entry.endPage,
          onPageChanged: observedPages.add,
        ),
      ),
    );

    // Real PDF decoding + layout on a 3.2MB / 640-page document — give it
    // real time on-device rather than a fixed short pump.
    for (var i = 0; i < 80 && !observedPages.contains(entry.startPage); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
    }

    expect(
      observedPages,
      contains(entry.startPage),
      reason:
          'PdfViewerScreen never reported reaching physical page '
          '${entry.startPage} for $code (${entry.name})',
    );
  }

  testWidgets('Rafaela (RAF) opens at its audited physical start page', (
    tester,
  ) async {
    await verifyOpensAtStartPage(tester, 'RAF');
  });

  testWidgets('María Luisa (MLA) opens at its audited physical start page', (
    tester,
  ) async {
    await verifyOpensAtStartPage(tester, 'MLA');
  });

  testWidgets('Petronila (PEA) opens at its audited physical start page', (
    tester,
  ) async {
    await verifyOpensAtStartPage(tester, 'PEA');
  });

  testWidgets('Río Salado (RSA) opens at its audited physical start page', (
    tester,
  ) async {
    await verifyOpensAtStartPage(tester, 'RSA');
  });

  testWidgets('Cululú (CUL) opens at its audited physical start page', (
    tester,
  ) async {
    await verifyOpensAtStartPage(tester, 'CUL');
  });
}
