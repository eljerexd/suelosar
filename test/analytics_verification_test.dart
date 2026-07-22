import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suelosar/analytics/analytics_actions.dart';
import 'package:suelosar/analytics/analytics_service.dart';
import 'package:suelosar/gis/gis_layer.dart';
import 'package:suelosar/gis/gis_map_screen.dart';
import 'package:suelosar/gis/gis_repository.dart';

import 'support/recording_analytics_service.dart';

void main() {
  test('analytics catalog and parameter allowlist remain privacy safe', () {
    const expectedEvents = <String>{
      'app_open',
      'map_opened',
      'pdf_opened',
      'search',
      'measure_area',
      'measure_distance',
      'marker_created',
      'favorite_added',
      'gps_enabled',
      'sync_started',
      'sync_completed',
      'sync_failed',
      'feedback_opened',
    };
    final eventSource = File(
      'lib/analytics/analytics_events.dart',
    ).readAsStringSync();
    final declaredEvents = RegExp(
      r"static const String [a-zA-Z]+ = '([^']+)';",
    ).allMatches(eventSource).map((match) => match.group(1)).toSet();
    expect(declaredEvents, expectedEvents);

    final firebaseSource = File(
      'lib/analytics/firebase_analytics_service.dart',
    ).readAsStringSync();
    final parameterKeys = RegExp(
      r"'([a-z_]+)'\s*:",
    ).allMatches(firebaseSource).map((match) => match.group(1)).toSet();
    expect(parameterKeys, <String>{'duration_ms', 'reason'});
  });

  test('Firebase Analytics remains behind the application boundary', () {
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in dartFiles) {
      if (file.path.endsWith('firebase_analytics_service.dart')) continue;
      final source = file.readAsStringSync();
      expect(
        source,
        isNot(contains('package:firebase_analytics')),
        reason: file.path,
      );
      expect(
        RegExp(r'\.logEvent\s*\(').hasMatch(source),
        isFalse,
        reason: file.path,
      );
      expect(
        RegExp(r'\bawait\s+AnalyticsService\.instance\.log').hasMatch(source),
        isFalse,
        reason: file.path,
      );
    }
  });

  test('application and terminal sync event callsites are singular', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    expect(_occurrences(mainSource, '.logAppOpen()'), 1);

    final mapSource = File('lib/gis/gis_map_screen.dart').readAsStringSync();
    expect(_occurrences(mapSource, '.logMapOpened()'), 1);
    expect(_occurrences(mapSource, '.logMeasureArea()'), 1);
    expect(_occurrences(mapSource, '.logMeasureDistance()'), 1);
    expect(_occurrences(mapSource, '.logMarkerCreated()'), 1);
    expect(_occurrences(mapSource, '.logFavoriteAdded()'), 1);
    expect(_occurrences(mapSource, '.logGpsEnabled()'), 1);

    final pdfSource = File(
      'lib/screens/pdf_viewer_screen.dart',
    ).readAsStringSync();
    expect(_occurrences(pdfSource, '.logPdfOpened()'), 1);
    expect(pdfSource, contains('if (_pdfOpenLogged) return;'));

    final searchSource = File(
      'lib/analytics/analytics_actions.dart',
    ).readAsStringSync();
    expect(_occurrences(searchSource, '.logSearch()'), 1);

    final soilMapsSource = File(
      'lib/screens/soil_maps_screen.dart',
    ).readAsStringSync();
    expect(_occurrences(soilMapsSource, '.logFavoriteAdded()'), 1);

    final settingsSource = File(
      'lib/screens/settings_screen.dart',
    ).readAsStringSync();
    expect(_occurrences(settingsSource, '.logGpsEnabled()'), 1);
    expect(_occurrences(settingsSource, '.logFeedbackOpened()'), 1);

    final syncSource = File(
      'lib/sync/sync_coordinator.dart',
    ).readAsStringSync();
    expect(_occurrences(syncSource, '.logSyncStarted()'), 1);
    expect(_occurrences(syncSource, '.logSyncCompleted('), 1);
    expect(_occurrences(syncSource, '.logSyncFailed('), 2);
  });

  test('submitted searches log once without forwarding their text', () async {
    final analytics = RecordingAnalyticsService();
    AnalyticsService.register(analytics);

    logSubmittedSearch('  ');
    logSubmittedSearch('private search content');
    await Future<void>.delayed(Duration.zero);

    expect(analytics.events, <String>['search']);
    expect(analytics.parameters, everyElement(isEmpty));
  });

  testWidgets('map opening logs once and rebuilds do not duplicate it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final analytics = RecordingAnalyticsService();
    AnalyticsService.register(analytics);
    const repository = _EmptyRepository();

    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: repository)),
    );
    await tester.pump();
    expect(analytics.count('map_opened'), 1);

    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: repository)),
    );
    await tester.pump();
    expect(analytics.count('map_opened'), 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      const MaterialApp(home: GisMapScreen(repository: repository)),
    );
    await tester.pump();
    expect(analytics.count('map_opened'), 2);
  });

  test('Crashlytics production fatal handlers remain configured', () {
    final serviceSource = File(
      'lib/analytics/firebase_analytics_service.dart',
    ).readAsStringSync();
    expect(serviceSource, contains('FlutterError.onError ='));
    expect(serviceSource, contains('recordFlutterFatalError'));
    expect(serviceSource, contains('PlatformDispatcher.instance.onError ='));
    expect(
      serviceSource,
      contains('recordError(error, stackTrace, fatal: true)'),
    );
  });
}

int _occurrences(String source, String pattern) =>
    RegExp(RegExp.escape(pattern)).allMatches(source).length;

class _EmptyRepository implements GisRepository {
  const _EmptyRepository();

  @override
  Future<GisArchiveInfo> initialize() async => const GisArchiveInfo(
    minZoom: 7,
    maxZoom: 14,
    centerLatitude: -36.5,
    centerLongitude: -60,
  );

  @override
  Future<GisLayer> loadTile(GisTileCoordinates coordinates) async => GisLayer(
    id: '${coordinates.zoom}-${coordinates.x}-${coordinates.y}',
    name: 'empty',
    features: const [],
  );

  @override
  Future<void> close() async {}
}
