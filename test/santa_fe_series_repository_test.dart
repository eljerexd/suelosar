import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/repositories/santa_fe_series_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SantaFeSeriesRepository — real index asset', () {
    late SantaFeSeriesRepository repository;

    setUp(() {
      repository = SantaFeSeriesRepository();
    });

    test('pdfAsset points at the consolidated Santa Fe PDF', () async {
      expect(
        await repository.pdfAsset,
        'assets/pdfs_santa_fe/mapa_suelos_santa_fe.pdf',
      );
    });

    // Values verified by hand against the PDF during the Santa Fe Fase 1
    // audit: física = impresa + 12, cross-checked at the start, middle, and
    // end of the document.
    for (final expected in [
      (code: 'RAF', name: 'Rafaela', startPage: 493, endPage: 496),
      (code: 'MLA', name: 'María Luisa', startPage: 430, endPage: 432),
      (code: 'PEA', name: 'Petronila', startPage: 473, endPage: 475),
      (code: 'RSA', name: 'Río Salado', startPage: 517, endPage: 519),
      (code: 'CUL', name: 'Cululú', startPage: 181, endPage: 183),
    ]) {
      test('resolves ${expected.code} (${expected.name}) to the audited page range', () async {
        final entry = await repository.findByCode(expected.code);
        expect(entry, isNotNull);
        expect(entry!.name, expected.name);
        expect(entry.startPage, expected.startPage);
        expect(entry.endPage, expected.endPage);
      });
    }

    test('lookup is case-insensitive', () async {
      final upper = await repository.findByCode('RAF');
      final lower = await repository.findByCode('raf');
      final mixed = await repository.findByCode('Raf');
      expect(upper, isNotNull);
      expect(lower?.name, upper?.name);
      expect(mixed?.startPage, upper?.startPage);
    });

    test(
      'resolves the audited capitalization mismatch (ALd geojson code vs Ald PDF code)',
      () async {
        final entry = await repository.findByCode('ALd');
        expect(entry, isNotNull);
        expect(entry!.name, 'Alejo Ledesma');
      },
    );

    test('unknown code returns null without throwing', () async {
      expect(await repository.findByCode('NOEXISTE'), isNull);
      // Audited: these GeoJSON component codes have no matching PDF series.
      expect(await repository.findByCode('Nq'), isNull);
      expect(await repository.findByCode('GUA'), isNull);
    });

    test('startPage/endPage form a valid, non-overlapping range', () async {
      final entry = await repository.findByCode('RAF');
      expect(entry!.endPage, greaterThanOrEqualTo(entry.startPage));
    });

    test(
      'loadAllSeries returns all 213 series, sorted by display name, real '
      'names never raw codes',
      () async {
        final all = await repository.loadAllSeries();
        expect(all, hasLength(213));
        expect(
          all.map((entry) => entry.name),
          orderedEquals(
            all.map((entry) => entry.name).toList()..sort(),
          ),
        );
        final rafaela = all.firstWhere((entry) => entry.code == 'RAF');
        expect(rafaela.name, 'Rafaela');
        expect(all.map((entry) => entry.name), isNot(contains('RAF')));
      },
    );
  });

  group('SantaFeSeriesRepository.dominantSeriesCode', () {
    test('picks the component with the highest percentage', () {
      final code = SantaFeSeriesRepository.dominantSeriesCode({
        'comp1': 'RAF cc',
        'comp1_porc': 60.0,
        'comp2': 'MLA cc',
        'comp2_porc': 40.0,
      });
      expect(code, 'RAF');
    });

    test('picks the highest percentage regardless of component order', () {
      final code = SantaFeSeriesRepository.dominantSeriesCode({
        'comp1': 'MLA cc',
        'comp1_porc': 30.0,
        'comp2': 'RAF cc',
        'comp2_porc': 70.0,
        'comp3': 'PEA cc',
        'comp3_porc': null,
      });
      expect(code, 'RAF');
    });

    test(
      'falls back to the first valid component when no percentage is usable',
      () {
        final code = SantaFeSeriesRepository.dominantSeriesCode({
          'comp1': 'BCH cc',
          'comp1_porc': null,
          'comp2': 'ENO cc',
          'comp2_porc': null,
        });
        expect(code, 'BCH');
      },
    );

    test('supports the ~30MB dataset\'s comp_1/comp_2 naming', () {
      final code = SantaFeSeriesRepository.dominantSeriesCode({
        'comp_1': 'ENO cc',
        'comp1_porc': null,
        'comp_2': null,
        'comp2_porc': null,
      });
      expect(code, 'ENO');
    });

    test('returns null when there is no usable component at all', () {
      final code = SantaFeSeriesRepository.dominantSeriesCode({
        'comp1': null,
        'comp2': null,
      });
      expect(code, isNull);
    });

    test('ignores a blank component string', () {
      final code = SantaFeSeriesRepository.dominantSeriesCode({
        'comp1': '   ',
        'comp2': 'RAF cc',
        'comp2_porc': 55.0,
      });
      expect(code, 'RAF');
    });
  });
}
