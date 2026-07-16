import '../sync/sync_entity.dart';
import '../sync/sync_state.dart';
import '../sync/uuid_v4.dart';

enum PersonalMarkerCategory {
  sampling('sampling', 'Muestreo'),
  soilPit('soil_pit', 'Calicata'),
  floodProneLowland('flood_prone_lowland', 'Bajo inundable'),
  observation('observation', 'Observación'),
  infrastructure('infrastructure', 'Infraestructura'),
  other('other', 'Otro');

  const PersonalMarkerCategory(this.id, this.label);

  final String id;
  final String label;

  static PersonalMarkerCategory fromId(Object? id) {
    return values.firstWhere(
      (category) => category.id == id,
      orElse: () => other,
    );
  }
}

class PersonalMarker implements SyncEntity {
  static const String storageKey = 'gis.personal_markers';

  PersonalMarker({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.name,
    required this.description,
    required this.createdAt,
    this.category = PersonalMarkerCategory.other,
    String? uuid,
    DateTime? updatedAt,
    this.deletedAt,
    this.syncState = SyncState.local,
  }) : uuid = uuid ?? UuidV4.generate(),
       updatedAt = updatedAt ?? createdAt;

  final String id;
  final double latitude;
  final double longitude;
  final String name;
  final String description;
  @override
  final DateTime createdAt;
  final PersonalMarkerCategory category;
  @override
  final String uuid;
  @override
  final DateTime updatedAt;
  @override
  final DateTime? deletedAt;
  @override
  final SyncState syncState;

  PersonalMarker copyWith({
    String? name,
    String? description,
    PersonalMarkerCategory? category,
    DateTime? updatedAt,
    DateTime? deletedAt,
    SyncState? syncState,
  }) {
    return PersonalMarker(
      id: id,
      latitude: latitude,
      longitude: longitude,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt,
      category: category ?? this.category,
      uuid: uuid,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      syncState: syncState ?? SyncState.pendingUpload,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'latitude': latitude,
    'longitude': longitude,
    'name': name,
    'description': description,
    'category': category.id,
    'createdAt': createdAt.toIso8601String(),
    'uuid': uuid,
    'updatedAt': updatedAt.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
    'syncState': syncState.name,
  };

  factory PersonalMarker.fromJson(Map<String, Object?> json) {
    final createdAt =
        parseSyncDate(json['createdAt']) ?? DateTime.now().toUtc();
    final storedUuid = json['uuid']?.toString() ?? '';
    return PersonalMarker(
      id: json['id'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      createdAt: createdAt,
      category: PersonalMarkerCategory.fromId(json['category']),
      uuid: UuidV4.isValid(storedUuid) ? storedUuid : UuidV4.generate(),
      updatedAt: parseSyncDate(json['updatedAt']) ?? createdAt,
      deletedAt: parseSyncDate(json['deletedAt']),
      syncState: SyncState.fromJson(json['syncState']),
    );
  }
}
