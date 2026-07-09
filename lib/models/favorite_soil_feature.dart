class FavoriteSoilFeature {
  const FavoriteSoilFeature({
    required this.id,
    required this.unitName,
    required this.unitSymbol,
    required this.soilSeries,
    required this.pdfIdentifier,
  });

  factory FavoriteSoilFeature.fromJson(Map<String, dynamic> json) {
    final rawSeries = json['soilSeries'];
    return FavoriteSoilFeature(
      id: json['id']?.toString() ?? '',
      unitName: json['unitName']?.toString() ?? '',
      unitSymbol: json['unitSymbol']?.toString() ?? '',
      soilSeries: rawSeries is List
          ? rawSeries.map((value) => value.toString()).toList()
          : const <String>[],
      pdfIdentifier: json['pdfIdentifier']?.toString(),
    );
  }

  static const String storageKey = 'gis.favorite_soil_features';

  final String id;
  final String unitName;
  final String unitSymbol;
  final List<String> soilSeries;
  final String? pdfIdentifier;

  String get dominantSoilSeries =>
      soilSeries.isEmpty ? 'Sin datos' : soilSeries.first;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'unitName': unitName,
      'unitSymbol': unitSymbol,
      'soilSeries': soilSeries,
      'pdfIdentifier': pdfIdentifier,
    };
  }
}
