import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings_sync_record.dart';
import '../models/measurement_color_option.dart';
import '../repositories/sync_aware_local_repository.dart';

class SettingsService extends ChangeNotifier {
  SettingsService._();

  static final SettingsService instance = SettingsService._();
  static const String _reduceAnimationsKey = 'settings.reduce_animations';
  static const String _followLocationAutomaticallyKey =
      'settings.follow_location_automatically';
  static const String _confirmBeforeDeletingKey =
      'settings.confirm_before_deleting';
  static const String _showGpsAccuracyCircleKey =
      'settings.show_gps_accuracy_circle';
  static const String _showZoomLevelKey = 'settings.show_zoom_level';
  static const String _defaultMeasurementColorKey =
      'settings.default_measurement_color';
  static const String _legacyMeasurementColorKey = 'gis.measurement_color';

  bool _reduceAnimations = false;
  bool _followLocationAutomatically = false;
  bool _confirmBeforeDeleting = true;
  bool _showGpsAccuracyCircle = true;
  bool _showZoomLevel = true;
  MeasurementColorOption _defaultMeasurementColor = MeasurementColorOption.blue;
  AppSettingsSyncRecord? _syncRecord;

  bool get reduceAnimations => _reduceAnimations;
  bool get followLocationAutomatically => _followLocationAutomatically;
  bool get confirmBeforeDeleting => _confirmBeforeDeleting;
  bool get showGpsAccuracyCircle => _showGpsAccuracyCircle;
  bool get showZoomLevel => _showZoomLevel;
  MeasurementColorOption get defaultMeasurementColor =>
      _defaultMeasurementColor;
  AppSettingsSyncRecord? get syncRecord => _syncRecord;

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    _reduceAnimations = preferences.getBool(_reduceAnimationsKey) ?? false;
    _followLocationAutomatically =
        preferences.getBool(_followLocationAutomaticallyKey) ?? false;
    _confirmBeforeDeleting =
        preferences.getBool(_confirmBeforeDeletingKey) ?? true;
    _showGpsAccuracyCircle =
        preferences.getBool(_showGpsAccuracyCircleKey) ?? true;
    _showZoomLevel = preferences.getBool(_showZoomLevelKey) ?? true;
    final storedColor =
        preferences.getString(_defaultMeasurementColorKey) ??
        preferences.getString(_legacyMeasurementColorKey);
    _defaultMeasurementColor = MeasurementColorOption.fromStorageValue(
      storedColor,
    );
    if (storedColor != _defaultMeasurementColor.id) {
      await preferences.setString(
        _defaultMeasurementColorKey,
        _defaultMeasurementColor.id,
      );
    }
    final encodedSyncRecord = preferences.getString(
      AppSettingsSyncRecord.storageKey,
    );
    if (encodedSyncRecord != null) {
      try {
        final decoded = jsonDecode(encodedSyncRecord);
        if (decoded is Map<String, dynamic>) {
          _syncRecord = AppSettingsSyncRecord.fromJson(decoded);
        }
      } catch (_) {
        _syncRecord = null;
      }
    }
    _syncRecord ??= AppSettingsSyncRecord(values: _currentValues());
    await preferences.setString(
      AppSettingsSyncRecord.storageKey,
      jsonEncode(_syncRecord!.toJson()),
    );
  }

  Future<void> setReduceAnimations(bool value) async {
    if (_reduceAnimations == value) return;
    _reduceAnimations = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_reduceAnimationsKey, value);
    await _updateSyncRecord(preferences);
  }

  Future<void> setFollowLocationAutomatically(bool value) async {
    if (_followLocationAutomatically == value) return;
    _followLocationAutomatically = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_followLocationAutomaticallyKey, value);
    await _updateSyncRecord(preferences);
  }

  Future<void> setConfirmBeforeDeleting(bool value) async {
    if (_confirmBeforeDeleting == value) return;
    _confirmBeforeDeleting = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_confirmBeforeDeletingKey, value);
    await _updateSyncRecord(preferences);
  }

  Future<void> setShowGpsAccuracyCircle(bool value) async {
    if (_showGpsAccuracyCircle == value) return;
    _showGpsAccuracyCircle = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_showGpsAccuracyCircleKey, value);
    await _updateSyncRecord(preferences);
  }

  Future<void> setShowZoomLevel(bool value) async {
    if (_showZoomLevel == value) return;
    _showZoomLevel = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_showZoomLevelKey, value);
    await _updateSyncRecord(preferences);
  }

  Future<void> setDefaultMeasurementColor(MeasurementColorOption value) async {
    if (_defaultMeasurementColor == value) return;
    _defaultMeasurementColor = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_defaultMeasurementColorKey, value.id);
    await _updateSyncRecord(preferences);
  }

  /// Applies a newer cloud snapshot without treating it as a local edit.
  Future<void> applyRemoteSyncRecord(AppSettingsSyncRecord record) async {
    final values = record.values;
    final reduceAnimations =
        values['reduceAnimations'] as bool? ?? _reduceAnimations;
    final followLocationAutomatically =
        values['followLocationAutomatically'] as bool? ??
        _followLocationAutomatically;
    final confirmBeforeDeleting =
        values['confirmBeforeDeleting'] as bool? ?? _confirmBeforeDeleting;
    final showGpsAccuracyCircle =
        values['showGpsAccuracyCircle'] as bool? ?? _showGpsAccuracyCircle;
    final showZoomLevel = values['showZoomLevel'] as bool? ?? _showZoomLevel;
    final defaultMeasurementColor = MeasurementColorOption.fromStorageValue(
      values['defaultMeasurementColor']?.toString(),
    );
    final changed =
        reduceAnimations != _reduceAnimations ||
        followLocationAutomatically != _followLocationAutomatically ||
        confirmBeforeDeleting != _confirmBeforeDeleting ||
        showGpsAccuracyCircle != _showGpsAccuracyCircle ||
        showZoomLevel != _showZoomLevel ||
        defaultMeasurementColor != _defaultMeasurementColor;

    _reduceAnimations = reduceAnimations;
    _followLocationAutomatically = followLocationAutomatically;
    _confirmBeforeDeleting = confirmBeforeDeleting;
    _showGpsAccuracyCircle = showGpsAccuracyCircle;
    _showZoomLevel = showZoomLevel;
    _defaultMeasurementColor = defaultMeasurementColor;
    _syncRecord = record;

    final preferences = await SharedPreferences.getInstance();
    await Future.wait<void>([
      preferences.setBool(_reduceAnimationsKey, reduceAnimations),
      preferences.setBool(
        _followLocationAutomaticallyKey,
        followLocationAutomatically,
      ),
      preferences.setBool(_confirmBeforeDeletingKey, confirmBeforeDeleting),
      preferences.setBool(_showGpsAccuracyCircleKey, showGpsAccuracyCircle),
      preferences.setBool(_showZoomLevelKey, showZoomLevel),
      preferences.setString(
        _defaultMeasurementColorKey,
        defaultMeasurementColor.id,
      ),
      preferences.setString(
        AppSettingsSyncRecord.storageKey,
        jsonEncode(record.toJson()),
      ),
    ]);
    if (changed) notifyListeners();
  }

  Map<String, Object?> _currentValues() => <String, Object?>{
    'reduceAnimations': _reduceAnimations,
    'followLocationAutomatically': _followLocationAutomatically,
    'confirmBeforeDeleting': _confirmBeforeDeleting,
    'showGpsAccuracyCircle': _showGpsAccuracyCircle,
    'showZoomLevel': _showZoomLevel,
    'defaultMeasurementColor': _defaultMeasurementColor.id,
  };

  Future<void> _updateSyncRecord(SharedPreferences preferences) async {
    final current =
        _syncRecord ?? AppSettingsSyncRecord(values: _currentValues());
    _syncRecord = current.withValues(_currentValues());
    await SyncAwareLocalRepository.instance.saveSettings(_syncRecord!);
  }
}
