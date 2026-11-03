import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/services/windows_update_indicator_controller.dart';
import 'package:suelosar/services/windows_update_models.dart';

void main() {
  final now = DateTime.utc(2026, 11, 1, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'restores last known up-to-date state and respects 24-hour interval',
    () async {
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: now
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
        WindowsUpdateIndicatorController.lastSuccessfulAtKey: now
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
        WindowsUpdateIndicatorController.lastStatusKey: 'upToDate',
      });
      var calls = 0;
      final controller = _controller(
        now: now,
        initialStatus: 'upToDate',
        recentAttempt: now.subtract(const Duration(hours: 1)),
        check: () async {
          calls++;
          return _upToDate();
        },
      );

      await controller.initialize();

      expect(controller.state, WindowsUpdateIndicatorState.upToDate);
      expect(calls, 0);
      controller.dispose();
    },
  );

  test('startup automatically checks when the saved attempt is due', () async {
    var calls = 0;
    final controller = _controller(
      now: now,
      check: () async {
        calls++;
        return _upToDate();
      },
    );

    await controller.initialize();
    await controller.checkCompletion;

    expect(calls, 1);
    expect(controller.state, WindowsUpdateIndicatorState.upToDate);
    expect(controller.lastAttemptedAt, now);
    expect(controller.lastSuccessfulAt, now);
    controller.dispose();
  });

  test(
    'startup initialization returns while the network check is pending',
    () async {
      final pending = Completer<WindowsUpdateCheckResult>();
      final controller = _controller(now: now, check: () => pending.future);

      await controller.initialize();

      expect(controller.isChecking, isTrue);
      expect(controller.state, WindowsUpdateIndicatorState.checking);
      pending.complete(_upToDate());
      await controller.checkCompletion;
      expect(controller.state, WindowsUpdateIndicatorState.upToDate);
      controller.dispose();
    },
  );

  test('startup network failure is not reported as up to date', () async {
    final controller = _controller(now: now, check: () async => _failure());

    await controller.initialize();
    await controller.checkCompletion;

    expect(controller.state, WindowsUpdateIndicatorState.error);
    expect(controller.lastSuccessfulAt, isNull);
    controller.dispose();
  });

  test(
    'preference write failure does not discard a valid release result',
    () async {
      final controller = WindowsUpdateIndicatorController(
        isWindows: true,
        checkForUpdates: () async => _updateAvailable('1.8.0'),
        preferencesLoader: () async => throw StateError('storage unavailable'),
        installedVersionReader: () async => '1.7.0',
        clock: () => now,
      );

      await controller.initialize();
      await controller.checkCompletion;

      expect(controller.state, WindowsUpdateIndicatorState.updateAvailable);
      expect(controller.latestAvailableRelease?.version.toString(), '1.8.0');
      controller.dispose();
    },
  );

  test('manual network failure exposes the retryable error state', () async {
    final controller = _controller(
      now: now,
      initialStatus: 'upToDate',
      recentAttempt: now,
      check: () async => _failure(),
    );
    await controller.initialize();

    final result = await controller.checkManually();

    expect(result?.status, WindowsUpdateStatus.releaseUnavailable);
    expect(controller.state, WindowsUpdateIndicatorState.error);
    controller.dispose();
  });

  for (final version in ['1.7.1', '1.8.0', '2.0.0']) {
    test('manual check detects newer stable version $version', () async {
      final controller = _controller(
        now: now,
        check: () async => _updateAvailable(version),
        initialStatus: 'upToDate',
        recentAttempt: now,
      );
      await controller.initialize();

      final result = await controller.checkManually();

      expect(result?.updateAvailable, isTrue);
      expect(controller.state, WindowsUpdateIndicatorState.updateAvailable);
      expect(controller.latestAvailableRelease?.version.toString(), version);
      controller.dispose();
    });
  }

  test('loading blocks concurrent manual requests', () async {
    final pending = Completer<WindowsUpdateCheckResult>();
    final checkerStarted = Completer<void>();
    var calls = 0;
    final controller = _controller(
      now: now,
      check: () {
        calls++;
        checkerStarted.complete();
        return pending.future;
      },
      initialStatus: 'upToDate',
      recentAttempt: now,
    );
    await controller.initialize();

    final first = controller.checkManually();
    await checkerStarted.future;
    final second = await controller.checkManually();
    expect(controller.state, WindowsUpdateIndicatorState.checking);
    expect(second, isNull);
    expect(calls, 1);

    pending.complete(_upToDate());
    await first;
    expect(controller.state, WindowsUpdateIndicatorState.upToDate);
    controller.dispose();
  });

  test('automatic failure retains a previously detected update', () async {
    final first = _controller(
      now: now,
      check: () async => _updateAvailable('1.8.0'),
    );
    await first.initialize();
    await first.checkCompletion;
    first.dispose();

    final later = now.add(const Duration(hours: 25));
    final second = _controller(
      now: later,
      check: () async => _failure(),
      resetPreferences: false,
    );
    await second.initialize();
    await second.checkCompletion;

    expect(second.state, WindowsUpdateIndicatorState.updateAvailable);
    expect(second.latestAvailableRelease?.version.toString(), '1.8.0');
    second.dispose();
  });

  test(
    'new release persists and is exposed as a next-launch prompt once',
    () async {
      final discovering = _controller(
        now: now,
        check: () async => _updateAvailable('1.8.0'),
      );
      await discovering.initialize();
      await discovering.checkCompletion;
      expect(discovering.hasPendingStartupPrompt, isFalse);
      expect(await discovering.takeStartupPrompt(), isNull);
      discovering.dispose();

      final restored = _controller(
        now: now.add(const Duration(minutes: 5)),
        check: () async => _upToDate(),
        recentAttempt: now,
        installedVersionReader: () async => '1.7.0',
        resetPreferences: false,
      );
      await restored.initialize();
      expect(restored.hasPendingStartupPrompt, isTrue);
      expect((await restored.takeStartupPrompt())?.version.toString(), '1.8.0');
      expect(await restored.takeStartupPrompt(), isNull);
      restored.dispose();
    },
  );

  test('Later suppresses the same release on the next launch', () async {
    final first = _controller(
      now: now,
      check: () async => _updateAvailable('1.8.0'),
    );
    await first.initialize();
    await first.checkCompletion;
    await first.markUpdateDismissedForLater('1.8.0');
    first.dispose();

    final nextLaunch = _controller(
      now: now.add(const Duration(minutes: 1)),
      check: () async => _upToDate(),
      recentAttempt: now,
      installedVersionReader: () async => '1.7.0',
      resetPreferences: false,
    );
    await nextLaunch.initialize();
    expect(nextLaunch.hasPendingStartupPrompt, isFalse);
    expect(await nextLaunch.takeStartupPrompt(), isNull);
    expect(nextLaunch.latestAvailableRelease?.version.toString(), '1.8.0');
    nextLaunch.dispose();
  });

  test('a newer pending release clears the previous Later choice', () async {
    final first = _controller(
      now: now,
      check: () async => _updateAvailable('1.8.0'),
    );
    await first.initialize();
    await first.checkCompletion;
    await first.markUpdateDismissedForLater('1.8.0');

    final updated = _controller(
      now: now.add(const Duration(minutes: 1)),
      check: () async => _updateAvailable('1.8.1'),
      initialStatus: 'updateAvailable',
      recentAttempt: now,
      installedVersionReader: () async => '1.7.0',
      resetPreferences: false,
    );
    await updated.initialize();
    await updated.checkManually();

    expect(updated.latestAvailableRelease?.version.toString(), '1.8.1');
    expect(updated.hasPendingStartupPrompt, isTrue);
    expect((await updated.takeStartupPrompt())?.version.toString(), '1.8.1');
    updated.dispose();
    first.dispose();
  });

  test('same-version release refresh replaces persisted notes', () async {
    final cached = _release(
      '1.7.0',
      description: 'Notas antiguas: paa comodidad.',
    );
    final recentAttempt = now.subtract(const Duration(hours: 1));
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
    const newDescription = 'Gestor de descarga para más comodidad.';
    final controller = _controller(
      now: now,
      check: () async => _updateAvailable(
        '1.7.0',
        installedVersion: '1.6.0',
        description: newDescription,
      ),
      recentAttempt: recentAttempt,
      resetPreferences: false,
      installedVersionReader: () async => '1.6.0',
    );

    await controller.initialize();
    expect(controller.releaseNotesAreFromCache, isTrue);
    final result = await controller.checkManually();

    expect(result!.release!.version.toString(), '1.7.0');
    expect(controller.latestAvailableRelease!.description, newDescription);
    expect(controller.lastStableRelease!.description, newDescription);
    expect(controller.releaseNotesAreFromCache, isFalse);
    final preferences = await SharedPreferences.getInstance();
    final pending =
        jsonDecode(
              preferences.getString(
                WindowsUpdateIndicatorController.pendingReleaseKey,
              )!,
            )
            as Map<String, dynamic>;
    final last =
        jsonDecode(
              preferences.getString(
                WindowsUpdateIndicatorController.lastReleaseKey,
              )!,
            )
            as Map<String, dynamic>;
    expect(pending['description'], newDescription);
    expect(last['description'], newDescription);
    controller.dispose();
  });

  test('a confirmed obsolete pending release is cleared', () async {
    final first = _controller(
      now: now,
      check: () async => _updateAvailable('1.8.0'),
    );
    await first.initialize();
    await first.checkCompletion;
    first.dispose();

    final installedNow = _controller(
      now: now.add(const Duration(hours: 25)),
      check: () async => _upToDate(installedVersion: '1.8.0'),
    );
    await installedNow.initialize();
    await installedNow.checkCompletion;
    expect(installedNow.state, WindowsUpdateIndicatorState.upToDate);
    expect(installedNow.latestAvailableRelease, isNull);
    expect(installedNow.hasPendingStartupPrompt, isFalse);
    installedNow.dispose();
  });

  test(
    'clears a dismissed cached release after installing that version',
    () async {
      final release = _release('1.7.0');
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: now
            .subtract(const Duration(minutes: 5))
            .toIso8601String(),
        WindowsUpdateIndicatorController.lastSuccessfulAtKey: now
            .subtract(const Duration(minutes: 5))
            .toIso8601String(),
        WindowsUpdateIndicatorController.lastStatusKey: 'updateAvailable',
        WindowsUpdateIndicatorController.lastReleaseKey: jsonEncode(
          _encodeRelease(release),
        ),
        WindowsUpdateIndicatorController.pendingReleaseKey: jsonEncode(
          _encodeRelease(release),
        ),
        WindowsUpdateIndicatorController.dismissedVersionKey: '1.7.0',
      });
      final controller = _controller(
        now: now,
        check: () async => fail('recent cached check should not run'),
        resetPreferences: false,
        installedVersionReader: () async => '1.7.0+20',
      );

      await controller.initialize();
      expect(controller.state, WindowsUpdateIndicatorState.upToDate);
      expect(controller.latestAvailableRelease, isNull);
      expect(await controller.takeStartupPrompt(), isNull);

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString(WindowsUpdateIndicatorController.lastStatusKey),
        'upToDate',
      );
      expect(
        preferences.getString(
          WindowsUpdateIndicatorController.pendingReleaseKey,
        ),
        isNull,
      );
      expect(
        preferences.getString(
          WindowsUpdateIndicatorController.dismissedVersionKey,
        ),
        isNull,
      );
      controller.dispose();
    },
  );

  test(
    'update selection emits release metadata without launching installer',
    () async {
      final controller = _controller(
        now: now,
        check: () async => _updateAvailable('1.8.0'),
      );
      await controller.initialize();
      await controller.checkCompletion;
      final selected = expectLater(
        controller.onUpdateAvailableSelected,
        emits(
          predicate<WindowsReleaseInfo>(
            (release) => release.version.toString() == '1.8.0',
          ),
        ),
      );

      controller.selectAvailableUpdate();

      await selected;
      controller.dispose();
    },
  );

  test(
    'non-Windows controller never checks or emits an update state',
    () async {
      var calls = 0;
      final controller = WindowsUpdateIndicatorController(
        isWindows: false,
        checkForUpdates: () async {
          calls++;
          return _upToDate();
        },
        clock: () => now,
      );

      await controller.initialize();
      expect(calls, 0);
      expect(await controller.checkManually(), isNull);
      expect(controller.latestAvailableRelease, isNull);
      controller.dispose();
    },
  );

  test(
    'download progress and cancellation delegate to the existing runner',
    () async {
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: now
            .toIso8601String(),
      });
      final started = Completer<void>();
      final operation = Completer<WindowsUpdateOperationResult>();
      var cancelCalls = 0;
      final controller = WindowsUpdateIndicatorController(
        isWindows: true,
        checkForUpdates: () async => _upToDate(),
        installedVersionReader: () async => '1.7.0',
        clock: () => now,
        downloadRunner: (check, {onProgress}) async {
          onProgress?.call(
            const WindowsUpdateProgress(downloadedBytes: 40, totalBytes: 100),
          );
          started.complete();
          return operation.future;
        },
        downloadCanceller: () => cancelCalls++,
      );
      await controller.initialize();

      final check = WindowsUpdateCheckResult(
        status: WindowsUpdateStatus.updateAvailable,
        installedVersion: SemanticVersion.tryParse('1.7.0'),
        release: _release('1.8.0'),
        installer: WindowsReleaseAsset(
          name: 'SuelosAR-Setup-1.8.0.exe',
          downloadUrl: Uri.parse(
            'https://example.invalid/SuelosAR-Setup-1.8.0.exe',
          ),
          size: 100,
        ),
        sha256: 'a' * 64,
      );
      final download = controller.startDownload(check: check);
      await started.future;

      expect(controller.downloadState, WindowsUpdateDownloadState.downloading);
      expect(controller.downloadProgress?.downloadedBytes, 40);
      controller.cancelDownload();
      expect(cancelCalls, 1);
      expect(controller.downloadState, WindowsUpdateDownloadState.cancelling);
      operation.complete(
        WindowsUpdateOperationResult(
          status: WindowsUpdateOperationStatus.cancelled,
        ),
      );
      await download;

      expect(controller.downloadState, WindowsUpdateDownloadState.cancelled);
      expect(controller.downloadProgress?.fraction, 0.4);
      controller.dispose();
    },
  );

  test(
    'download speed keeps its last valid sample and smooths rate changes',
    () async {
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: now
            .toIso8601String(),
      });
      final ready = Completer<void>();
      final operation = Completer<WindowsUpdateOperationResult>();
      late void Function(WindowsUpdateProgress progress) emitProgress;
      final controller = WindowsUpdateIndicatorController(
        isWindows: true,
        checkForUpdates: () async => _upToDate(),
        clock: () => now,
        downloadRunner: (check, {onProgress}) {
          emitProgress = onProgress!;
          ready.complete();
          return operation.future;
        },
      );
      await controller.initialize();

      final download = controller.startDownload(check: _downloadableCheck());
      await ready.future;
      emitProgress(
        const WindowsUpdateProgress(downloadedBytes: 0, totalBytes: 10000000),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1050));
      emitProgress(
        const WindowsUpdateProgress(
          downloadedBytes: 100000,
          totalBytes: 10000000,
        ),
      );
      final firstSpeed = controller.downloadSpeedBytesPerSecond;
      expect(firstSpeed, isNotNull);
      expect(firstSpeed, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 1050));
      emitProgress(
        const WindowsUpdateProgress(
          downloadedBytes: 100000,
          totalBytes: 10000000,
        ),
      );
      expect(controller.downloadSpeedBytesPerSecond, firstSpeed);

      await Future<void>.delayed(const Duration(milliseconds: 1050));
      emitProgress(
        const WindowsUpdateProgress(
          downloadedBytes: 1100000,
          totalBytes: 10000000,
        ),
      );
      final smoothedSpeed = controller.downloadSpeedBytesPerSecond!;
      expect(smoothedSpeed, greaterThan(firstSpeed!));
      expect(smoothedSpeed, lessThan(1000000));

      operation.complete(
        const WindowsUpdateOperationResult(
          status: WindowsUpdateOperationStatus.cancelled,
        ),
      );
      await download;
      controller.dispose();
    },
  );

  test(
    'completed update can be postponed without losing its verified file',
    () async {
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: now
            .toIso8601String(),
      });
      const installerPath =
          r'C:\Users\test\Temp\suelosar-update-1\SuelosAR-Setup-1.8.0.exe';
      final controller = WindowsUpdateIndicatorController(
        isWindows: true,
        checkForUpdates: () async => _upToDate(),
        clock: () => now,
        canInstallUpdate: true,
        downloadRunner: (check, {onProgress}) async =>
            WindowsUpdateOperationResult(
              status: WindowsUpdateOperationStatus.succeeded,
              installerPath: installerPath,
              sha256: 'a' * 64,
            ),
      );
      await controller.initialize();
      final check = _downloadableCheck();
      await controller.startDownload(check: check);

      expect(controller.downloadState, WindowsUpdateDownloadState.completed);
      expect(controller.verifiedInstallerPath, installerPath);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString(
          WindowsUpdateIndicatorController.verifiedInstallerPathKey,
        ),
        installerPath,
      );
      expect(
        preferences.getString(
          WindowsUpdateIndicatorController.verifiedInstallerSha256Key,
        ),
        'a' * 64,
      );
      controller.dismissDownloadPopup();
      expect(controller.hasDownloadPopup, isTrue);
      expect(controller.isDownloadPopupExpanded, isFalse);
      expect(controller.verifiedInstallerPath, installerPath);

      controller.toggleDownloadPopup();
      expect(controller.isDownloadPopupExpanded, isTrue);
      controller.dispose();
    },
  );

  test('restores a verified download after restarting the application', () async {
    const installerPath =
        r'C:\Users\test\AppData\Local\SuelosAR\Updates\suelosar-update-1\SuelosAR-Setup-1.8.0.exe';
    var checks = 0;
    var restoreCalls = 0;
    SharedPreferences.setMockInitialValues({
      WindowsUpdateIndicatorController.lastAttemptedAtKey: now
          .toIso8601String(),
      WindowsUpdateIndicatorController.lastStatusKey: 'updateAvailable',
      WindowsUpdateIndicatorController.pendingReleaseKey: jsonEncode(
        _encodeRelease(_release('1.8.0')),
      ),
      WindowsUpdateIndicatorController.verifiedInstallerPathKey: installerPath,
      WindowsUpdateIndicatorController.verifiedInstallerSha256Key: 'b' * 64,
      WindowsUpdateIndicatorController.verifiedInstallerVersionKey: '1.8.0',
    });
    final controller = WindowsUpdateIndicatorController(
      isWindows: true,
      checkForUpdates: () async {
        checks++;
        return _upToDate();
      },
      installedVersionReader: () async => '1.7.0',
      installerRestorer:
          ({required path, required expectedSha256, required version}) async {
            restoreCalls++;
            expect(path, installerPath);
            expect(expectedSha256, 'b' * 64);
            expect(version, '1.8.0');
            return true;
          },
      canInstallUpdate: true,
      clock: () => now,
    );

    await controller.initialize();

    expect(checks, 0);
    expect(restoreCalls, 1);
    expect(controller.downloadState, WindowsUpdateDownloadState.completed);
    expect(controller.verifiedInstallerPath, installerPath);
    expect(controller.canInstallCurrentUpdate, isTrue);
    expect(controller.isDownloadPopupExpanded, isTrue);
    expect(controller.hasPendingStartupPrompt, isFalse);
    controller.dispose();
  });

  test('clears persisted installer state if revalidation fails', () async {
    SharedPreferences.setMockInitialValues({
      WindowsUpdateIndicatorController.lastAttemptedAtKey: now
          .toIso8601String(),
      WindowsUpdateIndicatorController.lastStatusKey: 'updateAvailable',
      WindowsUpdateIndicatorController.pendingReleaseKey: jsonEncode(
        _encodeRelease(_release('1.8.0')),
      ),
      WindowsUpdateIndicatorController.verifiedInstallerPathKey:
          r'C:\Users\test\AppData\Local\SuelosAR\Updates\bad\SuelosAR-Setup-1.8.0.exe',
      WindowsUpdateIndicatorController.verifiedInstallerSha256Key: 'b' * 64,
      WindowsUpdateIndicatorController.verifiedInstallerVersionKey: '1.8.0',
    });
    final controller = WindowsUpdateIndicatorController(
      isWindows: true,
      checkForUpdates: () async => _upToDate(),
      installedVersionReader: () async => '1.7.0',
      installerRestorer:
          ({required path, required expectedSha256, required version}) async =>
              false,
      clock: () => now,
    );

    await controller.initialize();
    final preferences = await SharedPreferences.getInstance();

    expect(controller.downloadState, WindowsUpdateDownloadState.idle);
    expect(controller.canInstallCurrentUpdate, isFalse);
    expect(
      preferences.getString(
        WindowsUpdateIndicatorController.verifiedInstallerPathKey,
      ),
      isNull,
    );
    expect(
      preferences.getString(
        WindowsUpdateIndicatorController.verifiedInstallerSha256Key,
      ),
      isNull,
    );
    controller.dispose();
  });

  test(
    'installer operation is single-flight and closes only after helper ready',
    () async {
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: now
            .toIso8601String(),
      });
      final helperReady = Completer<WindowsUpdateOperationResult>();
      var launchCalls = 0;
      var closeCalls = 0;
      final controller = WindowsUpdateIndicatorController(
        isWindows: true,
        checkForUpdates: () async => _upToDate(),
        clock: () => now,
        canInstallUpdate: true,
        downloadRunner: (check, {onProgress}) async =>
            WindowsUpdateOperationResult(
              status: WindowsUpdateOperationStatus.succeeded,
              installerPath: r'C:\temp\SuelosAR-Setup-1.8.0.exe',
              sha256: 'a' * 64,
            ),
        installRunner: (path) {
          launchCalls++;
          return helperReady.future;
        },
        closeApplication: () async {
          closeCalls++;
        },
      );
      await controller.initialize();
      await controller.startDownload(check: _downloadableCheck());

      final firstInstall = controller.installAndRestart();
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.downloadState,
        WindowsUpdateDownloadState.preparingInstall,
      );
      final duplicateInstall = controller.installAndRestart();
      expect(launchCalls, 1);
      expect(closeCalls, 0);

      helperReady.complete(
        WindowsUpdateOperationResult(
          status: WindowsUpdateOperationStatus.succeeded,
        ),
      );
      await Future.wait([firstInstall, duplicateInstall]);
      expect(closeCalls, 1);
      expect(
        controller.downloadState,
        WindowsUpdateDownloadState.waitingForApplicationShutdown,
      );
      controller.dispose();
    },
  );

  test(
    'installation remains blocked when lifecycle validation is false',
    () async {
      SharedPreferences.setMockInitialValues({
        WindowsUpdateIndicatorController.lastAttemptedAtKey: now
            .toIso8601String(),
      });
      var launchCalls = 0;
      var closeCalls = 0;
      final controller = WindowsUpdateIndicatorController(
        isWindows: true,
        checkForUpdates: () async => _upToDate(),
        clock: () => now,
        downloadRunner: (check, {onProgress}) async =>
            WindowsUpdateOperationResult(
              status: WindowsUpdateOperationStatus.succeeded,
              installerPath: r'C:\temp\SuelosAR-Setup-1.8.0.exe',
              sha256: 'a' * 64,
            ),
        installRunner: (path) async {
          launchCalls++;
          return const WindowsUpdateOperationResult(
            status: WindowsUpdateOperationStatus.succeeded,
          );
        },
        closeApplication: () async {
          closeCalls++;
        },
      );
      await controller.initialize();
      await controller.startDownload(check: _downloadableCheck());
      await controller.installAndRestart();

      expect(launchCalls, 0);
      expect(closeCalls, 0);
      expect(controller.downloadState, WindowsUpdateDownloadState.completed);
      controller.dispose();
    },
  );
}

WindowsUpdateIndicatorController _controller({
  required DateTime now,
  required WindowsUpdateCheck check,
  String? initialStatus,
  DateTime? recentAttempt,
  InstalledAppVersionReader? installedVersionReader,
  bool resetPreferences = true,
}) {
  if (resetPreferences) {
    final values = <String, Object>{};
    if (initialStatus != null) {
      values[WindowsUpdateIndicatorController.lastStatusKey] = initialStatus;
    }
    if (recentAttempt != null) {
      values[WindowsUpdateIndicatorController.lastAttemptedAtKey] =
          recentAttempt.toIso8601String();
    }
    SharedPreferences.setMockInitialValues(values);
  }
  return WindowsUpdateIndicatorController(
    isWindows: true,
    checkForUpdates: check,
    installedVersionReader: installedVersionReader ?? () async => '1.7.0',
    clock: () => now,
  );
}

WindowsUpdateCheckResult _updateAvailable(
  String version, {
  String installedVersion = '1.7.0',
  String description = 'Notas de versión',
}) {
  final release = _release(version, description: description);
  return WindowsUpdateCheckResult(
    status: WindowsUpdateStatus.installerAssetMissing,
    installedVersion: SemanticVersion.tryParse(installedVersion),
    release: release,
  );
}

WindowsUpdateCheckResult _upToDate({String installedVersion = '1.7.0'}) {
  final installed = SemanticVersion.tryParse(installedVersion)!;
  return WindowsUpdateCheckResult(
    status: WindowsUpdateStatus.upToDate,
    installedVersion: installed,
    release: _release(installedVersion),
  );
}

WindowsUpdateCheckResult _downloadableCheck() => WindowsUpdateCheckResult(
  status: WindowsUpdateStatus.updateAvailable,
  installedVersion: SemanticVersion.tryParse('1.7.0'),
  release: _release('1.8.0'),
  installer: WindowsReleaseAsset(
    name: 'SuelosAR-Setup-1.8.0.exe',
    downloadUrl: Uri.parse('https://example.invalid/setup.exe'),
    size: 100,
  ),
  sha256: 'a' * 64,
);

WindowsUpdateCheckResult _failure() => const WindowsUpdateCheckResult(
  status: WindowsUpdateStatus.releaseUnavailable,
  error: WindowsUpdateError(
    code: WindowsUpdateErrorCode.networkUnavailable,
    message: 'offline',
  ),
);

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
