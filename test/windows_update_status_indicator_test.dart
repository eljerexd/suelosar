import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/screens/home_screen.dart';
import 'package:suelosar/services/windows_update_indicator_controller.dart';
import 'package:suelosar/services/windows_update_models.dart';
import 'package:suelosar/widgets/windows_update_status_indicator.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'Windows Home shows the update indicator opposite sync controls',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = _controller(() async => _upToDate());
      await controller.initialize();
      await controller.checkCompletion;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: HomeScreen(
            deviceLinkedStatusLoader: () async => false,
            windowsUpdateController: controller,
          ),
        ),
      );
      await tester.pump();

      final indicator = find.byKey(
        const ValueKey('windows-update-status-indicator'),
      );
      expect(indicator, findsOneWidget);
      expect(
        find.ancestor(of: indicator, matching: find.byType(Tooltip)),
        findsNothing,
      );
      expect(find.text('Aplicación actualizada'), findsOneWidget);
      expect(
        tester.getTopLeft(indicator).dx,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('home-synchronization-status')),
              )
              .dx,
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('update indicator hides build metadata in the release version', (
    tester,
  ) async {
    final controller = _controller(
      () async => _updateAvailable('1.8.0+25'),
      installedVersion: '1.7.0+21',
    );
    await controller.initialize();
    await controller.checkCompletion;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: WindowsUpdateStatusIndicator(controller: controller),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Nueva versión 1.8.0'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'manual up-to-date check confirms and update click emits release',
    (tester) async {
      var response = _upToDate();
      final controller = _controller(() async => response);
      await controller.initialize();
      await controller.checkCompletion;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: WindowsUpdateStatusIndicator(controller: controller),
          ),
        ),
      );

      await tester.tap(find.text('Aplicación actualizada'));
      await tester.pumpAndSettle();
      expect(find.text('Ya tenés la última versión'), findsOneWidget);
      expect(find.text('SuelosAR está actualizado.'), findsOneWidget);
      expect(find.text('1.7.0'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(
        find.byKey(const ValueKey('update-popover-check')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('windows-update-status-popover')),
        findsNothing,
      );

      response = _updateAvailable('1.8.0');
      await controller.checkManually();
      await tester.pump();
      final selected = expectLater(
        controller.onUpdateAvailableSelected,
        emits(
          predicate<WindowsReleaseInfo>(
            (release) => release.version.toString() == '1.8.0',
          ),
        ),
      );
      await tester.tap(find.text('Nueva versión 1.8.0'));
      await selected;
      expect(find.text('Nueva versión 1.8.0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'manual failure replaces checking feedback with offline feedback',
    (tester) async {
      final pending = Completer<WindowsUpdateCheckResult>();
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
        WindowsUpdateIndicatorController.lastStatusKey: 'upToDate',
      });
      final controller = _controller(() => pending.future);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: WindowsUpdateStatusIndicator(controller: controller),
          ),
        ),
      );

      await tester.tap(find.text('Aplicación actualizada'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('windows-update-status-popover')),
          matching: find.text('Buscando actualizaciones...'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('windows-update-status-popover')),
        findsOneWidget,
      );

      pending.complete(
        const WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.releaseUnavailable,
          error: WindowsUpdateError(
            code: WindowsUpdateErrorCode.networkUnavailable,
            message: 'offline',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No se pudo comprobar si hay actualizaciones.'),
        findsOneWidget,
      );
      expect(find.text('Buscando actualizaciones...'), findsNothing);
      expect(
        find.byKey(const ValueKey('update-popover-retry')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('indicator is absent on non-Windows platforms', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = WindowsUpdateIndicatorController(
      isWindows: false,
      checkForUpdates: () async => _upToDate(),
    );
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: HomeScreen(
          deviceLinkedStatusLoader: () async => false,
          windowsUpdateController: controller,
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('windows-update-status-indicator')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('manual release selection opens real notes and preserves Later', (
    tester,
  ) async {
    final controller = _controller(() async => _updateAvailable('1.8.0'));
    await controller.initialize();
    await controller.checkCompletion;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: HomeScreen(
          deviceLinkedStatusLoader: () async => false,
          windowsUpdateController: controller,
        ),
      ),
    );

    await tester.tap(find.text('Nueva versión 1.8.0'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('windows-update-availability-dialog')),
      findsOneWidget,
    );
    expect(find.text('Notas de versión'), findsOneWidget);
    expect(find.text('1.7.0'), findsOneWidget);
    final download = tester.widget<FilledButton>(
      find.byKey(const ValueKey('update-dialog-download')),
    );
    expect(download.onPressed, isNull);
    expect(
      find.text('Este release no incluye un instalador de Windows.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('update-dialog-later')));
    await tester.pumpAndSettle();
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(WindowsUpdateIndicatorController.pendingReleaseKey),
      contains('1.8.0'),
    );
    expect(
      preferences.getString(
        WindowsUpdateIndicatorController.dismissedVersionKey,
      ),
      '1.8.0',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'tapping a cached update refreshes its verification before opening the dialog',
    (tester) async {
      final cachedRelease = _release(
        '1.7.0',
        description: 'Notas guardadas de la comprobación anterior.',
      );
      final recentAttempt = DateTime.utc(
        2026,
        11,
        1,
      ).subtract(const Duration(hours: 1));
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: recentAttempt
            .toIso8601String(),
        WindowsUpdateIndicatorController.lastStatusKey: 'updateAvailable',
        WindowsUpdateIndicatorController.pendingReleaseKey: jsonEncode(
          _encodeRelease(cachedRelease),
        ),
        WindowsUpdateIndicatorController.lastReleaseKey: jsonEncode(
          _encodeRelease(cachedRelease),
        ),
      });

      var checkCount = 0;
      final controller = _controller(() async {
        checkCount++;
        return _verifiedUpdateAvailable('1.7.0');
      }, installedVersion: '1.6.0');
      await controller.initialize();
      await controller.checkCompletion;
      expect(checkCount, 0);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: HomeScreen(
            deviceLinkedStatusLoader: () async => false,
            windowsUpdateController: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final staleDownload = tester.widget<FilledButton>(
        find.byKey(const ValueKey('update-dialog-download')),
      );
      expect(staleDownload.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('update-dialog-later')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Nueva versión 1.7.0'));
      await tester.pumpAndSettle();

      expect(checkCount, 1);
      expect(find.text('Notas actuales de GitHub.'), findsOneWidget);
      final refreshedDownload = tester.widget<FilledButton>(
        find.byKey(const ValueKey('update-dialog-download')),
      );
      expect(refreshedDownload.onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('update-dialog-later')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'startup pending release prompts once and Later keeps it pending',
    (tester) async {
      final release = _release('1.8.0');
      final recentAttempt = DateTime.utc(
        2026,
        11,
        1,
      ).subtract(const Duration(hours: 1));
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: recentAttempt
            .toIso8601String(),
        WindowsUpdateIndicatorController.lastStatusKey: 'updateAvailable',
        WindowsUpdateIndicatorController.pendingReleaseKey: jsonEncode(
          _encodeRelease(release),
        ),
        WindowsUpdateIndicatorController.lastReleaseKey: jsonEncode(
          _encodeRelease(release),
        ),
      });
      final controller = _controller(() async => _upToDate());
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: HomeScreen(
            deviceLinkedStatusLoader: () async => false,
            windowsUpdateController: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('windows-update-availability-dialog')),
        findsOneWidget,
      );
      expect(find.text('Notas de versión'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('update-dialog-later')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey('windows-update-availability-dialog')),
        findsNothing,
      );
      expect(controller.hasPendingStartupPrompt, isFalse);
      expect(await controller.takeStartupPrompt(), isNull);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString(
          WindowsUpdateIndicatorController.pendingReleaseKey,
        ),
        contains('1.8.0'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'installed release clears the stale update indicator at startup',
    (tester) async {
      final release = _release('1.7.0');
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: DateTime.utc(
          2026,
          11,
          1,
        ).subtract(const Duration(minutes: 5)).toIso8601String(),
        WindowsUpdateIndicatorController.lastStatusKey: 'updateAvailable',
        WindowsUpdateIndicatorController.pendingReleaseKey: jsonEncode(
          _encodeRelease(release),
        ),
        WindowsUpdateIndicatorController.lastReleaseKey: jsonEncode(
          _encodeRelease(release),
        ),
        WindowsUpdateIndicatorController.dismissedVersionKey: '1.7.0',
      });
      final controller = _controller(
        () async => _upToDate(),
        installedVersion: '1.7.0+20',
      );
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: HomeScreen(
            deviceLinkedStatusLoader: () async => false,
            windowsUpdateController: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Aplicación actualizada'), findsOneWidget);
      expect(find.text('Nueva versión 1.7.0'), findsNothing);
      expect(
        find.byKey(const ValueKey('windows-update-availability-dialog')),
        findsNothing,
      );
      expect(controller.state, WindowsUpdateIndicatorState.upToDate);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'open update dialog refreshes notes when the release body changes',
    (tester) async {
      final oldRelease = _release(
        '1.7.0',
        description: 'Notas antiguas: paa comodidad.',
      );
      final recentAttempt = DateTime.utc(
        2026,
        11,
        1,
      ).subtract(const Duration(hours: 25));
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: recentAttempt
            .toIso8601String(),
        WindowsUpdateIndicatorController.lastStatusKey: 'updateAvailable',
        WindowsUpdateIndicatorController.pendingReleaseKey: jsonEncode(
          _encodeRelease(oldRelease),
        ),
        WindowsUpdateIndicatorController.lastReleaseKey: jsonEncode(
          _encodeRelease(oldRelease),
        ),
      });
      final refreshed = Completer<WindowsUpdateCheckResult>();
      final controller = _controller(
        () => refreshed.future,
        installedVersion: '1.6.0',
      );
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: HomeScreen(
            deviceLinkedStatusLoader: () async => false,
            windowsUpdateController: controller,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Notas antiguas: paa comodidad.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('update-dialog-cached-release-note')),
        findsOneWidget,
      );

      const newDescription = 'Gestor de descarga para más comodidad.';
      refreshed.complete(
        WindowsUpdateCheckResult(
          status: WindowsUpdateStatus.installerAssetMissing,
          installedVersion: SemanticVersion.tryParse('1.6.0'),
          release: _release('1.7.0', description: newDescription),
        ),
      );
      await controller.checkCompletion;
      await tester.pumpAndSettle();

      expect(find.text(newDescription), findsOneWidget);
      expect(find.text('Notas antiguas: paa comodidad.'), findsNothing);
      expect(
        find.byKey(const ValueKey('update-dialog-cached-release-note')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('update-dialog-later')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('cached release notes stay identified after an offline check', (
    tester,
  ) async {
    final cached = _release(
      '1.7.0',
      description: 'Notas guardadas de una comprobación anterior.',
    );
    final recentAttempt = DateTime.utc(
      2026,
      11,
      1,
    ).subtract(const Duration(hours: 25));
    SharedPreferences.setMockInitialValues({
      WindowsUpdateIndicatorController.lastAttemptedAtKey: recentAttempt
          .toIso8601String(),
      WindowsUpdateIndicatorController.lastStatusKey: 'updateAvailable',
      WindowsUpdateIndicatorController.pendingReleaseKey: jsonEncode(
        _encodeRelease(cached),
      ),
      WindowsUpdateIndicatorController.lastReleaseKey: jsonEncode(
        _encodeRelease(cached),
      ),
    });
    final check = Completer<WindowsUpdateCheckResult>();
    final controller = _controller(
      () => check.future,
      installedVersion: '1.6.0',
    );
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: HomeScreen(
          deviceLinkedStatusLoader: () async => false,
          windowsUpdateController: controller,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text(cached.description), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-dialog-cached-release-note')),
      findsOneWidget,
    );

    check.complete(
      const WindowsUpdateCheckResult(
        status: WindowsUpdateStatus.releaseUnavailable,
        error: WindowsUpdateError(
          code: WindowsUpdateErrorCode.networkUnavailable,
          message: 'offline',
        ),
      ),
    );
    await controller.checkCompletion;
    await tester.pumpAndSettle();

    expect(find.text(cached.description), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-dialog-cached-release-note')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('update-dialog-later')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('up-to-date popup is anchored below and aligned with indicator', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _controller(() async => _upToDate());
    await controller.initialize();
    await controller.checkCompletion;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: HomeScreen(
          deviceLinkedStatusLoader: () async => false,
          windowsUpdateController: controller,
        ),
      ),
    );

    await tester.tap(find.text('Aplicación actualizada'));
    await tester.pumpAndSettle();
    final indicator = tester.getRect(
      find.byKey(const ValueKey('windows-update-status-indicator')),
    );
    final popover = tester.getRect(
      find.byKey(const ValueKey('windows-update-status-popover')),
    );
    expect(popover.left, closeTo(indicator.left, 1));
    expect(popover.top, greaterThanOrEqualTo(indicator.bottom));
    expect(popover.right, lessThanOrEqualTo(tester.view.physicalSize.width));

    await tester.tapAt(const Offset(900, 700));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('windows-update-status-popover')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('up-to-date popup stays inside a narrow window', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _controller(() async => _upToDate());
    await controller.initialize();
    await controller.checkCompletion;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: HomeScreen(
          deviceLinkedStatusLoader: () async => false,
          windowsUpdateController: controller,
        ),
      ),
    );

    await tester.tap(find.text('Aplicación actualizada'));
    await tester.pumpAndSettle();
    final popover = tester.getRect(
      find.byKey(const ValueKey('windows-update-status-popover')),
    );
    expect(popover.left, greaterThanOrEqualTo(0));
    expect(popover.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'up-to-date popup shifts inward when indicator is at right edge',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = _controller(() async => _upToDate());
      await controller.initialize();
      await controller.checkCompletion;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: WindowsUpdateStatusIndicator(controller: controller),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Aplicación actualizada'));
      await tester.pumpAndSettle();
      final indicator = tester.getRect(
        find.byKey(const ValueKey('windows-update-status-indicator')),
      );
      final popover = tester.getRect(
        find.byKey(const ValueKey('windows-update-status-popover')),
      );
      expect(indicator.right, closeTo(320, 1));
      expect(popover.left, greaterThanOrEqualTo(16));
      expect(popover.right, lessThanOrEqualTo(304));
      expect(popover.top, greaterThan(indicator.bottom));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}

WindowsUpdateIndicatorController _controller(
  WindowsUpdateCheck check, {
  String installedVersion = '1.7.0',
}) => WindowsUpdateIndicatorController(
  isWindows: true,
  checkForUpdates: check,
  installedVersionReader: () async => installedVersion,
  clock: () => DateTime.utc(2026, 11, 1),
);

WindowsUpdateCheckResult _upToDate() => WindowsUpdateCheckResult(
  status: WindowsUpdateStatus.upToDate,
  installedVersion: const SemanticVersion(major: 1, minor: 7, patch: 0),
  release: _release('1.7.0'),
);

WindowsUpdateCheckResult _updateAvailable(String version) =>
    WindowsUpdateCheckResult(
      status: WindowsUpdateStatus.installerAssetMissing,
      installedVersion: const SemanticVersion(major: 1, minor: 7, patch: 0),
      release: _release(version),
    );

WindowsUpdateCheckResult _verifiedUpdateAvailable(String version) {
  final name = 'SuelosAR-Setup-$version.exe';
  final checksum = List.filled(64, 'a').join();
  return WindowsUpdateCheckResult(
    status: WindowsUpdateStatus.updateAvailable,
    installedVersion: SemanticVersion.tryParse('1.6.0'),
    release: _release(version, description: 'Notas actuales de GitHub.'),
    installer: WindowsReleaseAsset(
      name: name,
      downloadUrl: Uri.parse(
        'https://github.com/eljerexd/Web-SuelosAR/releases/download/v$version/$name',
      ),
      size: 100,
    ),
    sha256: checksum,
  );
}

WindowsReleaseInfo _release(
  String version, {
  String description = 'Notas de versión',
}) => WindowsReleaseInfo(
  tag: 'v$version',
  version: SemanticVersion.tryParse(version)!,
  name: 'SuelosAR $version',
  description: description,
  publishedAt: DateTime.utc(2026, 10, 31),
  assets: const [],
  htmlUrl: Uri.parse(
    'https://github.com/eljerexd/Web-SuelosAR/releases/tag/v$version',
  ),
);

Map<String, Object?> _encodeRelease(WindowsReleaseInfo release) => {
  'tag': release.tag,
  'version': release.version.toString(),
  'name': release.name,
  'description': release.description,
  'publishedAt': release.publishedAt.toUtc().toIso8601String(),
  'htmlUrl': release.htmlUrl.toString(),
  'assets': const <Object>[],
};
