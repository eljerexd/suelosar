import 'package:supabase_flutter/supabase_flutter.dart';

import 'device_pairing_backend.dart';
import 'device_pairing_models.dart';

class SupabaseDevicePairingBackend implements DevicePairingBackend {
  const SupabaseDevicePairingBackend(this._client);

  final SupabaseClient _client;

  @override
  bool get isConfigured => _client.auth.currentUser != null;

  @override
  Future<PairingBootstrapResult> registerCurrentDevice(
    PairingDeviceRegistration registration,
  ) async {
    final response = await _rpc('register_sync_device', {
      'p_device_uuid': registration.deviceUuid,
      'p_device_name': registration.deviceName,
      'p_platform': registration.platform,
    });
    return _bootstrapFrom(response, registration.deviceUuid);
  }

  @override
  Future<PairingSession> createPairingSession(
    PairingDeviceRegistration registration,
  ) async {
    final response = await _rpc('create_pairing_session', {
      'p_device_uuid': registration.deviceUuid,
    });
    final token = response['token']?.toString() ?? '';
    final code = response['pairing_code']?.toString() ?? '';
    final expiresAt = _date(response['expires_at']);
    if (token.isEmpty || code.length != 6 || expiresAt == null) {
      throw const DevicePairingException(
        'El servicio devolvió una sesión de vinculación inválida.',
      );
    }
    return PairingSession(
      token: token,
      pairingCode: code,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<PairingClaimResult> claimPairingToken({
    required PairingDeviceRegistration registration,
    String? token,
    String? pairingCode,
  }) async {
    final response = await _rpc('claim_pairing_session', {
      'p_device_uuid': registration.deviceUuid,
      'p_device_name': registration.deviceName,
      'p_platform': registration.platform,
      'p_token': token,
      'p_pairing_code': pairingCode,
    });
    final bootstrap = _bootstrapFrom(response, registration.deviceUuid);
    return PairingClaimResult(
      group: bootstrap.group,
      devices: bootstrap.devices,
    );
  }

  @override
  Future<List<PairedDevice>> listDevices(String currentDeviceUuid) async {
    final response = await _client.rpc(
      'list_paired_devices',
      params: {'p_device_uuid': currentDeviceUuid},
    );
    final rows = response is List ? response : const [];
    return rows
        .whereType<Map>()
        .map(
          (row) =>
              _deviceFrom(Map<String, Object?>.from(row), currentDeviceUuid),
        )
        .toList(growable: false);
  }

  @override
  Future<PairedDevice> renameDevice({
    required String deviceUuid,
    required String deviceName,
    required String currentDeviceUuid,
  }) async {
    final response = await _rpc('rename_paired_device', {
      'p_current_device_uuid': currentDeviceUuid,
      'p_target_device_uuid': deviceUuid,
      'p_device_name': deviceName,
    });
    return _deviceFrom(response, currentDeviceUuid);
  }

  @override
  Future<void> removeDevice({
    required String deviceUuid,
    required String currentDeviceUuid,
  }) async {
    await _client.rpc(
      'remove_paired_device',
      params: {
        'p_current_device_uuid': currentDeviceUuid,
        'p_target_device_uuid': deviceUuid,
      },
    );
  }

  Future<Map<String, Object?>> _rpc(
    String function,
    Map<String, Object?> params,
  ) async {
    try {
      final response = await _client.rpc(function, params: params);
      if (response is Map) return Map<String, Object?>.from(response);
      throw const DevicePairingException(
        'El servicio devolvió una respuesta inválida.',
      );
    } on PostgrestException catch (error) {
      throw DevicePairingException(_friendlyMessage(error.message));
    }
  }

  PairingBootstrapResult _bootstrapFrom(
    Map<String, Object?> response,
    String currentDeviceUuid,
  ) {
    final pairingError = response['error']?.toString();
    if (pairingError != null && pairingError.isNotEmpty) {
      throw DevicePairingException(_friendlyMessage(pairingError));
    }
    final groupMap = response['group'];
    final devicesValue = response['devices'];
    if (groupMap is! Map || devicesValue is! List) {
      throw const DevicePairingException(
        'No se pudo obtener el grupo de sincronización.',
      );
    }
    final group = Map<String, Object?>.from(groupMap);
    final createdAt = _date(group['created_at']);
    final groupUuid = group['group_uuid']?.toString() ?? '';
    final ownerUuid = group['owner_device_uuid']?.toString() ?? '';
    if (createdAt == null || groupUuid.isEmpty || ownerUuid.isEmpty) {
      throw const DevicePairingException(
        'El grupo de sincronización recibido no es válido.',
      );
    }
    return PairingBootstrapResult(
      group: SyncGroup(
        groupUuid: groupUuid,
        ownerDeviceUuid: ownerUuid,
        createdAt: createdAt,
      ),
      devices: devicesValue
          .whereType<Map>()
          .map(
            (row) =>
                _deviceFrom(Map<String, Object?>.from(row), currentDeviceUuid),
          )
          .toList(growable: false),
    );
  }

  PairedDevice _deviceFrom(Map<String, Object?> row, String currentDeviceUuid) {
    final uuid = row['device_uuid']?.toString() ?? '';
    final pairedAt = _date(row['paired_at']);
    if (uuid.isEmpty || pairedAt == null) {
      throw const DevicePairingException('Se recibió un dispositivo inválido.');
    }
    return PairedDevice(
      deviceUuid: uuid,
      deviceName: row['device_name']?.toString() ?? '',
      platform: row['platform']?.toString() ?? '',
      pairedAt: pairedAt,
      lastSynchronizationAt: _date(row['last_sync_at']),
      isCurrentDevice: uuid == currentDeviceUuid,
    );
  }

  DateTime? _date(Object? value) =>
      DateTime.tryParse(value?.toString() ?? '')?.toLocal();

  String _friendlyMessage(String message) {
    final normalized = message.toLowerCase();
    if (normalized.contains('expired')) return 'El código ya venció.';
    if (normalized.contains('invalid pairing') ||
        normalized.contains('invalid_pairing')) {
      return 'El código o QR no es válido.';
    }
    if (normalized.contains('too many') || normalized.contains('too_many')) {
      return 'Demasiados intentos. Esperá unos minutos.';
    }
    if (normalized.contains('already paired') ||
        normalized.contains('already_paired')) {
      return 'Este dispositivo ya está vinculado.';
    }
    if (normalized.contains('already_in_shared_group')) {
      return 'Este dispositivo ya pertenece a otro grupo sincronizado.';
    }
    return 'No se pudo completar la vinculación.';
  }
}
