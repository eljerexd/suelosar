/// Application-wide analytics boundary.
///
/// Feature code should depend only on this interface and use its typed methods;
/// event names and Firebase calls remain private to the implementation.
abstract interface class AnalyticsService {
  static AnalyticsService _instance = const _InactiveAnalyticsService();

  static AnalyticsService get instance => _instance;

  /// Registers the process-wide implementation during application startup.
  static void register(AnalyticsService service) {
    _instance = service;
  }

  Future<void> logAppOpen();

  Future<void> logMapOpened();

  Future<void> logPdfOpened();

  Future<void> logSearch();

  Future<void> logMeasureArea();

  Future<void> logMeasureDistance();

  Future<void> logMarkerCreated();

  Future<void> logFavoriteAdded();

  Future<void> logGpsEnabled();

  Future<void> logSyncStarted();

  Future<void> logSyncCompleted(Duration duration);

  Future<void> logSyncFailed(String reason);

  Future<void> logFeedbackOpened();
}

class _InactiveAnalyticsService implements AnalyticsService {
  const _InactiveAnalyticsService();

  @override
  Future<void> logAppOpen() async {}

  @override
  Future<void> logFavoriteAdded() async {}

  @override
  Future<void> logFeedbackOpened() async {}

  @override
  Future<void> logGpsEnabled() async {}

  @override
  Future<void> logMapOpened() async {}

  @override
  Future<void> logMarkerCreated() async {}

  @override
  Future<void> logMeasureArea() async {}

  @override
  Future<void> logMeasureDistance() async {}

  @override
  Future<void> logPdfOpened() async {}

  @override
  Future<void> logSearch() async {}

  @override
  Future<void> logSyncCompleted(Duration duration) async {}

  @override
  Future<void> logSyncFailed(String reason) async {}

  @override
  Future<void> logSyncStarted() async {}
}
