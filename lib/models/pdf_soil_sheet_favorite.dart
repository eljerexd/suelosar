class PdfSoilSheetFavorite {
  const PdfSoilSheetFavorite({
    required this.id,
    required this.title,
    required this.pdfIdentifier,
    required this.createdAt,
  });

  factory PdfSoilSheetFavorite.fromJson(Map<String, dynamic> json) {
    return PdfSoilSheetFavorite(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      pdfIdentifier: json['pdfIdentifier']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }

  static const String storageKey = 'pdf.favorite_soil_sheets';
  static const String idPrefix = 'pdf-sheet:';

  final String id;
  final String title;
  final String pdfIdentifier;
  final DateTime createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'pdfIdentifier': pdfIdentifier,
    'createdAt': createdAt.toIso8601String(),
  };
}
