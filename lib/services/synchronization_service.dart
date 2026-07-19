import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync/persistent_sync_queue.dart';
import '../sync/initial_history_sync.dart';
import '../sync/sync_bootstrap.dart';
import '../sync/sync_coordinator.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_operation.dart';
import '../sync/sync_status.dart';
import 'connectivity_service.dart';
import 'device_identity_service.dart';

typedef SynchronizeAction = Future<bool> Function();
typedef DeviceDetailsLoader = Future<SynchronizationDeviceDetails> Function();

class SynchronizationService extends ChangeNotifier {
  SynchronizationService({
    SyncEngine? engine,
    ConnectivityService? connectivity,
    PersistentSyncQueue? queue,
    SynchronizeAction? synchronizeAction,
    DeviceDetailsLoader? deviceDetailsLoader,
    bool Function()? backendConfigured,
    bool Function()? backendConnected,
    String Function()? backendAdapterName,
    Duration? Function()? pollingInterval,
    String? Function()? backendStartupError,
    InitialHistorySyncProgress Function()? initialHistoryProgress,
    SynchronizeAction? reuploadLocalDataAction,
  }) : _engine = engine ?? SyncEngine.instance,
       _connectivity = connectivity ?? ConnectivityService.instance,
       _queue = queue ?? SyncEngine.instance.queue,
       _synchronizeAction = synchronizeAction ?? SyncBootstrap.synchronizeNow,
       _deviceDetailsLoader = deviceDetailsLoader ?? _loadDeviceDetails,
       _backendConfigured =
           backendConfigured ?? (() => SyncBootstrap.isConfigured),
       _backendConnected =
           backendConnected ?? (() => SyncBootstrap.isConnected),
       _backendAdapterName =
           backendAdapterName ?? (() => SyncBootstrap.backendAdapterName),
       _pollingInterval =
           pollingInterval ?? (() => SyncBootstrap.pollingInterval),
       _backendStartupError =
           backendStartupError ?? (() => SyncBootstrap.startupError),
       _initialHistoryProgress =
           initialHistoryProgress ??
           (() => SyncBootstrap.initialHistoryProgress),
       _reuploadLocalDataAction =
           reuploadLocalDataAction ?? SyncBootstrap.reuploadLocalData;

  final SyncEngine _engine;
  final ConnectivityService _connectivity;
  final PersistentSyncQueue _queue;
  final SynchronizeAction _synchronizeAction;
  final DeviceDetailsLoader _deviceDetailsLoader;
  final bool Function() _backendConfigured;
  final bool Function() _backendConnected;
  final String Function() _backendAdapterName;
  final Duration? Function() _pollingInterval;
  final String? Function() _backendStartupError;
  final InitialHistorySyncProgress Function() _initialHistoryProgress;
  final SynchronizeAction _reuploadLocalDataAction;
  StreamSubscription<ConnectivityStatus>? _connectivitySubscription;
  bool _started = false;
  bool _disposed = false;
  bool _refreshing = false;
  Object? _lastPublishedState;
  SynchronizationDeviceDetails _device =
      const SynchronizationDeviceDetails.empty();
  List<SyncOperation> _operations = const [];
  DateTime? _lastSuccessfulAt;
  String? _lastError;
  String? _lastDownloadCursor;

  SyncStatus get engineStatus => _engine.status.value;
  ConnectivityStatus get connectivityStatus => _connectivity.status;
  SynchronizationDeviceDetails get device => _device;
  int get pendingUploads => _operations.length;
  int get pendingDownloads => 0;
  int get queueSize => _operations.length;
  int get pendingCreates => _operationCount(SyncOperationType.create);
  int get pendingUpdates => _operationCount(SyncOperationType.update);
  int get pendingDeletes => _operationCount(SyncOperationType.delete);
  int get retryCount =>
      _operations.fold(0, (total, operation) => total + operation.retryCount);
  bool get isSynchronizing => const {
    SyncStatus.scanning,
    SyncStatus.preparing,
    SyncStatus.uploading,
    SyncStatus.downloading,
  }.contains(engineStatus);
  bool get hasFailedOperations =>
      _operations.any((operation) => operation.retryCount > 0);
  DateTime? get lastSuccessfulAt => _lastSuccessfulAt;
  String? get lastError {
    final startupError = _backendStartupError();
    return startupError?.trim().isNotEmpty == true ? startupError : _lastError;
  }

  String? get lastDownloadCursor => _lastDownloadCursor;
  bool get isBackendConfigured => _backendConfigured();
  bool get isBackendConnected => _backendConnected();
  String get backendAdapter => _backendAdapterName();
  Duration? get currentPollingInterval => _pollingInterval();
  InitialHistorySyncProgress get initialHistoryProgress =>
      _initialHistoryProgress();

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _engine.status.addListener(_handleStateChanged);
    _connectivitySubscription = _connectivity.changes.listen(
      (_) => _handleStateChanged(),
    );
    _device = await _deviceDetailsLoader();
    if (_disposed) return;
    await refresh();
  }

  Future<void> refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      _operations = await _queue.readAll();
      _lastSuccessfulAt = DateTime.tryParse(
        preferences.getString(SyncCoordinator.lastSuccessfulSyncStorageKey) ??
            '',
      )?.toLocal();
      _lastError = preferences.getString(SyncCoordinator.lastErrorStorageKey);
      _lastDownloadCursor = preferences.getString(
        SyncCoordinator.cursorStorageKey,
      );
      if (!_disposed) _notifyIfChanged('refresh');
    } finally {
      _refreshing = false;
    }
  }

  Future<bool> synchronizeNow() async {
    final started = await _synchronizeAction();
    await refresh();
    return started;
  }

  Future<bool> retryFailedOperations() => synchronizeNow();

  Future<bool> reuploadLocalData() async {
    final started = await _reuploadLocalDataAction();
    await refresh();
    return started;
  }

  Future<void> clearPendingQueue() async {
    final operations = await _queue.readAll();
    for (final operation in operations) {
      await _engine.cancel(operation.operationId);
    }
    await refresh();
  }

  int _operationCount(SyncOperationType type) =>
      _operations.where((operation) => operation.operationType == type).length;

  void _handleStateChanged() {
    if (_disposed) return;
    _notifyIfChanged('engine_or_connectivity');
    unawaited(refresh());
  }

  void _notifyIfChanged(String source) {
    final nextState = _observableState();
    if (_lastPublishedState == nextState) {
      return;
    }
    _lastPublishedState = nextState;
    notifyListeners();
  }

  Object _observableState() {
    final progress = initialHistoryProgress;
    final operationsFingerprint = _operations
        .map(
          (operation) =>
              '${operation.operationId}:${operation.retryCount}:'
              '${operation.operationType.name}',
        )
        .join('|');
    return (
      engineStatus,
      connectivityStatus,
      operationsFingerprint,
      _device.name,
      _device.uuid,
      _device.appVersion,
      _device.platform,
      _lastSuccessfulAt,
      lastError,
      _lastDownloadCursor,
      isBackendConfigured,
      isBackendConnected,
      backendAdapter,
      currentPollingInterval,
      progress.status,
      progress.groupUuid,
      progress.markers.completed,
      progress.markers.total,
      progress.measurements.completed,
      progress.measurements.total,
      progress.favorites.completed,
      progress.favorites.total,
      progress.error,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _started = false;
    _engine.status.removeListener(_handleStateChanged);
    unawaited(_connectivitySubscription?.cancel());
    super.dispose();
  }

  static Future<SynchronizationDeviceDetails> _loadDeviceDetails() async {
    String deviceName = '';
    try {
      final plugin = DeviceInfoPlugin();
      deviceName = switch (defaultTargetPlatform) {
        TargetPlatform.android => _androidDeviceName(await plugin.androidInfo),
        TargetPlatform.windows => (await plugin.windowsInfo).computerName,
        TargetPlatform.macOS => (await plugin.macOsInfo).modelName,
        TargetPlatform.iOS => (await plugin.iosInfo).modelName,
        TargetPlatform.linux => (await plugin.linuxInfo).prettyName,
        TargetPlatform.fuchsia => '',
      };
    } catch (_) {
      deviceName = '';
    }
    String version = '';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      version = '';
    }
    String uuid = '';
    try {
      uuid = DeviceIdentityService.instance.deviceUuid;
    } catch (_) {
      final preferences = await SharedPreferences.getInstance();
      uuid = preferences.getString(DeviceIdentityService.storageKey) ?? '';
    }
    return SynchronizationDeviceDetails(
      name: deviceName.isEmpty ? _platformName() : deviceName,
      uuid: uuid,
      appVersion: version,
      platform: _platformName(),
    );
  }

  static String _androidDeviceName(AndroidDeviceInfo info) {
    final manufacturer = info.manufacturer.trim();
    final model = info.model.trim();
    if (manufacturer.isEmpty) return model;
    if (model.isEmpty ||
        model.toLowerCase().startsWith(manufacturer.toLowerCase())) {
      return model;
    }
    return '$manufacturer $model';
  }

  static String _platformName() => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
}

@immutable
class SynchronizationDeviceDetails {
  const SynchronizationDeviceDetails({
    required this.name,
    required this.uuid,
    required this.appVersion,
    required this.platform,
  });

  const SynchronizationDeviceDetails.empty()
    : name = '',
      uuid = '',
      appVersion = '',
      platform = '';

  final String name;
  final String uuid;
  final String appVersion;
  final String platform;
}
