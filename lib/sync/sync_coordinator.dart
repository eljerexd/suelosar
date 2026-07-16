import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/connectivity_service.dart';
import 'initial_history_sync.dart';
import 'sync_backend_adapter.dart';
import 'sync_engine.dart';
import 'sync_local_merge_store.dart';
import 'sync_logger.dart';
import 'sync_status.dart';
import 'supabase_sync_backend_adapter.dart';

class SyncCoordinator {
  SyncCoordinator({
    required this.engine,
    required this.backend,
    this.localStore = const SyncLocalMergeStore(),
    InitialHistorySync? initialHistorySync,
    SyncLogger? logger,
    this.pollInterval = const Duration(seconds: 30),
  }) : _logger = logger ?? SyncLogger.instance,
       initialHistorySync =
           initialHistorySync ??
           InitialHistorySync(
             engine: engine,
             backend: backend,
             localStore: localStore,
             logger: logger,
           );

  static const String cursorStorageKey = 'sync.download_cursor';
  static const String lastSuccessfulSyncStorageKey = 'sync.last_successful_at';
  static const String lastErrorStorageKey = 'sync.last_error';

  final SyncEngine engine;
  final SyncBackendAdapter backend;
  final SyncLocalMergeStore localStore;
  final InitialHistorySync initialHistorySync;
  final SyncLogger _logger;
  final Duration pollInterval;
  Timer? _pollTimer;
  Timer? _retryTimer;
  StreamSubscription<ConnectivityStatus>? _connectivitySubscription;
  StreamSubscription<void>? _localChangeSubscription;
  Future<void>? _activeSynchronization;
  bool _synchronizationRequested = false;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _localChangeSubscription = engine.localChanges.listen((_) {
      unawaited(synchronizeNow());
    });
    _connectivitySubscription = engine.connectivity.changes.listen((status) {
      if (status == ConnectivityStatus.online) unawaited(synchronizeNow());
    });
    _pollTimer = Timer.periodic(
      pollInterval,
      (_) => unawaited(synchronizeNow()),
    );
    unawaited(synchronizeNow());
  }

  Future<void> synchronizeNow() {
    final active = _activeSynchronization;
    if (active != null) {
      _synchronizationRequested = true;
      return active;
    }
    final synchronization = _synchronize();
    _activeSynchronization = synchronization;
    return synchronization.whenComplete(() {
      if (identical(_activeSynchronization, synchronization)) {
        _activeSynchronization = null;
        if (_started && _synchronizationRequested) {
          _synchronizationRequested = false;
          unawaited(synchronizeNow());
        }
      }
    });
  }

  Future<void> _synchronize() async {
    List<PreparedSyncUpload> batch = const [];
    try {
      await initialHistorySync.prepareIfNeeded();
      batch = await engine.prepareUploadBatch();
      if (batch.isNotEmpty) {
        engine.status.value = SyncStatus.uploading;
        await backend.upload(batch);
        await localStore.markUploaded(batch);
        await engine.confirm(batch.map((item) => item.operation.operationId));
        initialHistorySync.recordUploaded(batch);
      }

      engine.status.value = SyncStatus.downloading;
      final preferences = await SharedPreferences.getInstance();
      final downloaded = await backend.download(
        SyncDownloadRequest(cursor: preferences.getString(cursorStorageKey)),
      );
      await localStore.mergeRemoteChanges(downloaded.changes);
      if (downloaded.nextCursor != null) {
        await preferences.setString(cursorStorageKey, downloaded.nextCursor!);
      }
      engine.connectivity.update(ConnectivityStatus.online);
      await preferences.setString(
        lastSuccessfulSyncStorageKey,
        DateTime.now().toUtc().toIso8601String(),
      );
      await preferences.remove(lastErrorStorageKey);
      _retryTimer?.cancel();
      _retryTimer = null;
      _logger.log('Polling synchronization completed', {
        'uploaded': batch.length,
        'downloaded': downloaded.changes.length,
      });
      if ((await engine.queue.readAll()).isNotEmpty) {
        _synchronizationRequested = true;
      } else {
        await initialHistorySync.completeIfQueueEmpty();
      }
      engine.status.value = SyncStatus.completed;
    } on SyncAuthenticationRequiredException catch (error) {
      engine.status.value = SyncStatus.waitingConnection;
      await _storeLastError(error);
      _logger.log('Synchronization waiting for authentication', {
        'error': error.toString(),
      });
    } catch (error) {
      engine.connectivity.update(ConnectivityStatus.offline);
      for (final item in batch) {
        await engine.scheduleRetry(item.operation.operationId);
      }
      _logger.log('Polling synchronization failed', {
        'error': error.toString(),
      });
      await _storeLastError(error);
      _scheduleRetry(batch);
      engine.status.value = SyncStatus.error;
    }
  }

  Future<void> _storeLastError(Object error) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(lastErrorStorageKey, error.toString());
  }

  void _scheduleRetry(List<PreparedSyncUpload> batch) {
    if (_retryTimer != null) return;
    final retryCount = batch.fold<int>(
      0,
      (maximum, item) => item.operation.retryCount > maximum
          ? item.operation.retryCount
          : maximum,
    );
    final multiplier = 1 << retryCount.clamp(0, 6);
    final delay = Duration(seconds: 5 * multiplier);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(synchronizeNow());
    });
  }

  Future<void> dispose() async {
    _started = false;
    _synchronizationRequested = false;
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    await _localChangeSubscription?.cancel();
    _localChangeSubscription = null;
  }

  Future<void> reuploadLocalData() async {
    await initialHistorySync.resetCurrentGroup();
    do {
      await synchronizeNow();
      if (engine.status.value == SyncStatus.error ||
          engine.status.value == SyncStatus.waitingConnection) {
        return;
      }
    } while ((await engine.queue.readAll()).isNotEmpty);
  }
}
