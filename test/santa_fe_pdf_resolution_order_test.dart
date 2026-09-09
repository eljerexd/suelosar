import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/gis_soil_series.dart';
import 'package:suelosar/gis/series_resolver.dart';
import 'package:suelosar/repositories/santa_fe_series_repository.dart';

/// Fase 6B regression test.
///
/// Bug: `_showFeatureAttributes` (gis_map_screen.dart) resolved the PDF
/// from the *display-renamed* series list instead of the raw one —
/// `_resolveSeriesDisplayNames` runs first and overwrites `GisSoilSeries
/// .name` from a raw code ("RSA cc") to its real name ("Río Salado")
/// before `_findSeriesPdfs` ever sees it. `SantaFeSeriesResolver.resolve`
/// then extracts a "code" from that already-renamed value — the leading
/// token of "Río Salado" is "Río", which isn't in the index — and returns
/// null, so the UI showed "Memoria no disponible" for a series whose PDF
/// genuinely exists and resolves fine (Fase 1: page 517).
///
/// This never affected Buenos Aires because its SeriesNameResolver is the
/// identity function (its SERIE values are already real names), so
/// "renamed" and "raw" were always the same string there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SantaFeSeriesResolver.resolve fails on an already-renamed series '
    '(reproduces the bug)',
    () async {
      final repository = SantaFeSeriesRepository();
      final nameResolver = SantaFeSeriesNameResolver(repository);
      final pdfResolver = SantaFeSeriesResolver(repository);
      await nameResolver.preload();

      final raw = GisSoilSeries(name: 'RSA cc', percentage: '30');
      final displayName = nameResolver.resolve(raw.name);
      expect(displayName, 'Río Salado');

      final renamed = GisSoilSeries(name: displayName, percentage: '30');
      final locationFromRenamed = await pdfResolver.resolve(renamed);
      expect(
        locationFromRenamed,
        isNull,
        reason:
            'documents the bug: resolving from the renamed series must '
            'fail, since "Río Salado" has no series code in it',
      );
    },
  );

  test(
    'the fix: resolving the PDF from the raw series succeeds — Río Salado, '
    'page 517',
    () async {
      final repository = SantaFeSeriesRepository();
      final pdfResolver = SantaFeSeriesResolver(repository);

      final raw = GisSoilSeries(name: 'RSA cc', percentage: '30');
      final location = await pdfResolver.resolve(raw);

      expect(location, isNotNull);
      expect(
        location!.assetPath,
        'assets/pdfs_santa_fe/mapa_suelos_santa_fe.pdf',
      );
      expect(location.startPage, 517);
      expect(location.endPage, 519);
    },
  );
}
