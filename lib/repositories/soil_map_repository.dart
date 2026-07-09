import 'dart:convert';

import 'package:flutter/services.dart';

import '../constants/asset_paths.dart';
import '../models/soil_map.dart';

class SoilMapRepository {
  const SoilMapRepository();

  static Future<List<SoilMap>>? _cachedSoilMaps;

  Future<List<SoilMap>> loadSoilMaps() {
    return _cachedSoilMaps ??= _loadSoilMaps();
  }

  Future<List<SoilMap>> _loadSoilMaps() async {
    final rawJson = await rootBundle.loadString(AssetPaths.soilMapsCatalog);
    return decodeSoilMaps(rawJson);
  }

  List<SoilMap> decodeSoilMaps(String rawJson) {
    final records = jsonDecode(rawJson) as List<dynamic>;

    return records
        .map(
          (record) =>
              SoilMap.fromJson(Map<String, dynamic>.from(record as Map)),
        )
        .toList(growable: false);
  }
}
