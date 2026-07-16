import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_backend_adapter.dart';
import 'sync_operation.dart';
import 'sync_payload_policy.dart';
import 'sync_state.dart';

class SyncAuthenticationRequiredException implements Exception {
  const SyncAuthenticationRequiredException();

  @override
  String toString() => 'An authenticated Supabase session is required.';
}

class SupabaseSyncBackendAdapter implements SyncBackendAdapter {
  factory SupabaseSyncBackendAdapter({
    required SupabaseClient client,
    required String deviceUuid,
  }) => SupabaseSyncBackendAdapter._(client, deviceUuid);

  SupabaseSyncBackendAdapter._(this._client, this._deviceUuid);

  final SupabaseClient _client;
  final String _deviceUuid;

  static const Map<SyncEntityType, String> _tables = {
    SyncEntityType.marker: 'markers',
    SyncEntityType.measurement: 'measurements',
    SyncEntityType.favorite: 'favorites',
  };

  @override
  Future<void> upload(List<PreparedSyncUpload> batch) async {
    _requireAuthentication();
    final latestByEntity = <String, PreparedSyncUpload>{};
    for (final item in batch) {
      latestByEntity['${item.operation.entityType.name}:${item.operation.uuid}'] =
          item;
    }

    final grouped = <SyncEntityType, List<Map<String, Object?>>>{};
    for (final item in latestByEntity.values) {
      if (!SyncPayloadPolicy.synchronizes(item.operation.entityType)) continue;
      grouped
          .putIfAbsent(item.operation.entityType, () => [])
          .add(_remoteRow(item));
    }
    for (final entry in grouped.entries) {
      await _client
          .from(_tables[entry.key]!)
          .upsert(entry.value, onConflict: 'uuid');
    }
  }

  @override
  Future<SyncDownloadBatch> download(SyncDownloadRequest request) async {
    _requireAuthentication();
    final cursors = _decodeCursors(request.cursor);
    final changes = <Map<String, Object?>>[];
    final nextCursors = Map<String, _TableCursor>.from(cursors);

    for (final entry in _tables.entries) {
      final table = entry.value;
      final cursor = cursors[table];
      final List<Map<String, dynamic>> rows;
      if (cursor == null) {
        rows = await _client
            .from(table)
            .select(
              'uuid, device_uuid, created_at, updated_at, deleted_at, '
              'sync_state, payload',
            )
            .order('updated_at')
            .order('uuid')
            .limit(request.limit);
      } else {
        final timestamp = cursor.updatedAt.toUtc().toIso8601String();
        rows = await _client
            .from(table)
            .select(
              'uuid, device_uuid, created_at, updated_at, deleted_at, '
              'sync_state, payload',
            )
            .or(
              'updated_at.gt.$timestamp,'
              'and(updated_at.eq.$timestamp,uuid.gt.${cursor.uuid})',
            )
            .order('updated_at')
            .order('uuid')
            .limit(request.limit);
      }

      for (final row in rows) {
        changes.add(<String, Object?>{
          'entityType': entry.key.name,
          'uuid': row['uuid'],
          'deviceUuid': row['device_uuid'],
          'createdAt': row['created_at'],
          'updatedAt': row['updated_at'],
          'deletedAt': row['deleted_at'],
          'syncState': row['sync_state'],
          'payload': row['payload'],
        });
      }
      if (rows.isNotEmpty) {
        final last = rows.last;
        final updatedAt = DateTime.parse(last['updated_at'].toString()).toUtc();
        nextCursors[table] = _TableCursor(
          updatedAt: updatedAt,
          uuid: last['uuid'].toString(),
        );
      }
    }

    changes.sort((left, right) {
      final leftDate = DateTime.parse(left['updatedAt'].toString());
      final rightDate = DateTime.parse(right['updatedAt'].toString());
      final dateComparison = leftDate.compareTo(rightDate);
      if (dateComparison != 0) return dateComparison;
      return left['uuid'].toString().compareTo(right['uuid'].toString());
    });
    return SyncDownloadBatch(
      changes: List<Map<String, Object?>>.unmodifiable(changes),
      nextCursor: _encodeCursors(nextCursors),
    );
  }

  Map<String, Object?> _remoteRow(PreparedSyncUpload item) {
    final payload = SyncPayloadPolicy.forUpload(
      item.operation.entityType,
      item.payload,
    )..['syncState'] = SyncState.synced.name;
    final createdAt =
        _dateFrom(payload['createdAt']) ?? item.operation.createdAt;
    final updatedAt =
        _dateFrom(payload['updatedAt']) ?? item.operation.createdAt;
    final deletedAt = _dateFrom(payload['deletedAt']);
    return <String, Object?>{
      'uuid': item.operation.uuid,
      'device_uuid': _deviceUuid,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
      'sync_state': SyncState.synced.name,
      'payload': payload,
    };
  }

  void _requireAuthentication() {
    if (_client.auth.currentUser == null) {
      throw const SyncAuthenticationRequiredException();
    }
  }

  DateTime? _dateFrom(Object? value) =>
      DateTime.tryParse(value?.toString() ?? '')?.toUtc();

  Map<String, _TableCursor> _decodeCursors(String? encoded) {
    if (encoded == null || encoded.isEmpty) return {};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return {};
      final cursors = <String, _TableCursor>{};
      for (final entry in decoded.entries) {
        if (!_tables.containsValue(entry.key)) continue;
        final cursor = _TableCursor.fromJson(entry.value);
        if (cursor != null) cursors[entry.key] = cursor;
      }
      return cursors;
    } catch (_) {
      return {};
    }
  }

  String _encodeCursors(Map<String, _TableCursor> cursors) => jsonEncode({
    for (final entry in cursors.entries) entry.key: entry.value.toJson(),
  });
}

class _TableCursor {
  const _TableCursor({required this.updatedAt, required this.uuid});

  final DateTime updatedAt;
  final String uuid;

  Map<String, String> toJson() => {
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'uuid': uuid,
  };

  static _TableCursor? fromJson(Object? value) {
    if (value is! Map) return null;
    final updatedAt = DateTime.tryParse(value['updatedAt']?.toString() ?? '');
    final uuid = value['uuid']?.toString() ?? '';
    if (updatedAt == null || uuid.isEmpty) return null;
    return _TableCursor(updatedAt: updatedAt.toUtc(), uuid: uuid);
  }
}
