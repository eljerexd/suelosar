import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/services/windows_update_models.dart';
import 'package:suelosar/widgets/windows_update_availability_dialog.dart';
import 'package:suelosar/widgets/windows_update_success_dialog.dart';
import 'package:suelosar/widgets/windows_update_status_popover.dart';

void main() {
  testWidgets('success dialog shows the installed version and continues', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showWindowsUpdateSuccessDialog(
                context,
                installedVersion: '1.7.0+20',
              ),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('¡SuelosAR se actualizó!'), findsOneWidget);
    expect(
      find.text('La actualización se instaló correctamente'),
      findsOneWidget,
    );
    expect(find.text('VERSIÓN 1.7.0'), findsOneWidget);
    expect(find.text('VERSIÓN 1.7.0+20'), findsNothing);
    final checkIcon = tester.widget<Icon>(
      find.byKey(const ValueKey('windows-update-success-icon')),
    );
    expect(checkIcon.icon, Icons.check_rounded);
    expect(find.byIcon(Icons.crop_square_rounded), findsNothing);
    expect(
      find.text('Ya tenés instalada la última versión de SuelosAR'),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('windows-update-success-continue')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(WindowsUpdateSuccessDialog), findsNothing);
  });

  testWidgets('success dialog hides different build numbers', (tester) async {
    for (final version in ['1.7.0+20', '1.7.0+21']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WindowsUpdateSuccessDialog(installedVersion: version),
          ),
        ),
      );
      expect(find.text('VERSIÓN 1.7.0'), findsOneWidget);
      expect(find.textContaining('+'), findsNothing);
    }
  });

  testWidgets('availability dialog hides build metadata for both versions', (
    tester,
  ) async {
    final release = WindowsReleaseInfo(
      tag: 'v1.8.0',
      version: SemanticVersion.tryParse('1.8.0+25')!,
      name: 'SuelosAR 1.8.0',
      description: 'Mejoras y correcciones.',
      publishedAt: DateTime.utc(2026, 11, 3),
      assets: const [],
      htmlUrl: Uri.parse('https://example.invalid/releases/v1.8.0'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsUpdateAvailabilityDialog(
            release: release,
            installedVersion: '1.7.0+21',
            verifiedCheck: null,
            isPreview: false,
            downloadUnavailableReason: null,
          ),
        ),
      ),
    );

    expect(find.text('1.7.0'), findsOneWidget);
    expect(find.text('1.8.0'), findsNWidgets(2));
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('update popup hides build metadata for installed and download', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WindowsUpdateStatusPopover(
            state: WindowsUpdatePopoverState.downloading,
            installedVersion: '1.7.0+21',
            downloadVersion: '1.8.0+25',
            reduceAnimations: true,
            onCheck: _noop,
          ),
        ),
      ),
    );

    expect(find.text('1.7.0'), findsNothing);
    expect(find.text('Versión 1.8.0'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('up-to-date popup hides installed build metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WindowsUpdateStatusPopover(
            state: WindowsUpdatePopoverState.upToDate,
            installedVersion: '1.7.0+21',
            reduceAnimations: true,
            onCheck: _noop,
          ),
        ),
      ),
    );
    expect(find.text('1.7.0'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
  });
}

void _noop() {}
