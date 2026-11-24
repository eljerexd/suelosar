import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../pairing/device_pairing_models.dart';
import '../pairing/supabase_device_pairing_backend.dart';
import '../services/device_identity_service.dart';
import 'sync_coordinator.dart';
import 'sync_engine.dart';
import 'initial_history_sync.dart';
import 'sync_logger.dart';
import 'supabase_sync_backend_adapter.dart';
import 'supabase_sync_config.dart';

class SyncBootstrap {
  SyncBootstrap._();

  static SyncCoordinator? _coordinator;
  static SupabaseClient? _client;
  static Future<void>? _starting;
  static bool _configured = false;
  static String? _startupError;

  static bool get isConfigured => _configured;
  static bool get isConnected => _coordinator != null;
  static String? get startupError => _startupError;
  static String get backendAdapterName =>
      isConfigured ? 'SupabaseSyncBackendAdapter' : 'No configurado';
  static Duration? get pollingInterval => _coordinator?.pollInterval;
  static InitialHistorySyncProgress get initialHistoryProgress =>
      _coordinator?.initialHistorySync.progress.value ??
      const InitialHistorySyncProgress();

  static Future<void> start() {
    if (_coordinator != null) return Future<void>.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  static Future<void> _start() async {
    await SyncEngine.instance.start();
    final config = SupabaseSyncConfig.fromEnvironment();
    _configured = config.isConfigured;
    _startupError = null;
    SyncLogger.instance.log('Supabase synchronization configuration', {
      'url': config.url,
      'publishableKeyPresent': config.publishableKey.isNotEmpty,
      'isConfigured': config.isConfigured,
    });
    if (!config.isConfigured) {
      _startupError =
          'Configuraci\u00f3n incompleta: SUPABASE_URL y '
          'SUPABASE_PUBLISHABLE_KEY deben recibirse mediante --dart-define.';
      SyncLogger.instance.log('Supabase synchronization not configured', {
        'error': _startupError,
      });
      return;
    }
    try {
      var client = _client;
      if (client == null) {
        try {
          client = Supabase.instance.client;
        } catch (_) {
          await Supabase.initialize(
            url: config.url,
            publishableKey: config.publishableKey,
          );
          client = Supabase.instance.client;
        }
        _client = client;
      }
      if (client.auth.currentSession == null) {
        await client.auth.signInAnonymously(
          data: {'device_uuid': DeviceIdentityService.instance.deviceUuid},
        );
      }
      final platform = _platformName();
      await SupabaseDevicePairingBackend(client).registerCurrentDevice(
        PairingDeviceRegistration(
          deviceUuid: DeviceIdentityService.instance.deviceUuid,
          deviceName: 'SuelosAR $platform',
          platform: platform,
        ),
      );
      final coordinator = SyncCoordinator(
        engine: SyncEngine.instance,
        backend: SupabaseSyncBackendAdapter(
          client: client,
          deviceUuid: DeviceIdentityService.instance.deviceUuid,
        ),
      );
      _coordinator = coordinator;
      await coordinator.start();
      SyncLogger.instance.log('Supabase synchronization initialized', {
        'pollingSeconds': coordinator.pollInterval.inSeconds,
      });
    } catch (error, stackTrace) {
      _startupError = error.toString();
      SyncLogger.instance.log('Supabase synchronization startup failed', {
        'error': _startupError,
        'stackTrace': stackTrace.toString(),
      });
    }
  }

  static Future<void> dispose() async {
    await _coordinator?.dispose();
    _coordinator = null;
  }

  static Future<bool> synchronizeNow() async {
    var coordinator = _coordinator;
    if (coordinator == null) {
      await start();
      coordinator = _coordinator;
    }
    if (coordinator == null) return false;
    await coordinator.synchronizeNow();
    return true;
  }

  static Future<bool> reuploadLocalData() async {
    final coordinator = _coordinator;
    if (coordinator == null) return false;
    await coordinator.reuploadLocalData();
    return true;
  }

  static String _platformName() => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
}
