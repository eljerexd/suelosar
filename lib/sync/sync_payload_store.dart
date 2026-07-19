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
  }) => putAll(<String, Map<String, Object?>>{
    reference: payload,
  }, tombstoneReferences: tombstone ? <String>{reference} : const <String>{});

  Future<void> putAll(
    Map<String, Map<String, Object?>> additions, {
    Set<String> tombstoneReferences = const <String>{},
  }) async {
    if (additions.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    final payloads = _readMap(preferences, storageKey)..addAll(additions);
    await preferences.setString(storageKey, jsonEncode(payloads));
    if (tombstoneReferences.isNotEmpty) {
      final tombstones = _readMap(preferences, tombstoneStorageKey);
      for (final reference in tombstoneReferences) {
        final payload = additions[reference];
        if (payload != null) tombstones[reference] = payload;
      }
      await preferences.setString(tombstoneStorageKey, jsonEncode(tombstones));
    }
  }

  Future<Map<String, Object?>?> get(String reference) async {
    final preferences = await SharedPreferences.getInstance();
    final value = _readMap(preferences, storageKey)[reference];
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  Future<void> remove(String reference) => removeAll(<String>{reference});

  Future<void> removeAll(Iterable<String> references) async {
    final removed = references.toSet();
    if (removed.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    final payloads = _readMap(preferences, storageKey)
      ..removeWhere((key, _) => removed.contains(key));
    final tombstones = _readMap(preferences, tombstoneStorageKey)
      ..removeWhere((key, _) => removed.contains(key));
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
