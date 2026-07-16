import 'package:shared_preferences/shared_preferences.dart';

import '../sync/uuid_v4.dart';

class DeviceIdentityService {
  DeviceIdentityService._();

  static final DeviceIdentityService instance = DeviceIdentityService._();
  static const String storageKey = 'sync.device_uuid';

  String? _deviceUuid;

  String get deviceUuid {
    final value = _deviceUuid;
    if (value == null) {
      throw StateError('DeviceIdentityService has not been initialized.');
    }
    return value;
  }

  Future<void> initialize() async {
    if (_deviceUuid != null) return;
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(storageKey);
    if (stored != null && UuidV4.isValid(stored)) {
      _deviceUuid = stored;
      return;
    }
    final generated = UuidV4.generate();
    await preferences.setString(storageKey, generated);
    _deviceUuid = generated;
  }
}
