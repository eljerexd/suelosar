import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/widgets/windows_update_status_popover.dart';

void main() {
  testWidgets('verified download offers install and close only postpones', (
    tester,
  ) async {
    var installCalls = 0;
    var closeCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsUpdateStatusPopover(
            state: WindowsUpdatePopoverState.downloadCompleted,
            installedVersion: '1.7.0',
            downloadVersion: '1.8.0',
            reduceAnimations: true,
            onCheck: () {},
            installEnabled: true,
            onInstallUpdate: () => installCalls++,
            onDismissDownload: () => closeCalls++,
          ),
        ),
      ),
    );

    expect(find.text('Descarga completada'), findsOneWidget);
    expect(find.text('Actualizar y reiniciar'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('windows-update-download-dismiss')),
    );
    expect(closeCalls, 1);
    expect(installCalls, 0);
    await tester.tap(find.byKey(const ValueKey('windows-update-install')));
    expect(installCalls, 1);
  });

  testWidgets('automatic install stays disabled before lifecycle validation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WindowsUpdateStatusPopover(
            state: WindowsUpdatePopoverState.downloadCompleted,
            installedVersion: '1.7.0',
            downloadVersion: '1.8.0',
            reduceAnimations: true,
            onCheck: _noop,
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('windows-update-install')),
    );
    expect(button.onPressed, isNull);
    expect(
      find.text(
        'La instalación automática está pendiente de validación en Windows.',
      ),
      findsOneWidget,
    );
  });
}

void _noop() {}
