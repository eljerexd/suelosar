import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/measurement_color_option.dart';

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
  static const String _defaultMeasurementColorKey =
      'settings.default_measurement_color';
  static const String _legacyMeasurementColorKey = 'gis.measurement_color';

  bool _reduceAnimations = false;
  bool _followLocationAutomatically = false;
  bool _confirmBeforeDeleting = true;
  bool _showGpsAccuracyCircle = true;
  MeasurementColorOption _defaultMeasurementColor = MeasurementColorOption.blue;

  bool get reduceAnimations => _reduceAnimations;
  bool get followLocationAutomatically => _followLocationAutomatically;
  bool get confirmBeforeDeleting => _confirmBeforeDeleting;
  bool get showGpsAccuracyCircle => _showGpsAccuracyCircle;
  MeasurementColorOption get defaultMeasurementColor =>
      _defaultMeasurementColor;

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    _reduceAnimations = preferences.getBool(_reduceAnimationsKey) ?? false;
    _followLocationAutomatically =
        preferences.getBool(_followLocationAutomaticallyKey) ?? false;
    _confirmBeforeDeleting =
        preferences.getBool(_confirmBeforeDeletingKey) ?? true;
    _showGpsAccuracyCircle =
        preferences.getBool(_showGpsAccuracyCircleKey) ?? true;
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
  }

  Future<void> setReduceAnimations(bool value) async {
    if (_reduceAnimations == value) return;
    _reduceAnimations = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_reduceAnimationsKey, value);
  }

  Future<void> setFollowLocationAutomatically(bool value) async {
    if (_followLocationAutomatically == value) return;
    _followLocationAutomatically = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_followLocationAutomaticallyKey, value);
  }

  Future<void> setConfirmBeforeDeleting(bool value) async {
    if (_confirmBeforeDeleting == value) return;
    _confirmBeforeDeleting = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_confirmBeforeDeletingKey, value);
  }

  Future<void> setShowGpsAccuracyCircle(bool value) async {
    if (_showGpsAccuracyCircle == value) return;
    _showGpsAccuracyCircle = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_showGpsAccuracyCircleKey, value);
  }

  Future<void> setDefaultMeasurementColor(MeasurementColorOption value) async {
    if (_defaultMeasurementColor == value) return;
    _defaultMeasurementColor = value;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_defaultMeasurementColorKey, value.id);
  }
}
