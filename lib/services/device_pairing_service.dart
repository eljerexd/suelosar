import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../pairing/device_pairing_backend.dart';
import '../pairing/device_pairing_models.dart';
import '../pairing/supabase_device_pairing_backend.dart';

typedef PairingRegistrationLoader =
    Future<PairingDeviceRegistration> Function();
typedef PairingBackendLoader = DevicePairingBackend Function();

class DevicePairingService extends ChangeNotifier {
  DevicePairingService({
    DevicePairingBackend? backend,
    required PairingRegistrationLoader registrationLoader,
    PairingBackendLoader? backendLoader,
  }) : _backendLoader = backendLoader ?? _defaultBackend {
    _backend = backend;
    _registrationLoader = registrationLoader;
  }

  static const String groupStorageKey = 'sync.group_uuid';

  DevicePairingBackend? _backend;
  late final PairingRegistrationLoader _registrationLoader;
  final PairingBackendLoader _backendLoader;
  PairingDeviceRegistration? _registration;
  SyncGroup? _group;
  List<PairedDevice> _devices = const [];
  DevicePairingStatus _status = DevicePairingStatus.idle;
  String? _lastError;
  bool _started = false;
  bool _disposed = false;

  DevicePairingStatus get status => _status;
  SyncGroup? get group => _group;
  List<PairedDevice> get devices => List.unmodifiable(_devices);
  String? get lastError => _lastError;
  bool get isConfigured => _backend?.isConfigured ?? false;
  bool get isBusy => const {
    DevicePairingStatus.loading,
    DevicePairingStatus.creating,
    DevicePairingStatus.joining,
    DevicePairingStatus.updating,
  }.contains(_status);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _registration = await _registrationLoader();
    _backend ??= _backendLoader();
    if (!isConfigured) {
      _notify();
      return;
    }
    await _run(DevicePairingStatus.loading, () async {
      final result = await _backend!.registerCurrentDevice(_registration!);
      await _applyBootstrap(result);
    });
  }

  Future<void> refreshDevices() async {
    final registration = _requireRegistration();
    final backend = _requireBackend();
    await _run(DevicePairingStatus.loading, () async {
      _devices = await backend.listDevices(registration.deviceUuid);
    });
  }

  Future<PairingSession> createPairingSession() async {
    final registration = _requireRegistration();
    final backend = _requireBackend();
    late PairingSession session;
    await _run(DevicePairingStatus.creating, () async {
      session = await backend.createPairingSession(registration);
    });
    return session;
  }

  Future<void> pairWithToken(String token) async {
    final normalized = _tokenFromPayload(token);
    if (normalized.isEmpty) {
      throw const DevicePairingException('El código QR no es válido.');
    }
    await _claim(token: normalized);
  }

  Future<void> pairWithCode(String pairingCode) async {
    final normalized = pairingCode.replaceAll(RegExp(r'\D'), '');
    if (normalized.length != 6) {
      throw const DevicePairingException('Ingresá un código de 6 dígitos.');
    }
    await _claim(pairingCode: normalized);
  }

  Future<void> renameDevice(PairedDevice device, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw const DevicePairingException(
        'Ingresá un nombre para el dispositivo.',
      );
    }
    final registration = _requireRegistration();
    final backend = _requireBackend();
    await _run(DevicePairingStatus.updating, () async {
      final updated = await backend.renameDevice(
        deviceUuid: device.deviceUuid,
        deviceName: normalized,
        currentDeviceUuid: registration.deviceUuid,
      );
      _devices = [
        for (final item in _devices)
          if (item.deviceUuid == updated.deviceUuid) updated else item,
      ];
    });
  }

  Future<void> removeDevice(PairedDevice device) async {
    if (device.isCurrentDevice) {
      throw const DevicePairingException(
        'El dispositivo actual no puede quitarse desde esta pantalla.',
      );
    }
    final registration = _requireRegistration();
    final backend = _requireBackend();
    await _run(DevicePairingStatus.updating, () async {
      await backend.removeDevice(
        deviceUuid: device.deviceUuid,
        currentDeviceUuid: registration.deviceUuid,
      );
      _devices = _devices
          .where((item) => item.deviceUuid != device.deviceUuid)
          .toList(growable: false);
    });
  }

  Future<void> _claim({String? token, String? pairingCode}) async {
    final registration = _requireRegistration();
    final backend = _requireBackend();
    await _run(DevicePairingStatus.joining, () async {
      final result = await backend.claimPairingToken(
        registration: registration,
        token: token,
        pairingCode: pairingCode,
      );
      _group = result.group;
      _devices = result.devices;
      await _storeGroup(result.group.groupUuid);
    });
  }

  Future<void> _applyBootstrap(PairingBootstrapResult result) async {
    _group = result.group;
    _devices = result.devices;
    await _storeGroup(result.group.groupUuid);
  }

  Future<void> _storeGroup(String uuid) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(groupStorageKey, uuid);
  }

  Future<void> _run(
    DevicePairingStatus status,
    Future<void> Function() operation,
  ) async {
    _status = status;
    _lastError = null;
    _notify();
    try {
      await operation();
      _status = DevicePairingStatus.idle;
    } catch (error) {
      _status = DevicePairingStatus.error;
      _lastError = error is DevicePairingException
          ? error.message
          : 'No se pudo completar la operación.';
      rethrow;
    } finally {
      _notify();
    }
  }

  PairingDeviceRegistration _requireRegistration() {
    final registration = _registration;
    if (registration == null) {
      throw const DevicePairingException(
        'La información del dispositivo todavía no está disponible.',
      );
    }
    return registration;
  }

  DevicePairingBackend _requireBackend() {
    final backend = _backend;
    if (backend == null || !backend.isConfigured) {
      throw const DevicePairingException(
        'El servicio de sincronización no está configurado.',
      );
    }
    return backend;
  }

  String _tokenFromPayload(String value) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri?.scheme == 'suelosar' && uri?.host == 'pair') {
      return uri?.queryParameters['token']?.trim() ?? '';
    }
    return trimmed.contains('://') ? '' : trimmed;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static DevicePairingBackend _defaultBackend() {
    try {
      return SupabaseDevicePairingBackend(Supabase.instance.client);
    } catch (_) {
      return const UnavailableDevicePairingBackend();
    }
  }
}
