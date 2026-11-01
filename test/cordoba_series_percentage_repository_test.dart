import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/cordoba_series_percentage_repository.dart';
import 'package:suelosar/gis/gis_feature.dart';
import 'package:suelosar/gis/gis_soil_series.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CordobaSeriesPercentageRepository repository;

  setUp(() {
    repository = CordobaSeriesPercentageRepository();
  });

  test('SEl3 gets only the three official individual percentages', () async {
    // Official WFS source record: carta_suelo_50mil_2025, id 617, SEl3.
    final properties = <String, Object?>{
      'OBJECTID': 617,
      'SIMBC': 'SEl3',
      'SERIE1': 'SANTA ELENA',
      'PORC1': null,
      'SERIE2': 'FLORA',
      'PORC2': null,
      'SERIE3': 'ACHALAY',
      'PORC3': null,
    };
    final result = await repository.enrichCardSeries(
      feature: _feature(properties),
      sourceSeries: GisSoilSeries.fromProperties(properties),
    );

    expect(result.series.map((series) => series.name), [
      'SANTA ELENA',
      'FLORA',
      'ACHALAY',
    ]);
    expect(result.series.map((series) => series.percentage), [
      '40',
      '20',
      '40',
    ]);
    expect(result.aggregateCompositions, isEmpty);
    expect(properties['PORC1'], isNull);
  });

  test('Ota5 percentages distinguish repeated Olaeta by phase', () async {
    // Official WFS source record: carta_suelo_50mil_2025, id 1281, Ota5.
    final properties = <String, Object?>{
      'OBJECTID': 1281,
      'SIMBC': 'Ota5',
      'SERIE1': 'OLAETA',
      'FASE1': null,
      'PORC1': null,
      'SERIE2': 'LA VICTORIA',
      'FASE2': null,
      'PORC2': null,
      'SERIE3': 'OLAETA',
      'FASE3': 'en fase moderadamente alcalina en profundidad',
      'PORC3': null,
    };
    final result = await repository.enrichCardSeries(
      feature: _feature(properties),
      sourceSeries: GisSoilSeries.fromProperties(properties),
    );

    expect(result.series.map((series) => series.name), [
      'OLAETA',
      'LA VICTORIA',
      'OLAETA',
    ]);
    expect(result.series.map((series) => series.percentage), [
      '40',
      '30',
      '30',
    ]);
    expect(result.series.last.phase, properties['FASE3']);
    expect(
      result.series.fold<int>(
        0,
        (total, item) => total + int.parse(item.percentage),
      ),
      100,
    );
    expect(properties['PORC1'], isNull);
    expect(properties['PORC2'], isNull);
    expect(properties['PORC3'], isNull);
  });

  test(
    'Ota5 phase mismatch does not borrow another repeated series value',
    () async {
      final properties = <String, Object?>{
        'OBJECTID': 1281,
        'SIMBC': 'Ota5',
        'SERIE1': 'OLAETA',
        'FASE1': 'fase no documentada',
        'PORC1': null,
      };
      final result = await repository.enrichCardSeries(
        feature: _feature(properties),
        sourceSeries: GisSoilSeries.fromProperties(properties),
      );

      expect(result.series.single.percentage, isEmpty);
    },
  );

  test(
    'BYc3 keeps its approximate 60% aggregate separate from series',
    () async {
      // Official WFS source record: carta_suelo_50mil_2025, id 1371, BYc3.
      final properties = <String, Object?>{
        'OBJECTID': 1371,
        'SIMBC': 'BYc3',
        'SERIE1': 'BARRANCA YACO',
        'PORC1': null,
        'SERIE2': 'LA EMILIA',
        'PORC2': null,
        'SERIE3': 'PUERTA DE HIERRO II',
        'PORC3': null,
        'SERIE4': 'suelos de textura arenosa franca poco desarrollados',
        'PORC4': null,
      };
      final result = await repository.enrichCardSeries(
        feature: _feature(properties),
        sourceSeries: GisSoilSeries.fromProperties(properties),
      );

      expect(
        result.series.map((series) => series.percentage),
        everyElement(''),
      );
      expect(result.aggregateCompositions, hasLength(1));
      expect(
        result.aggregateCompositions.single.displayText,
        'BARRANCA YACO y LA EMILIA representan aproximadamente 60% en conjunto; '
        'la fuente no informa el porcentaje individual de cada serie.',
      );
      expect(result.aggregateCompositions.single.page, 1);
      expect(
        result.aggregateCompositions.single.evidence,
        contains('no separa'),
      );
    },
  );

  test(
    'CoD1 retains all eight source series without invented proportions',
    () async {
      // Official WFS source record: carta_suelo_100mil_2025, id 86;
      // normalized OBJECTID includes the 100000 source offset.
      final properties = <String, Object?>{
        'OBJECTID': 100086,
        'SIMBC': 'CoD1',
        'SERIE1': 'YACANTO I',
        'SERIE2': 'YACANTO II',
        'SERIE3': 'YACANTO III',
        'SERIE4': 'YACANTO IV',
        'SERIE5': 'CALAMUCHITA III',
        'SERIE6': 'SAN IGNACIO IV',
        'SERIE7': 'FUNDACIÓN',
        'SERIE8': 'SAN PANCRACIO',
        for (var index = 1; index <= 5; index++) 'PORC$index': null,
        'PORC6': null,
        'PORC7': null,
        'PORC8': null,
      };
      final result = await repository.enrichCardSeries(
        feature: _feature(properties),
        sourceSeries: GisSoilSeries.fromProperties(properties),
      );

      expect(result.series, hasLength(8));
      expect(
        result.series.map((series) => series.percentage),
        everyElement(''),
      );
      expect(result.aggregateCompositions, isEmpty);
    },
  );

  test(
    'supplement requires matching symbol and scale-specific OBJECTID',
    () async {
      final source = <String, Object?>{
        'OBJECTID': 617,
        'SIMBC': 'SEl3',
        'SERIE1': 'FLORA',
      };
      final series = GisSoilSeries.fromProperties(source);

      final wrongSymbol = await repository.enrichCardSeries(
        feature: _feature({...source, 'SIMBC': 'otro símbolo'}),
        sourceSeries: series,
      );
      final wrongScale = await repository.enrichCardSeries(
        feature: _feature({...source, 'OBJECTID': 100617}),
        sourceSeries: series,
      );

      expect(wrongSymbol.series.single.percentage, isEmpty);
      expect(wrongScale.series.single.percentage, isEmpty);
      expect(wrongSymbol.aggregateCompositions, isEmpty);
      expect(wrongScale.aggregateCompositions, isEmpty);
    },
  );

  test(
    'existing source percentage takes precedence over the supplement',
    () async {
      final properties = <String, Object?>{
        'OBJECTID': 617,
        'SIMBC': 'SEl3',
        'SERIE1': 'FLORA',
        'PORC1': 19,
      };
      final result = await repository.enrichCardSeries(
        feature: _feature(properties),
        sourceSeries: GisSoilSeries.fromProperties(properties),
      );

      expect(result.series.single.percentage, '19');
    },
  );

  test(
    'missing source percentages remain unavailable; BA is unchanged',
    () async {
      for (final properties in [
        <String, Object?>{
          'OBJECTID': 3,
          'SIMBC': 'sin registro',
          'SERIE1': 'X',
        },
        <String, Object?>{
          'OBJECTID': 175,
          'SIMBC': 'AVi3',
          'SERIE1': 'Bragado',
        },
        <String, Object?>{
          'OBJECTID': 100271,
          'SIMBC': 'AEtc-2',
          'SERIE1': 'ARROYITO',
          'PORC1': 30,
          'SERIE2': 'ALTOS DE CHIPIÓN',
          'PORC2': 30,
          'SERIE3': 'LA ARGENTINA',
          'PORC3': 20,
          'SERIE4': 'suelos hidro-halomórficos',
          'PORC4': 20,
        },
      ]) {
        final parsed = GisSoilSeries.fromProperties(properties);
        final result = await repository.enrichCardSeries(
          feature: _feature(properties),
          sourceSeries: parsed,
        );
        expect(
          result.series.map((series) => series.percentage),
          parsed.map((series) => series.percentage),
        );
        expect(result.aggregateCompositions, isEmpty);
      }
    },
  );
}

GisFeature _feature(Map<String, Object?> properties) => GisFeature(
  id: 'cordoba:test',
  geometry: const GisGeometry(type: 'Polygon', coordinates: <Object>[]),
  properties: properties,
  locality: '',
  soilMapId: 0,
);
