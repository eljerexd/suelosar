/// Soil-classification and taxonomic fields published by provincial soil maps.
class GisSoilTaxonomy {
  const GisSoilTaxonomy({
    required this.soilClass,
    required this.subclass,
    required this.productivityIndex,
    required this.components,
    this.sourceClassifications = const [],
  });

  final String? soilClass;
  final String? subclass;
  final String? productivityIndex;
  final List<GisSoilTaxonomyComponent> components;
  final List<GisSoilSourceClassification> sourceClassifications;

  bool get isEmpty =>
      soilClass == null &&
      subclass == null &&
      productivityIndex == null &&
      components.isEmpty &&
      sourceClassifications.isEmpty;

  static GisSoilTaxonomy fromProperties(Map<String, Object?> properties) {
    final components = <GisSoilTaxonomyComponent>[];
    for (var index = 1; index <= 5; index++) {
      final subgroup = _read(properties['SUBGRUPO$index']);
      final position = _read(properties['POSICION$index']);
      if (subgroup == null && position == null) continue;
      components.add(
        GisSoilTaxonomyComponent(
          index: index,
          subgroup: subgroup,
          position: position,
        ),
      );
    }
    const sourceFields = <(String, String)>[
      ('taxo_ppal', 'Taxonomía principal'),
      ('taxo_2rio', 'Taxonomía secundaria 2'),
      ('taxo_3rio', 'Taxonomía secundaria 3'),
      ('taxo_4rio', 'Taxonomía secundaria 4'),
      ('taxo_5', 'Taxonomía secundaria 5'),
      ('taxo_6', 'Taxonomía secundaria 6'),
    ];
    final sourceClassifications = [
      for (final (key, label) in sourceFields)
        if (_read(properties[key]) case final value?)
          GisSoilSourceClassification(label: label, value: value),
    ];
    return GisSoilTaxonomy(
      soilClass: _read(properties['CLASE']),
      subclass: _read(properties['SUBCLASE']),
      productivityIndex: _read(properties['IP']),
      components: List<GisSoilTaxonomyComponent>.unmodifiable(components),
      sourceClassifications: List<GisSoilSourceClassification>.unmodifiable(
        sourceClassifications,
      ),
    );
  }
}

class GisSoilSourceClassification {
  const GisSoilSourceClassification({required this.label, required this.value});

  final String label;
  final String value;
}

class GisSoilTaxonomyComponent {
  const GisSoilTaxonomyComponent({
    required this.index,
    required this.subgroup,
    required this.position,
  });

  final int index;
  final String? subgroup;
  final String? position;
}

String? _read(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
