import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'analytics_events.dart';
import 'analytics_service.dart';

typedef FirebaseOptionsProvider = FirebaseOptions Function();

/// Firebase-backed analytics boundary and global Crashlytics bootstrap.
///
/// Firebase imports remain confined here so feature code depends only on
/// [AnalyticsService].
final class FirebaseAnalyticsService implements AnalyticsService {
  FirebaseAnalyticsService._(this._analytics, this._crashlytics);

  final FirebaseAnalytics _analytics;
  final FirebaseCrashlytics _crashlytics;

  static bool _errorHandlersInstalled = false;

  /// Initializes Firebase once on platforms supported by Analytics and
  /// Crashlytics. A failure leaves the process-wide no-op service installed.
  static Future<bool> initialize({
    required FirebaseOptionsProvider optionsProvider,
  }) async {
    if (!_supportsFirebaseTelemetry) return false;

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: optionsProvider());
      }

      final service = FirebaseAnalyticsService._(
        FirebaseAnalytics.instance,
        FirebaseCrashlytics.instance,
      );
      AnalyticsService.register(service);
      service._installErrorHandlers();
      return true;
    } catch (error, stackTrace) {
      debugPrint('Firebase analytics initialization skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  static bool get _supportsFirebaseTelemetry {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.windows => false,
    };
  }

  void _installErrorHandlers() {
    if (_errorHandlersInstalled) return;
    _errorHandlersInstalled = true;

    final previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (previousFlutterErrorHandler != null) {
        previousFlutterErrorHandler(details);
      } else {
        FlutterError.presentError(details);
      }
      unawaited(_recordFlutterError(details));
    };

    final previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      unawaited(_recordPlatformError(error, stackTrace));
      return previousPlatformErrorHandler?.call(error, stackTrace) ?? false;
    };
  }

  Future<void> _recordFlutterError(FlutterErrorDetails details) async {
    try {
      await _crashlytics.recordFlutterFatalError(details);
    } catch (error) {
      debugPrint('Crashlytics could not record a Flutter error: $error');
    }
  }

  Future<void> _recordPlatformError(Object error, StackTrace stackTrace) async {
    try {
      await _crashlytics.recordError(error, stackTrace, fatal: true);
    } catch (recordingError) {
      debugPrint(
        'Crashlytics could not record a platform error: $recordingError',
      );
    }
  }

  @override
  Future<void> logAppOpen() => _safely(_analytics.logAppOpen);

  @override
  Future<void> logFavoriteAdded() => _log(AnalyticsEvents.favoriteAdded);

  @override
  Future<void> logFeedbackOpened() => _log(AnalyticsEvents.feedbackOpened);

  @override
  Future<void> logGpsEnabled() => _log(AnalyticsEvents.gpsEnabled);

  @override
  Future<void> logMapOpened() => _log(AnalyticsEvents.mapOpened);

  @override
  Future<void> logMarkerCreated() => _log(AnalyticsEvents.markerCreated);

  @override
  Future<void> logMeasureArea() => _log(AnalyticsEvents.measureArea);

  @override
  Future<void> logMeasureDistance() => _log(AnalyticsEvents.measureDistance);

  @override
  Future<void> logPdfOpened() => _log(AnalyticsEvents.pdfOpened);

  @override
  Future<void> logSearch() => _log(AnalyticsEvents.search);

  @override
  Future<void> logSyncCompleted(Duration duration) => _log(
    AnalyticsEvents.syncCompleted,
    parameters: <String, Object>{'duration_ms': duration.inMilliseconds},
  );

  @override
  Future<void> logSyncFailed(String reason) => _log(
    AnalyticsEvents.syncFailed,
    parameters: <String, Object>{'reason': _normalizeSyncFailure(reason)},
  );

  @override
  Future<void> logSyncStarted() => _log(AnalyticsEvents.syncStarted);

  Future<void> _log(String name, {Map<String, Object>? parameters}) =>
      _safely(() => _analytics.logEvent(name: name, parameters: parameters));

  Future<void> _safely(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      // Analytics must never affect an application workflow.
    }
  }

  static String _normalizeSyncFailure(String reason) {
    final normalized = reason.toLowerCase();
    if (normalized.contains('timeout') || normalized.contains('timed out')) {
      return 'timeout';
    }
    if (normalized.contains('auth') ||
        normalized.contains('unauthorized') ||
        normalized.contains('forbidden') ||
        normalized.contains('jwt') ||
        normalized.contains('sign in') ||
        normalized.contains('token') ||
        normalized.contains('401') ||
        normalized.contains('403')) {
      return 'authentication';
    }
    if (normalized.contains('socket') ||
        normalized.contains('network') ||
        normalized.contains('offline') ||
        normalized.contains('connection') ||
        normalized.contains('host lookup') ||
        normalized.contains('unreachable') ||
        normalized.contains('clientexception')) {
      return 'network';
    }
    if (normalized.contains('server') ||
        normalized.contains('supabase') ||
        normalized.contains('postgrest') ||
        normalized.contains('postgres') ||
        normalized.contains('500') ||
        normalized.contains('502') ||
        normalized.contains('503') ||
        normalized.contains('504')) {
      return 'server';
    }
    return 'unknown';
  }
}
