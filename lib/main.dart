import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';

import 'analytics/firebase_analytics_service.dart';
import 'analytics/analytics_service.dart';
import 'app/suelos_ar_app.dart';
import 'firebase_options.dart';
import 'services/device_identity_service.dart';
import 'services/local_sync_migration_service.dart';
import 'services/settings_service.dart';
import 'services/windows_update_indicator_controller.dart';
import 'services/windows_update_http_client.dart';
import 'services/windows_update_preview_mode.dart';
import 'services/windows_update_success_confirmation.dart';
import 'sync/sync_bootstrap.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_cleanupUpdateHelperDirectory(args));

  await FirebaseAnalyticsService.initialize(
    optionsProvider: () => DefaultFirebaseOptions.currentPlatform,
  );
  unawaited(AnalyticsService.instance.logAppOpen());
  await DeviceIdentityService.instance.initialize();
  await const LocalSyncMigrationService().migrate();
  await SettingsService.instance.initialize();
  unawaited(SyncBootstrap.start());
  final updatePreview =
      updatePreviewModeEnabled &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows;
  final isWindowsApp =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  http.Client? windowsUpdateClient;
  if (isWindowsApp && !updatePreview) {
    try {
      windowsUpdateClient = await createWindowsUpdateHttpClient();
    } catch (error, stackTrace) {
      debugPrint('Windows updater transport initialization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }
  final windowsUpdateController = isWindowsApp
      ? updatePreview
            ? WindowsUpdateIndicatorController.forDevelopmentPreview()
            : WindowsUpdateIndicatorController.forWindows(
                client: windowsUpdateClient,
              )
      : null;
  runApp(
    SuelosARApp(
      windowsUpdateController: windowsUpdateController,
      windowsUpdateStartupMessage: _startupUpdateMessage(args),
      windowsUpdateSuccessConfirmation: isWindowsApp
          ? WindowsUpdateSuccessConfirmation.fromArguments(args)
          : null,
    ),
  );
}

String? _startupUpdateMessage(List<String> args) {
  final outcome = _argumentValue(args, '--suelosar-update-result=');
  final version = _argumentValue(args, '--suelosar-update-version=');
  if (version == null ||
      !RegExp(
        r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
      ).hasMatch(version)) {
    return null;
  }
  return switch (outcome) {
    'cancelled' => 'La instalación de la versión $version se canceló.',
    'recovered' =>
      'No se completó la actualización a $version. SuelosAR volvió a abrirse; verificá la versión instalada.',
    _ => null,
  };
}

Future<void> _cleanupUpdateHelperDirectory(List<String> args) async {
  final path = _argumentValue(args, '--suelosar-update-helper-cleanup=');
  final processIdText = _argumentValue(args, '--suelosar-update-helper-pid=');
  final processId = int.tryParse(processIdText ?? '');
  if (path == null || processId == null || processId <= 0) return;

  final directory = Directory(path);
  final tempRoot = Directory.systemTemp.absolute.uri.normalizePath();
  final candidate = directory.absolute.uri.normalizePath();
  final normalizedRoot = tempRoot.path.endsWith('/')
      ? tempRoot
      : tempRoot.replace(path: '${tempRoot.path}/');
  final directoryName = directory.path
      .split(Platform.pathSeparator)
      .last
      .toLowerCase();
  if (!candidate.path.toLowerCase().startsWith(
        normalizedRoot.path.toLowerCase(),
      ) ||
      !directoryName.startsWith('suelosar-update-helper-')) {
    return;
  }

  var helperExited = false;
  for (var attempt = 0; attempt < 300; attempt++) {
    try {
      final process = await Process.start('tasklist', [
        '/FI',
        'PID eq $processId',
        '/FO',
        'CSV',
        '/NH',
      ], runInShell: false);
      final output = await process.stdout
          .transform(systemEncoding.decoder)
          .join();
      await process.exitCode;
      if (!output.contains('"$processId"')) {
        helperExited = true;
        break;
      }
    } catch (_) {
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  if (!helperExited) return;

  try {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.directory) {
      await directory.delete(recursive: true);
    }
  } on FileSystemException {
    // Preserve the helper directory if Windows still has a file open.
  }
}

String? _argumentValue(List<String> args, String prefix) {
  for (final argument in args) {
    if (argument.startsWith(prefix)) return argument.substring(prefix.length);
  }
  return null;
}
