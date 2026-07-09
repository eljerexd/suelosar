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

class PersonalMarker {
  static const String storageKey = 'gis.personal_markers';

  const PersonalMarker({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.name,
    required this.description,
    required this.createdAt,
    this.category = PersonalMarkerCategory.other,
  });

  final String id;
  final double latitude;
  final double longitude;
  final String name;
  final String description;
  final DateTime createdAt;
  final PersonalMarkerCategory category;

  PersonalMarker copyWith({
    String? name,
    String? description,
    PersonalMarkerCategory? category,
  }) {
    return PersonalMarker(
      id: id,
      latitude: latitude,
      longitude: longitude,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt,
      category: category ?? this.category,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'latitude': latitude,
    'longitude': longitude,
    'name': name,
    'description': description,
    'category': category.id,
    'createdAt': createdAt.toIso8601String(),
  };

  factory PersonalMarker.fromJson(Map<String, Object?> json) {
    return PersonalMarker(
      id: json['id'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      category: PersonalMarkerCategory.fromId(json['category']),
    );
  }
}
