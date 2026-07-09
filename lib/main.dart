import 'package:flutter/material.dart';

import 'app/suelos_ar_app.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.instance.initialize();
  runApp(const SuelosARApp());
}
