import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/screens/home_screen.dart';
import 'package:suelosar/services/windows_update_indicator_controller.dart';
import 'package:suelosar/services/windows_update_models.dart';
import 'package:suelosar/widgets/windows_update_availability_dialog.dart';
import 'package:suelosar/widgets/windows_update_status_popover.dart';

void main() {
  testWidgets('update indicator opens the preview and Más tarde closes it', (
    tester,
  ) async {
    final controller = WindowsUpdateIndicatorController.forDevelopmentPreview();
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(_app(controller));
    expect(find.text('Nueva versión 1.8.0'), findsOneWidget);
    await tester.tap(find.text('Nueva versión 1.8.0'));
    await tester.pumpAndSettle();

    expect(find.text('Nueva versión disponible'), findsOneWidget);
    expect(find.text('1.7.0'), findsOneWidget);
    expect(find.text('1.8.0'), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('update-dialog-version-badge')),
      findsOneWidget,
    );
    expect(
      tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('update-dialog-later')),
      ),
      isA<OutlinedButton>(),
    );
    expect(
      tester.widget<FilledButton>(
        find.byKey(const ValueKey('update-dialog-download')),
      ),
      isA<FilledButton>(),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('update-dialog-download')),
        matching: find.text('Descargar'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Correcciones, mejoras y novedades de esta versión.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('update-dialog-later')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('windows-update-availability-dialog')),
      findsNothing,
    );
    expect(find.text('Nueva versión 1.8.0'), findsOneWidget);
  });

  testWidgets('Descargar closes the dialog and starts popup progress', (
    tester,
  ) async {
    final controller = WindowsUpdateIndicatorController.forDevelopmentPreview();
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Nueva versión 1.8.0'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-dialog-download')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.byKey(const ValueKey('windows-update-availability-dialog')),
      findsNothing,
    );
    expect(find.text('Descargando SuelosAR'), findsOneWidget);
    expect(find.text('Descargando actualización...'), findsOneWidget);
    expect(
      RegExp(r'^\d+%$').hasMatch(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('windows-update-download-percent')),
            )
            .data!,
      ),
      isTrue,
    );
    expect(
      RegExp(r'^\d+,\d MB de 66,5 MB$').hasMatch(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('windows-update-download-bytes')),
            )
            .data!,
      ),
      isTrue,
    );
    expect(find.text('5,5 MB/s'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('windows-update-download-progress')),
      findsOneWidget,
    );
    expect(controller.state.name, 'updateAvailable');
    expect(await controller.checkManually(), isNull);

    final indicator = find.byKey(
      const ValueKey('windows-update-status-indicator'),
    );
    expect(
      find.byKey(const ValueKey('windows-update-download-indicator-spinner')),
      findsOneWidget,
    );
    await tester.tap(indicator);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('windows-update-status-popover')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('windows-update-download-indicator-spinner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('windows-update-availability-dialog')),
      findsNothing,
    );
    await tester.tap(indicator);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('windows-update-status-popover')),
      findsOneWidget,
    );
    expect(controller.downloadState, WindowsUpdateDownloadState.downloading);

    final initialFraction = controller.downloadProgress!.fraction!;
    await _advancePreviewTime(tester, const Duration(milliseconds: 3000));
    final progress = controller.downloadProgress!;
    expect(progress.fraction!, closeTo(initialFraction + 0.25, 0.02));
    expect(find.text('${(progress.fraction! * 100).round()}%'), findsOneWidget);
    final downloadedMb = (progress.downloadedBytes / 1000000)
        .toStringAsFixed(1)
        .replaceAll('.', ',');
    expect(find.text('$downloadedMb MB de 66,5 MB'), findsOneWidget);
    controller.cancelDownload();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    controller.dismissDownloadPopup();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('popup cancellation returns to a dismissible cancelled state', (
    tester,
  ) async {
    final controller = WindowsUpdateIndicatorController.forDevelopmentPreview();
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Nueva versión 1.8.0'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-dialog-download')));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Descargando actualización...'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('windows-update-download-cancel')),
    );
    await tester.pump();
    expect(find.text('Cancelando descarga'), findsOneWidget);
    expect(find.text('Cancelando descarga...'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Descarga cancelada'), findsOneWidget);
    expect(find.text('No se instaló nada.'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('windows-update-download-dismiss')),
    );
    await tester.pumpAndSettle();
    expect(controller.hasDownloadPopup, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('simulation completes at 100 percent without a real callback', (
    tester,
  ) async {
    final controller = WindowsUpdateIndicatorController.forDevelopmentPreview();
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Nueva versión 1.8.0'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-dialog-download')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Descargando SuelosAR'), findsOneWidget);
    await _advancePreviewTime(tester, const Duration(seconds: 13));
    expect(controller.downloadProgress?.fraction, 1);
    expect(find.text('Descarga completada'), findsOneWidget);
    expect(
      find.text('Demostración completada; no se creó ningún archivo.'),
      findsOneWidget,
    );
    expect(await controller.checkManually(), isNull);
    await tester.tap(
      find.byKey(const ValueKey('windows-update-download-dismiss')),
    );
    await tester.pumpAndSettle();
    expect(controller.hasDownloadPopup, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('centered update dialog remains usable in a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = WindowsUpdateIndicatorController.forDevelopmentPreview();
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(_app(controller));
    await tester.tap(
      find.byKey(const ValueKey('windows-update-status-indicator')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nueva versión disponible'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-dialog-version-badge')),
      findsOneWidget,
    );
    final dialog = tester.getRect(
      find.byKey(const ValueKey('windows-update-availability-dialog')),
    );
    expect(dialog.left, greaterThanOrEqualTo(0));
    expect(dialog.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialog renders the actual version and release notes values', (
    tester,
  ) async {
    final release = WindowsReleaseInfo(
      tag: 'v1.8.3',
      version: SemanticVersion.tryParse('1.8.3')!,
      name: 'SuelosAR 1.8.3',
      description: 'Notas oficiales para 1.8.3.',
      publishedAt: DateTime.utc(2026, 11, 1),
      assets: const [],
      htmlUrl: Uri.parse('https://example.invalid/releases/v1.8.3'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsUpdateAvailabilityDialog(
            release: release,
            installedVersion: '1.7.2',
            verifiedCheck: null,
            isPreview: false,
            downloadUnavailableReason: 'No se verificó un instalador.',
          ),
        ),
      ),
    );

    expect(find.text('1.8.3'), findsNWidgets(2));
    expect(find.text('1.7.2'), findsOneWidget);
    expect(find.text('Notas oficiales para 1.8.3.'), findsOneWidget);
    expect(
      find.text('Correcciones, mejoras y novedades de esta versión.'),
      findsNothing,
    );
  });

  testWidgets('ready dialog height follows the release notes length', (
    tester,
  ) async {
    final shortRelease = _release('1.8.1', description: 'Mejoras menores.');
    Widget dialogFor(WindowsReleaseInfo release) => MaterialApp(
      home: Scaffold(
        body: WindowsUpdateAvailabilityDialog(
          release: release,
          installedVersion: '1.7.0',
          verifiedCheck: null,
          isPreview: false,
          downloadUnavailableReason: null,
        ),
      ),
    );

    await tester.pumpWidget(dialogFor(shortRelease));
    final shortHeight = tester
        .getRect(find.byKey(const ValueKey('update-dialog-surface')))
        .height;
    expect(shortHeight, lessThan(360));

    final longRelease = _release(
      '1.8.1',
      description: List<String>.filled(
        12,
        'Se mejoró el rendimiento de mapas y se corrigieron errores menores.',
      ).join('\n\n'),
    );
    await tester.pumpWidget(dialogFor(longRelease));
    final longHeight = tester
        .getRect(find.byKey(const ValueKey('update-dialog-surface')))
        .height;
    expect(longHeight, greaterThan(shortHeight + 100));
    expect(longHeight, lessThan(560));
  });

  testWidgets('empty release notes have a truthful fallback', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsUpdateAvailabilityDialog(
            release: _release('1.8.4', description: ''),
            installedVersion: '1.7.0',
            verifiedCheck: null,
            isPreview: false,
            downloadUnavailableReason: null,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('update-dialog-empty-release-notes')),
      findsOneWidget,
    );
    expect(find.text('Sin notas de versión.'), findsNothing);
  });

  testWidgets('missing installer and checksum both disable download', (
    tester,
  ) async {
    final release = _release('1.8.5');
    final asset = WindowsReleaseAsset(
      name: 'SuelosAR-Setup-1.8.5.exe',
      downloadUrl: Uri.parse(
        'https://github.com/eljerexd/suelosar/releases/download/v1.8.5/SuelosAR-Setup-1.8.5.exe',
      ),
      size: 100,
    );
    for (final check in [
      WindowsUpdateCheckResult(
        status: WindowsUpdateStatus.installerAssetMissing,
        installedVersion: SemanticVersion.tryParse('1.7.0'),
        release: release,
      ),
      WindowsUpdateCheckResult(
        status: WindowsUpdateStatus.checksumUnavailable,
        installedVersion: SemanticVersion.tryParse('1.7.0'),
        release: release,
        installer: asset,
      ),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WindowsUpdateAvailabilityDialog(
              release: release,
              installedVersion: '1.7.0',
              verifiedCheck: check,
              isPreview: false,
              downloadUnavailableReason: null,
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('update-dialog-download')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.text(
          check.status == WindowsUpdateStatus.installerAssetMissing
              ? 'Este release no incluye un instalador de Windows.'
              : 'No hay un SHA-256 verificable para este instalador.',
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('verified Descargar closes the dialog with a download action', (
    tester,
  ) async {
    final release = _release('1.8.6');
    final check = WindowsUpdateCheckResult(
      status: WindowsUpdateStatus.updateAvailable,
      installedVersion: SemanticVersion.tryParse('1.7.0'),
      release: release,
      installer: WindowsReleaseAsset(
        name: 'SuelosAR-Setup-1.8.6.exe',
        downloadUrl: Uri.parse(
          'https://github.com/eljerexd/suelosar/releases/download/v1.8.6/SuelosAR-Setup-1.8.6.exe',
        ),
        size: 100,
      ),
      sha256: 'a' * 64,
    );
    WindowsUpdateDialogAction? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showWindowsUpdateAvailabilityDialog(
                  context,
                  release: release,
                  installedVersion: '1.7.0',
                  verifiedCheck: check,
                  isPreview: false,
                  downloadUnavailableReason: null,
                );
              },
              child: const Text('Abrir diálogo'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir diálogo'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('update-dialog-download')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('update-dialog-download')));
    await tester.pumpAndSettle();
    expect(selected, WindowsUpdateDialogAction.download);
    expect(
      find.byKey(const ValueKey('windows-update-availability-dialog')),
      findsNothing,
    );
  });
}

WindowsReleaseInfo _release(
  String version, {
  String description = 'Notas oficiales.',
}) => WindowsReleaseInfo(
  tag: 'v$version',
  version: SemanticVersion.tryParse(version)!,
  name: 'SuelosAR $version',
  description: description,
  publishedAt: DateTime.utc(2026, 11, 1),
  assets: const [],
  htmlUrl: Uri.parse(
    'https://github.com/eljerexd/suelosar/releases/tag/v$version',
  ),
);

Widget _app(WindowsUpdateIndicatorController controller) {
  final layerLink = LayerLink();
  return MaterialApp(
    theme: ThemeData(platform: TargetPlatform.windows),
    builder: (context, child) => WindowsUpdateDownloadPopupHost(
      controller: controller,
      indicatorLink: layerLink,
      child: child ?? const SizedBox.shrink(),
    ),
    home: HomeScreen(
      deviceLinkedStatusLoader: () async => false,
      windowsUpdateController: controller,
      windowsUpdateIndicatorLink: layerLink,
    ),
  );
}

Future<void> _advancePreviewTime(WidgetTester tester, Duration duration) async {
  const step = Duration(milliseconds: 100);
  for (var elapsed = Duration.zero; elapsed < duration; elapsed += step) {
    await tester.pump(step);
  }
}
