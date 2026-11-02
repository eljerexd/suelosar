import 'dart:async';

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
        const WindowsUpdateOperationResult(
          status: WindowsUpdateOperationStatus.cancelled,
        ),
      );
      await download;

      expect(controller.downloadState, WindowsUpdateDownloadState.cancelled);
      expect(controller.downloadProgress?.fraction, 0.4);
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

WindowsUpdateCheckResult _updateAvailable(String version) {
  final release = _release(version);
  return WindowsUpdateCheckResult(
    status: WindowsUpdateStatus.installerAssetMissing,
    installedVersion: const SemanticVersion(major: 1, minor: 7, patch: 0),
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

WindowsUpdateCheckResult _failure() => const WindowsUpdateCheckResult(
  status: WindowsUpdateStatus.releaseUnavailable,
  error: WindowsUpdateError(
    code: WindowsUpdateErrorCode.networkUnavailable,
    message: 'offline',
  ),
);

WindowsReleaseInfo _release(String version) => WindowsReleaseInfo(
  tag: 'v$version',
  version: SemanticVersion.tryParse(version)!,
  name: 'SuelosAR $version',
  description: 'Notas de versión',
  publishedAt: DateTime.utc(2026, 10, 31),
  assets: const [],
  htmlUrl: Uri.parse(
    'https://github.com/eljerexd/suelosar/releases/tag/v$version',
  ),
);
