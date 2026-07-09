import '../constants/asset_paths.dart';

class SoilMap {
  const SoilMap({
    this.id = 0,
    required this.name,
    this.province = '',
    this.department = '',
    this.scale = '',
    required this.pdf,
    this.memory,
    this.map,
    this.notes = '',
  });

  final int id;
  final String name;
  final String province;
  final String department;
  final String scale;
  final String pdf;
  final String? memory;
  final String? map;
  final String notes;

  String get assetPath {
    return '${AssetPaths.soilMapsPdfDirectory}/$pdf';
  }

  factory SoilMap.fromJson(Map<String, dynamic> json) {
    return SoilMap(
      id: _readInt(json['id']),
      name: _readString(json['name']),
      province: _readString(json['province']),
      department: _readString(json['department']),
      scale: _readString(json['scale']),
      pdf: _readString(json['pdf']),
      memory: _readNullableString(json['memory']),
      map: _readNullableString(json['map']),
      notes: _readString(json['notes']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'province': province,
      'department': department,
      'scale': scale,
      'pdf': pdf,
      'memory': memory,
      'map': map,
      'notes': notes,
    };
  }

  static int _readInt(Object? value) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    if (value is String) {
      return int.tryParse(value) ?? 0;
    }

    return 0;
  }

  static String _readString(Object? value) {
    return value?.toString() ?? '';
  }

  static String? _readNullableString(Object? value) {
    return value?.toString();
  }
}
