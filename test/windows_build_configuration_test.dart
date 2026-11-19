import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'official Windows Release build enables MapLibre and Supabase defines',
    () {
      final script = File('build_windows.bat').readAsStringSync();

      expect(script, contains('--dart-define=SUelosAR_MAPLIBRE_NATIVE=true'));
      expect(
        script,
        contains('--dart-define-from-file=.vscode/supabase.env.json'),
      );
      expect(script, isNot(contains('SUelosAR_UPDATE_STAGING_BASE')));
      expect(script, isNot(contains('SUelosAR_UPDATE_REQUIRE_DIFFERENTIAL')));
    },
  );
}
