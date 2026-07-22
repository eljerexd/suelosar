/// Canonical event names reserved for SuelosAR analytics.
///
/// Add future event names here first, then expose them through a strongly typed
/// method on [AnalyticsService]. Screens and repositories must never use raw
/// event-name strings or import a Firebase analytics package directly.
abstract final class AnalyticsEvents {
  static const String appOpen = 'app_open';
  static const String mapOpened = 'map_opened';
  static const String pdfOpened = 'pdf_opened';
  static const String search = 'search';
  static const String measureArea = 'measure_area';
  static const String measureDistance = 'measure_distance';
  static const String markerCreated = 'marker_created';
  static const String favoriteAdded = 'favorite_added';
  static const String gpsEnabled = 'gps_enabled';
  static const String syncStarted = 'sync_started';
  static const String syncCompleted = 'sync_completed';
  static const String syncFailed = 'sync_failed';
  static const String feedbackOpened = 'feedback_opened';
}
