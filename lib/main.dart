import 'dart:async';

import 'package:flutter/material.dart';

import 'app/suelos_ar_app.dart';
import 'services/device_identity_service.dart';
import 'services/local_sync_migration_service.dart';
import 'services/settings_service.dart';
import 'sync/sync_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await DeviceIdentityService.instance.initialize();
  await const LocalSyncMigrationService().migrate();
  await SettingsService.instance.initialize();
  unawaited(SyncBootstrap.start());
  runApp(const SuelosARApp());
}
