import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SyncPayloadStore {
  const SyncPayloadStore();

  static const String storageKey = 'sync.operation_payloads';
  static const String tombstoneStorageKey = 'sync.tombstones';

  Future<void> put(
    String reference,
    Map<String, Object?> payload, {
    bool tombstone = false,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final payloads = _readMap(preferences, storageKey);
    payloads[reference] = payload;
    await preferences.setString(storageKey, jsonEncode(payloads));
    if (tombstone) {
      final tombstones = _readMap(preferences, tombstoneStorageKey);
      tombstones[reference] = payload;
      await preferences.setString(tombstoneStorageKey, jsonEncode(tombstones));
    }
  }

  Future<Map<String, Object?>?> get(String reference) async {
    final preferences = await SharedPreferences.getInstance();
    final value = _readMap(preferences, storageKey)[reference];
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  Future<void> remove(String reference) async {
    final preferences = await SharedPreferences.getInstance();
    final payloads = _readMap(preferences, storageKey)..remove(reference);
    final tombstones = _readMap(preferences, tombstoneStorageKey)
      ..remove(reference);
    await preferences.setString(storageKey, jsonEncode(payloads));
    await preferences.setString(tombstoneStorageKey, jsonEncode(tombstones));
  }

  Future<List<Map<String, Object?>>> readTombstones() async {
    final preferences = await SharedPreferences.getInstance();
    return _readMap(preferences, tombstoneStorageKey).values
        .whereType<Map>()
        .map((value) => Map<String, Object?>.from(value))
        .toList(growable: false);
  }

  Map<String, dynamic> _readMap(SharedPreferences preferences, String key) {
    final encoded = preferences.getString(key);
    if (encoded == null) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(encoded);
      return decoded is Map<String, dynamic>
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
