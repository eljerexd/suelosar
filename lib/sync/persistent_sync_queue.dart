import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'sync_operation.dart';

class PersistentSyncQueue {
  PersistentSyncQueue({this.storageKey = 'sync.operation_queue'});

  final String storageKey;
  Future<void> _writeChain = Future<void>.value();

  Future<List<SyncOperation>> readAll() async {
    await _writeChain;
    final preferences = await SharedPreferences.getInstance();
    return _decode(preferences.getStringList(storageKey));
  }

  Future<void> enqueue(SyncOperation operation) =>
      _write((operations) => operations..add(operation));

  Future<void> enqueueAll(Iterable<SyncOperation> newOperations) {
    final additions = newOperations.toList(growable: false);
    if (additions.isEmpty) return Future<void>.value();
    return _write((operations) => operations..addAll(additions));
  }

  Future<void> cancel(String operationId) => _write(
    (operations) =>
        operations
          ..removeWhere((operation) => operation.operationId == operationId),
  );

  Future<void> removeAll(Iterable<String> operationIds) {
    final ids = operationIds.toSet();
    return _write(
      (operations) =>
          operations
            ..removeWhere((operation) => ids.contains(operation.operationId)),
    );
  }

  Future<void> incrementRetry(String operationId) => _write((operations) {
    final index = operations.indexWhere(
      (operation) => operation.operationId == operationId,
    );
    if (index != -1) {
      final operation = operations[index];
      operations[index] = operation.copyWith(
        retryCount: operation.retryCount + 1,
      );
    }
    return operations;
  });

  Future<List<SyncOperation>> takeBatch(int maximum) async {
    final operations = await readAll();
    return operations.take(maximum).toList(growable: false);
  }

  Future<void> _write(
    List<SyncOperation> Function(List<SyncOperation>) update,
  ) {
    final completer = Completer<void>();
    _writeChain = _writeChain.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        final operations = _decode(preferences.getStringList(storageKey));
        final updated = update(operations);
        await preferences.setStringList(
          storageKey,
          updated.map((operation) => jsonEncode(operation.toJson())).toList(),
        );
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  List<SyncOperation> _decode(List<String>? encoded) {
    final operations = <SyncOperation>[];
    for (final item in encoded ?? const <String>[]) {
      try {
        final json = jsonDecode(item);
        if (json is Map<String, dynamic>) {
          operations.add(SyncOperation.fromJson(json));
        }
      } catch (_) {
        // A malformed queue entry must not prevent later valid work.
      }
    }
    return operations;
  }
}
