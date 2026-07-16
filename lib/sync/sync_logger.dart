import 'package:flutter/foundation.dart';

class SyncLogEntry {
  SyncLogEntry({
    required this.event,
    this.fields = const <String, Object?>{},
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().toUtc();

  final DateTime timestamp;
  final String event;
  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => <String, Object?>{
    'timestamp': timestamp.toIso8601String(),
    'event': event,
    'fields': fields,
  };
}

typedef SyncLogSink = void Function(SyncLogEntry entry);

class SyncLogger {
  SyncLogger({this.sink});

  static final SyncLogger instance = SyncLogger();
  final SyncLogSink? sink;

  void log(String event, [Map<String, Object?> fields = const {}]) {
    final entry = SyncLogEntry(event: event, fields: fields);
    sink?.call(entry);
    if (kDebugMode) debugPrint('[Sync] ${entry.toJson()}');
  }
}
