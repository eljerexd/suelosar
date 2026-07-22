import 'package:suelosar/analytics/analytics_service.dart';

class RecordingAnalyticsService implements AnalyticsService {
  final List<String> events = <String>[];
  final List<Map<String, Object>> parameters = <Map<String, Object>>[];

  int count(String event) => events.where((value) => value == event).length;

  Future<void> _record(
    String event, [
    Map<String, Object> eventParameters = const <String, Object>{},
  ]) async {
    events.add(event);
    parameters.add(eventParameters);
  }

  @override
  Future<void> logAppOpen() => _record('app_open');

  @override
  Future<void> logFavoriteAdded() => _record('favorite_added');

  @override
  Future<void> logFeedbackOpened() => _record('feedback_opened');

  @override
  Future<void> logGpsEnabled() => _record('gps_enabled');

  @override
  Future<void> logMapOpened() => _record('map_opened');

  @override
  Future<void> logMarkerCreated() => _record('marker_created');

  @override
  Future<void> logMeasureArea() => _record('measure_area');

  @override
  Future<void> logMeasureDistance() => _record('measure_distance');

  @override
  Future<void> logPdfOpened() => _record('pdf_opened');

  @override
  Future<void> logSearch() => _record('search');

  @override
  Future<void> logSyncCompleted(Duration duration) => _record(
    'sync_completed',
    <String, Object>{'duration_ms': duration.inMilliseconds},
  );

  @override
  Future<void> logSyncFailed(String reason) =>
      _record('sync_failed', <String, Object>{'reason': reason});

  @override
  Future<void> logSyncStarted() => _record('sync_started');
}
