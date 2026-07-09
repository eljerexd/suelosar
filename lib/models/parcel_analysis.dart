class ParcelSoilComposition {
  const ParcelSoilComposition({
    required this.featureId,
    required this.unitSymbol,
    required this.dominantSoilSeries,
    required this.capabilityClass,
    required this.areaSquareMeters,
    required this.percentage,
  });

  final String featureId;
  final String unitSymbol;
  final String dominantSoilSeries;
  final String capabilityClass;
  final double areaSquareMeters;
  final double percentage;

  double get areaHectares => areaSquareMeters / 10000;
}

class ParcelAnalysis {
  const ParcelAnalysis({
    required this.totalAreaSquareMeters,
    required this.perimeterMeters,
    this.intersections = const <ParcelSoilIntersection>[],
    this.soilComposition = const <ParcelSoilComposition>[],
    this.dominantSoilUnit,
    this.dominantCapabilityClass,
    this.dominantSoilSeries,
  });

  final double totalAreaSquareMeters;
  final double perimeterMeters;
  final List<ParcelSoilIntersection> intersections;
  final List<ParcelSoilComposition> soilComposition;
  final String? dominantSoilUnit;
  final String? dominantCapabilityClass;
  final String? dominantSoilSeries;
}

class ParcelSoilIntersection {
  const ParcelSoilIntersection({
    required this.featureId,
    required this.unitSymbol,
    required this.dominantSoilSeries,
    required this.capabilityClass,
    required this.geometry,
    required this.areaSquareMeters,
  });

  final String featureId;
  final String unitSymbol;
  final String dominantSoilSeries;
  final String capabilityClass;
  final ParcelIntersectionGeometry geometry;
  final double areaSquareMeters;
}

class ParcelIntersectionGeometry {
  const ParcelIntersectionGeometry({
    this.includedRings = const <List<ParcelCoordinate>>[],
    this.excludedRings = const <List<ParcelCoordinate>>[],
  });

  final List<List<ParcelCoordinate>> includedRings;
  final List<List<ParcelCoordinate>> excludedRings;
}

class ParcelCoordinate {
  const ParcelCoordinate({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}
