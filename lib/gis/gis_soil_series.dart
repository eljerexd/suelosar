/// A soil series referenced by a polygon's vector-tile attributes.
class GisSoilSeries {
  const GisSoilSeries({required this.name, required this.percentage});

  final String name;
  final String percentage;

  String get displayLabel {
    if (percentage.isEmpty) {
      return name;
    }

    final percentageLabel = percentage.endsWith('%')
        ? percentage
        : '$percentage%';
    return '$name ($percentageLabel)';
  }

  static List<GisSoilSeries> fromProperties(Map<String, Object?> properties) {
    final series = <GisSoilSeries>[];

    for (var index = 1; index <= 6; index++) {
      final name = properties['SERIE$index']?.toString().trim() ?? '';
      if (name.isEmpty) {
        continue;
      }

      series.add(
        GisSoilSeries(
          name: name,
          percentage: _readPercentage(properties['PORC$index']),
        ),
      );
    }

    return List<GisSoilSeries>.unmodifiable(series);
  }

  static String _readPercentage(Object? value) {
    if (value == null) {
      return '';
    }

    if (value is num && value == value.roundToDouble()) {
      return value.toInt().toString();
    }

    return value.toString().trim();
  }
}
