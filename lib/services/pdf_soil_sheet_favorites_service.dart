import '../models/pdf_soil_sheet_favorite.dart';
import '../repositories/pdf_soil_sheet_favorites_repository.dart';

class PdfSoilSheetFavoritesService {
  PdfSoilSheetFavoritesService([
    this._repository = const PdfSoilSheetFavoritesRepository(),
  ]);

  final PdfSoilSheetFavoritesRepository _repository;

  Future<List<PdfSoilSheetFavorite>> load() => _repository.load();

  Future<List<PdfSoilSheetFavorite>> toggle(
    Iterable<PdfSoilSheetFavorite> current, {
    required String title,
    required String pdfIdentifier,
  }) async {
    final updated = current.toList();
    final normalizedPdf = pdfIdentifier.trim().toLowerCase();
    final existingIndex = updated.indexWhere(
      (item) => item.pdfIdentifier.trim().toLowerCase() == normalizedPdf,
    );
    if (existingIndex >= 0) {
      updated.removeAt(existingIndex);
    } else {
      updated.add(
        PdfSoilSheetFavorite(
          id: '${PdfSoilSheetFavorite.idPrefix}$pdfIdentifier',
          title: title,
          pdfIdentifier: pdfIdentifier,
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }
    await _repository.save(updated);
    return updated;
  }

  Future<List<PdfSoilSheetFavorite>> remove(
    Iterable<PdfSoilSheetFavorite> current,
    PdfSoilSheetFavorite favorite,
  ) async {
    final updated = current.where((item) => item.id != favorite.id).toList();
    await _repository.save(updated);
    return updated;
  }
}
