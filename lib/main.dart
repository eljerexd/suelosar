import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'analytics/firebase_analytics_service.dart';
import 'analytics/analytics_service.dart';
import 'app/suelos_ar_app.dart';
import 'firebase_options.dart';
import 'services/device_identity_service.dart';
import 'services/local_sync_migration_service.dart';
import 'services/settings_service.dart';
import 'services/windows_update_indicator_controller.dart';
import 'services/windows_update_preview_mode.dart';
import 'sync/sync_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  final windowsUpdateController =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
      ? updatePreview
            ? WindowsUpdateIndicatorController.forDevelopmentPreview()
            : WindowsUpdateIndicatorController.forWindows()
      : null;
  runApp(SuelosARApp(windowsUpdateController: windowsUpdateController));
}
