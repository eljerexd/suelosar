import 'dart:async';

import 'analytics_service.dart';

/// Records an explicitly submitted non-empty search without retaining or
/// forwarding the query itself.
void logSubmittedSearch(String query) {
  if (query.trim().isEmpty) return;
  unawaited(AnalyticsService.instance.logSearch());
}
