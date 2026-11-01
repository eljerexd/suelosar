import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../normalize/field_mapping.dart';
import '../schema/suelosar_schema.dart';
import 'paths.dart';

enum GisFormat {
  shapefile('shapefile'),
  geojson('geojson'),
  geojsonLines('geojson_lines');

  const GisFormat(this.key);
  final String key;
}

/// How a raw `SERIEn` value becomes a series key.
enum SeriesCodeRule {
  /// The whole value is the series name (Buenos Aires).
  wholeValue('whole_value'),

  /// The leading token is the series code (`"CER cc"` -> `"CER"`, Santa Fe).
  firstToken('first_token');

  const SeriesCodeRule(this.key);
  final String key;
}

/// How series keys from the GIS are compared with the catalog.
enum SeriesMatch {
  /// `PdfSeriesRepository.normalizeName` on both sides.
  normalizedName('normalized_name'),

  /// Trimmed, lower-cased codes (`SantaFeSeriesRepository.normalizeCode`).
  caseInsensitive('case_insensitive');

  const SeriesMatch(this.key);
  final String key;
}

enum PdfModel {
  perSeries('per_series'),
  consolidated('consolidated'),

  /// The documented-series list comes straight from a JSON index file
  /// (`{"series":[{"name":...,"startPage":...,"endPage":...}, ...]}`) —
  /// Parte 12B: Córdoba's PDF is one already-unified 409-series document
  /// (built outside this pipeline, in `output/`), and its own
  /// `cordoba_series_index.json` is the single source of truth for which
  /// series it documents. Avoids re-deriving the same list by re-parsing
  /// the PDF's table of contents (fragile) or requiring a directory of
  /// per-series files that doesn't exist for this edition. Generic — any
  /// future province with a similar unified-PDF-plus-index setup can use
  /// it, not specific to Córdoba.
  indexReference('index_reference');

  const PdfModel(this.key);
  final String key;
}

enum JsonStyle {
  /// `JsonEncoder.withIndent('  ')`, no trailing newline.
  standard('standard'),

  /// Windows PowerShell 5.1 `ConvertTo-Json` layout (used by `soil_maps.json`).
  powershell('powershell');

  const JsonStyle(this.key);
  final String key;
}

class SeriesConfig {
  const SeriesConfig({
    required this.codeRule,
    required this.match,
    required this.aliases,
    this.notSeries,
    this.extraSeriesFields = const [],
  });

  final SeriesCodeRule codeRule;
  final SeriesMatch match;

  /// GIS code -> catalog code, applied before matching.
  final Map<String, String> aliases;

  /// `SERIEn` values matching this pattern are map-unit components that are
  /// not soil series ("suelos menores", "roca expuesta"): they stay in the
  /// data, but are not looked up in the catalog.
  final RegExp? notSeries;

  /// Beyond [SuelosArSchema.seriesFields] (fixed at [SuelosArSchema
  /// .seriesSlots], the same for every province): extra optional series
  /// fields (from [SuelosArSchema.optionalFields] — `SERIE7`/`SERIE8`,
  /// Parte 12B) this province's own mapping declares and wants the
  /// series-detection/catalog cross-reference to also scan. Empty for
  /// every province that doesn't need more than [SuelosArSchema
  /// .seriesSlots] components per unit.
  final List<String> extraSeriesFields;
}

class ThresholdConfig {
  const ThresholdConfig({
    required this.warnBelow,
    required this.errorBelow,
    required this.fields,
  });

  /// Percentages (0-100).
  final double warnBelow;
  final double errorBelow;

  /// Target fields held to these thresholds.
  final List<String> fields;
}

class GisConfig {
  const GisConfig({
    required this.source,
    required this.format,
    required this.encoding,
    required this.layerName,
    required this.mapping,
    required this.series,
    required this.thresholds,
    this.additionalSources = const [],
    this.scalePriority,
  });

  final String source;
  final GisFormat format;

  /// Declared text encoding; null means "use the `.cpg`" (shapefile) or
  /// UTF-8 (GeoJSON).
  final String? encoding;
  final String layerName;
  final FieldMapping mapping;
  final SeriesConfig series;
  final ThresholdConfig thresholds;

  /// Extra GIS sources merged in after [source] (Parte 12: Córdoba's
  /// `carta_suelo_100mil_2025`, filling the area `source`'s own
  /// `carta_suelo_50mil_2025` doesn't cover). Empty for every province that
  /// still has just one source — nothing about the single-source path
  /// changes when this is empty.
  final List<AdditionalGisSource> additionalSources;

  /// Required when [additionalSources] is non-empty: the official scale
  /// index that decides, geographically, which of the additional sources'
  /// features are kept (see [AdditionalGisSource.scale]).
  final ScalePriorityConfig? scalePriority;
}

/// One extra GIS source merged in after the primary [GisConfig.source], kept
/// only where the official [ScalePriorityConfig.indexFile] says [scale]
/// applies — so it can never override or duplicate the primary source's own
/// coverage, regardless of file order.
class AdditionalGisSource {
  const AdditionalGisSource({
    required this.id,
    required this.scale,
    required this.source,
    required this.format,
    required this.encoding,
    required this.mapping,
    required this.objectIdOffset,
  });

  /// Short label for reports/debugging (Parte 12 §7's "internal provenance
  /// marker") — never written into the normalized GeoJSON's own schema.
  final String id;

  /// Value of [ScalePriorityConfig.field] this source's own features must
  /// fall under to be kept (e.g. `"1:100000"`).
  final String scale;

  final String source;
  final GisFormat format;
  final String? encoding;
  final FieldMapping mapping;

  /// Added to this source's own `OBJECTID` so it can never collide with the
  /// primary source's — a fixed, reversible namespace (`original =
  /// OBJECTID - objectIdOffset`), not a re-hash.
  final int objectIdOffset;
}

class ScalePriorityConfig {
  const ScalePriorityConfig({
    required this.indexFile,
    required this.field,
    required this.primaryScale,
  });

  /// Official scale-coverage polygons (IDECOR's own
  /// `escalas_cartograficas_2025`), one feature per scale zone.
  final String indexFile;

  /// Property on [indexFile]'s features holding the scale label (e.g.
  /// `"escala_carto"`).
  final String field;

  /// The primary source's own scale label, purely descriptive (used in
  /// reports; the primary source itself is never geographically filtered —
  /// it always has full priority in its own zone, per Parte 12 §2).
  final String primaryScale;
}

class TocConfig {
  const TocConfig({
    required this.firstPage,
    required this.lastPage,
    required this.seriesPattern,
    required this.entryPattern,
    required this.headingPattern,
    required this.pageOffset,
  });

  final int firstPage;
  final int lastPage;
  final RegExp seriesPattern;
  final RegExp entryPattern;

  /// Template with `{name}`/`{code}` placeholders, matched at the start of a
  /// page to find where a series really begins.
  final String headingPattern;

  /// Null means "detect automatically".
  final int? pageOffset;
}

class PdfConfig {
  const PdfConfig({
    required this.model,
    this.directory,
    this.wordSeparator,
    this.file,
    this.assetPath,
    this.toc,
    this.indexFile,
  });

  final PdfModel model;

  // per_series
  final String? directory;
  final String? wordSeparator;

  // consolidated
  final String? file;
  final String? assetPath;
  final TocConfig? toc;

  // index_reference
  final String? indexFile;
}

class CatalogConfig {
  const CatalogConfig({
    required this.output,
    required this.reference,
    required this.jsonStyle,
    required this.provinceLabel,
  });

  /// File name written to the province `output/` directory.
  final String output;

  /// The catalog the app ships today, compared with (and, for per-series
  /// catalogs, the source of stable ids). Null for a new province.
  final String? reference;
  final JsonStyle jsonStyle;

  /// `province` value of a consolidated index.
  final String provinceLabel;
}

/// Which file feeds the Docker pipeline (`pmtiles.input`).
enum PmtilesInput {
  /// The original source when it is a shapefile mapped column-for-column,
  /// otherwise the normalized GeoJSON.
  auto('auto'),
  source('source'),
  normalized('normalized');

  const PmtilesInput(this.key);
  final String key;
}

/// When the optimizer rewrites the archive (`pmtiles.optimize`).
enum OptimizeMode {
  /// Only when the archive carries attributes outside the schema;
  /// otherwise the archive is copied unchanged.
  auto('auto'),
  always('always'),
  never('never');

  const OptimizeMode(this.key);
  final String key;
}

class PmtilesConfig {
  const PmtilesConfig({
    required this.output,
    required this.reference,
    required this.layer,
    required this.minZoom,
    required this.maxZoom,
    required this.input,
    required this.optimize,
  });

  /// File name of the published archive inside `output/`.
  final String output;

  /// The archive the app ships today — only compared with, never written.
  final String? reference;
  final String layer;
  final int minZoom;
  final int maxZoom;
  final PmtilesInput input;
  final OptimizeMode optimize;

  /// `output` without `.pmtiles`.
  String get stem => output.substring(0, output.length - '.pmtiles'.length);

  /// Constraints of docker/build_map.sh: the low-detail tier ends at z6 and
  /// the fixed tiers need z13 or more at the top.
  static const minZoomRange = (0, 6);
  static const maxZoomRange = (13, 20);
}

class ProvinceDefinition {
  const ProvinceDefinition({
    required this.id,
    required this.name,
    required this.directory,
    required this.repoRoot,
    required this.gis,
    required this.pdf,
    required this.catalog,
    required this.pmtiles,
    required this.xrefErrorAbovePercent,
    required this.dockerImage,
    this.raw = const {},
  });

  final String id;
  final String name;

  /// `data/provinces/<id>`.
  final String directory;
  final String repoRoot;
  final GisConfig gis;
  final PdfConfig? pdf;
  final CatalogConfig? catalog;
  final PmtilesConfig? pmtiles;

  /// Share of GIS features whose series has no catalog entry above which
  /// XRF001 becomes an error.
  final double xrefErrorAbovePercent;
  final String dockerImage;

  /// The parsed YAML, used to fingerprint configuration sections.
  final Map<String, Object?> raw;

  String get configFile => p.join(directory, 'province.yaml');
  String get workDir => p.join(directory, 'work');
  String get outputDir => p.join(directory, 'output');
  String get stagesDir => p.join(outputDir, 'stages');
  String get normalizedGisFile => p.join(workDir, 'normalized.geojson');
  String get pmtilesMetadataFile => p.join(outputDir, 'pmtiles_metadata.json');
  String get stampsDir => p.join(workDir, 'stamps');
  String get logsDir => p.join(workDir, 'logs');
  String get mapInputDir => p.join(workDir, 'map_input');
  String get mapInputFile => p.join(mapInputDir, 'map_input.geojson');
  String get pmtilesWorkDir => p.join(workDir, 'pmtiles');

  /// Raw archive written by Docker.
  String? get fullPmtilesFile => pmtiles == null
      ? null
      : p.join(pmtilesWorkDir, '${pmtiles!.stem}.full.pmtiles');

  /// Archive after the optimize stage, before publication.
  String? get optimizedPmtilesFile =>
      pmtiles == null ? null : p.join(pmtilesWorkDir, pmtiles!.output);

  /// Archive published only when every stage passed.
  String? get publishedPmtilesFile =>
      pmtiles == null ? null : p.join(outputDir, pmtiles!.output);

  String? get catalogOutputFile =>
      catalog == null ? null : p.join(outputDir, catalog!.output);

  String display(String path) => displayPath(path, repoRoot);

  static String provinceDirectory(String provincesDir, String id) =>
      p.join(provincesDir, id);

  /// Loads `<provincesDir>/<id>/province.yaml`. Any structural problem is a
  /// [ConfigException] (CLI exit code 2) listing every issue found.
  static ProvinceDefinition load({
    required String id,
    required String provincesDir,
    required String repoRoot,
    Map<String, String>? environment,
  }) {
    final directory = p.normalize(
      p.absolute(provinceDirectory(provincesDir, id)),
    );
    final file = File(p.join(directory, 'province.yaml'));
    if (!file.existsSync()) {
      throw ConfigException(
        'CFG001 No existe ${displayPath(file.path, repoRoot)}. '
        'Creala con: dart run tool/suelosar_data.dart init $id',
      );
    }
    final Object? yaml;
    try {
      yaml = loadYaml(file.readAsStringSync(), sourceUrl: file.uri);
    } on YamlException catch (e) {
      throw ConfigException(
        'CFG001 YAML inválido en ${file.path}: ${e.message}',
      );
    }
    final root = _plain(yaml);
    if (root is! Map<String, Object?>) {
      throw ConfigException('CFG001 ${file.path} debe ser un mapa YAML.');
    }
    final reader = _Reader(
      root,
      baseDir: directory,
      repoRoot: repoRoot,
      environment: environment,
    );
    final definition = reader.read(expectedId: id);
    if (reader.problems.isNotEmpty) {
      throw ConfigException(
        'CFG001 Configuración inválida (${displayPath(file.path, repoRoot)}):\n'
        '${reader.problems.map((problem) => '  - $problem').join('\n')}',
      );
    }
    return definition!;
  }
}

Object? _plain(Object? node) {
  if (node is YamlMap) {
    return <String, Object?>{
      for (final entry in node.entries)
        entry.key.toString(): _plain(entry.value),
    };
  }
  if (node is YamlList) return [for (final item in node) _plain(item)];
  return node;
}

class _Reader {
  _Reader(
    this.root, {
    required this.baseDir,
    required this.repoRoot,
    required this.environment,
  });

  final Map<String, Object?> root;
  final String baseDir;
  final String repoRoot;
  final Map<String, String>? environment;
  final problems = <String>[];

  ProvinceDefinition? read({required String expectedId}) {
    final id = _string(root, 'id', 'id');
    if (id != null && id != expectedId) {
      problems.add('id "$id" no coincide con la carpeta "$expectedId".');
    }
    final name = _string(root, 'name', 'name');
    final gis = _gis(_map(root, 'gis', 'gis'));
    final pdfNode = root['pdf'];
    final pdf = pdfNode == null ? null : _pdf(_map(root, 'pdf', 'pdf'));
    final catalogNode = root['catalog'];
    final catalog = catalogNode == null
        ? null
        : _catalog(_map(root, 'catalog', 'catalog'), name ?? expectedId, pdf);
    if (pdf != null && catalog == null) {
      problems.add('catalog: obligatorio cuando se declara pdf.');
    }
    final pmtilesNode = root['pmtiles'];
    final pmtiles = pmtilesNode == null
        ? null
        : _pmtiles(_map(root, 'pmtiles', 'pmtiles'), expectedId);
    final xref = root['xref'] == null ? null : _map(root, 'xref', 'xref');
    final xrefError = xref == null
        ? 50.0
        : _number(
            xref,
            'error_above_percent',
            'xref.error_above_percent',
            fallback: 50,
          );
    final docker = root['docker'] == null
        ? null
        : _map(root, 'docker', 'docker');
    final image = docker == null
        ? 'suelosar-gis-builder:local'
        : _string(docker, 'image', 'docker.image', optional: true) ??
              'suelosar-gis-builder:local';

    if (problems.isNotEmpty || id == null || name == null || gis == null) {
      return null;
    }
    return ProvinceDefinition(
      id: id,
      name: name,
      directory: baseDir,
      repoRoot: repoRoot,
      gis: gis,
      pdf: pdf,
      catalog: catalog,
      pmtiles: pmtiles,
      xrefErrorAbovePercent: xrefError ?? 50,
      dockerImage: image,
      raw: root,
    );
  }

  GisConfig? _gis(Map<String, Object?>? node) {
    if (node == null) return null;
    final source = _path(node, 'source', 'gis.source');
    final format = _enum(
      node,
      'format',
      'gis.format',
      GisFormat.values,
      (f) => f.key,
    );
    final encoding = _string(node, 'encoding', 'gis.encoding', optional: true);
    final layer =
        _string(node, 'layer_name', 'gis.layer_name', optional: true) ??
        'soil_polygons';
    final mappingNode = _map(node, 'mapping', 'gis.mapping');
    FieldMapping? mapping;
    if (mappingNode != null) {
      try {
        mapping = FieldMapping.parse(mappingNode);
      } on FormatException catch (e) {
        problems.add('gis.mapping: ${e.message}');
      }
    }
    final seriesNode = node['series'] == null
        ? <String, Object?>{}
        : _map(node, 'series', 'gis.series');
    final codeRule = _enum(
      seriesNode ?? {},
      'code_rule',
      'gis.series.code_rule',
      SeriesCodeRule.values,
      (r) => r.key,
      fallback: SeriesCodeRule.wholeValue,
    );
    final match = _enum(
      seriesNode ?? {},
      'match',
      'gis.series.match',
      SeriesMatch.values,
      (m) => m.key,
      fallback: SeriesMatch.normalizedName,
    );
    final aliasesNode = seriesNode?['aliases'];
    final aliases = <String, String>{};
    if (aliasesNode is Map) {
      aliasesNode.forEach(
        (key, value) => aliases[key.toString()] = value.toString(),
      );
    } else if (aliasesNode != null) {
      problems.add(
        'gis.series.aliases: debe ser un mapa código GIS -> código de catálogo.',
      );
    }
    final notSeriesNode = seriesNode?['not_series'];
    RegExp? notSeries;
    if (notSeriesNode is String && notSeriesNode.isNotEmpty) {
      try {
        notSeries = RegExp(notSeriesNode);
      } on FormatException catch (e) {
        problems.add(
          'gis.series.not_series: expresión regular inválida (${e.message}).',
        );
      }
    } else if (notSeriesNode != null) {
      problems.add(
        'gis.series.not_series: debe ser una expresión regular (texto).',
      );
    }
    final extraFieldsNode = seriesNode?['extra_fields'];
    final extraSeriesFields = <String>[];
    if (extraFieldsNode is List) {
      for (final raw in extraFieldsNode) {
        final field = raw.toString();
        if (!SuelosArSchema.optionalFields.contains(field) ||
            field == 'OBJECTID') {
          problems.add(
            'gis.series.extra_fields: "$field" no es un campo de serie '
            'opcional del esquema SuelosAR '
            '(${SuelosArSchema.optionalFields.where((f) => f != 'OBJECTID').join(', ')}).',
          );
        } else {
          extraSeriesFields.add(field);
        }
      }
    } else if (extraFieldsNode != null) {
      problems.add('gis.series.extra_fields: debe ser una lista.');
    }
    final thresholdsNode = node['thresholds'] == null
        ? <String, Object?>{}
        : _map(node, 'thresholds', 'gis.thresholds');
    final warnBelow = _number(
      thresholdsNode ?? {},
      'warn_below',
      'gis.thresholds.warn_below',
      fallback: 90,
    );
    final errorBelow = _number(
      thresholdsNode ?? {},
      'error_below',
      'gis.thresholds.error_below',
      fallback: 50,
    );
    final fieldsNode = thresholdsNode?['fields'];
    List<String>? fields;
    if (fieldsNode is List) {
      fields = [for (final f in fieldsNode) f.toString()];
    } else if (fieldsNode != null) {
      problems.add('gis.thresholds.fields: debe ser una lista.');
    }
    final additionalNode = node['additional_sources'];
    final additionalSources = <AdditionalGisSource>[];
    if (additionalNode is List) {
      for (var i = 0; i < additionalNode.length; i++) {
        final entry = additionalNode[i];
        if (entry is! Map<String, Object?>) {
          problems.add('gis.additional_sources[$i]: debe ser un mapa.');
          continue;
        }
        final parsed = _additionalSource(entry, 'gis.additional_sources[$i]');
        if (parsed != null) additionalSources.add(parsed);
      }
    } else if (additionalNode != null) {
      problems.add('gis.additional_sources: debe ser una lista.');
    }
    final scalePriorityNode = node['scale_priority'];
    ScalePriorityConfig? scalePriority;
    if (scalePriorityNode != null) {
      scalePriority = _scalePriority(
        _map(node, 'scale_priority', 'gis.scale_priority'),
      );
    }
    if (additionalSources.isNotEmpty && scalePriority == null) {
      problems.add(
        'gis.scale_priority: obligatorio cuando se declara '
        'gis.additional_sources.',
      );
    }

    if (source == null ||
        format == null ||
        mapping == null ||
        codeRule == null ||
        match == null) {
      return null;
    }
    return GisConfig(
      source: source,
      format: format,
      encoding: encoding,
      layerName: layer,
      mapping: mapping,
      series: SeriesConfig(
        codeRule: codeRule,
        match: match,
        aliases: aliases,
        notSeries: notSeries,
        extraSeriesFields: extraSeriesFields,
      ),
      thresholds: ThresholdConfig(
        warnBelow: warnBelow ?? 90,
        errorBelow: errorBelow ?? 50,
        fields: fields ?? SuelosArSchema.defaultThresholdFields,
      ),
      additionalSources: additionalSources,
      scalePriority: scalePriority,
    );
  }

  AdditionalGisSource? _additionalSource(
    Map<String, Object?> node,
    String where,
  ) {
    final id = _string(node, 'id', '$where.id');
    final scale = _string(node, 'scale', '$where.scale');
    final source = _path(node, 'source', '$where.source');
    final format = _enum(
      node,
      'format',
      '$where.format',
      GisFormat.values,
      (f) => f.key,
    );
    final encoding = _string(node, 'encoding', '$where.encoding', optional: true);
    final mappingNode = _map(node, 'mapping', '$where.mapping');
    FieldMapping? mapping;
    if (mappingNode != null) {
      try {
        mapping = FieldMapping.parse(mappingNode);
      } on FormatException catch (e) {
        problems.add('$where.mapping: ${e.message}');
      }
    }
    final offsetNode = node['objectid_offset'];
    int? offset;
    if (offsetNode is int && offsetNode >= 1) {
      offset = offsetNode;
    } else {
      problems.add(
        '$where.objectid_offset: obligatorio, entero > 0 (debe dejar '
        'espacio por encima del OBJECTID máximo de la fuente principal, '
        'para que no puedan colisionar).',
      );
    }
    if (id == null ||
        scale == null ||
        source == null ||
        format == null ||
        mapping == null ||
        offset == null) {
      return null;
    }
    return AdditionalGisSource(
      id: id,
      scale: scale,
      source: source,
      format: format,
      encoding: encoding,
      mapping: mapping,
      objectIdOffset: offset,
    );
  }

  ScalePriorityConfig? _scalePriority(Map<String, Object?>? node) {
    if (node == null) return null;
    final indexFile = _path(node, 'index', 'gis.scale_priority.index');
    final field =
        _string(node, 'field', 'gis.scale_priority.field', optional: true) ??
        'escala_carto';
    final primaryScale = _string(
      node,
      'primary_scale',
      'gis.scale_priority.primary_scale',
    );
    if (indexFile == null || primaryScale == null) return null;
    return ScalePriorityConfig(
      indexFile: indexFile,
      field: field,
      primaryScale: primaryScale,
    );
  }

  PdfConfig? _pdf(Map<String, Object?>? node) {
    if (node == null) return null;
    final model = _enum(
      node,
      'model',
      'pdf.model',
      PdfModel.values,
      (m) => m.key,
    );
    switch (model) {
      case null:
        return null;
      case PdfModel.perSeries:
        final directory = _path(node, 'directory', 'pdf.directory');
        final naming = node['naming'] == null
            ? null
            : _map(node, 'naming', 'pdf.naming');
        final separator = naming == null
            ? '_'
            : _string(
                    naming,
                    'word_separator',
                    'pdf.naming.word_separator',
                    optional: true,
                  ) ??
                  '_';
        if (directory == null) return null;
        return PdfConfig(
          model: model,
          directory: directory,
          wordSeparator: separator,
        );
      case PdfModel.consolidated:
        final file = _path(node, 'file', 'pdf.file');
        final asset = _string(node, 'asset_path', 'pdf.asset_path');
        final toc = _toc(_map(node, 'toc', 'pdf.toc'));
        if (file == null || asset == null || toc == null) return null;
        return PdfConfig(model: model, file: file, assetPath: asset, toc: toc);
      case PdfModel.indexReference:
        final indexFile = _path(node, 'index_file', 'pdf.index_file');
        final asset = _string(
          node,
          'asset_path',
          'pdf.asset_path',
          optional: true,
        );
        if (indexFile == null) return null;
        return PdfConfig(model: model, indexFile: indexFile, assetPath: asset);
    }
  }

  TocConfig? _toc(Map<String, Object?>? node) {
    if (node == null) return null;
    final pages = node['pages'];
    int? first;
    int? last;
    if (pages is List && pages.length == 2 && pages.every((v) => v is int)) {
      first = pages[0] as int;
      last = pages[1] as int;
      if (first < 1 || last < first) {
        problems.add('pdf.toc.pages: rango inválido $pages.');
      }
    } else {
      problems.add(
        'pdf.toc.pages: debe ser [primera, última] (páginas físicas, desde 1).',
      );
    }
    final series = _regex(
      node,
      'series_pattern',
      'pdf.toc.series_pattern',
      const ['name', 'code', 'page'],
    );
    final entry = _regex(node, 'entry_pattern', 'pdf.toc.entry_pattern', const [
      'page',
    ]);
    final heading = _string(node, 'heading_pattern', 'pdf.toc.heading_pattern');
    final offsetNode = node['page_offset'];
    int? offset;
    if (offsetNode is int) {
      offset = offsetNode;
    } else if (offsetNode != 'auto') {
      problems.add('pdf.toc.page_offset: debe ser un entero o "auto".');
    }
    if (first == null ||
        last == null ||
        series == null ||
        entry == null ||
        heading == null) {
      return null;
    }
    return TocConfig(
      firstPage: first,
      lastPage: last,
      seriesPattern: series,
      entryPattern: entry,
      headingPattern: heading,
      pageOffset: offset,
    );
  }

  CatalogConfig? _catalog(
    Map<String, Object?>? node,
    String provinceName,
    PdfConfig? pdf,
  ) {
    if (node == null) return null;
    final output = _string(node, 'output', 'catalog.output');
    if (output != null && (output.contains('/') || output.contains(r'\'))) {
      problems.add(
        'catalog.output: debe ser un nombre de archivo, sin carpetas.',
      );
    }
    final reference = node['reference'] == null
        ? null
        : _path(node, 'reference', 'catalog.reference');
    final style = _enum(
      node,
      'json_style',
      'catalog.json_style',
      JsonStyle.values,
      (s) => s.key,
      fallback: JsonStyle.standard,
    );
    final label =
        _string(
          node,
          'province_label',
          'catalog.province_label',
          optional: true,
        ) ??
        provinceName;
    if (output == null || style == null) return null;
    return CatalogConfig(
      output: output,
      reference: reference,
      jsonStyle: style,
      provinceLabel: label,
    );
  }

  PmtilesConfig? _pmtiles(Map<String, Object?>? node, String id) {
    if (node == null) return null;
    if (node.containsKey('file')) {
      problems.add(
        'pmtiles.file: se renombró a pmtiles.reference (el archivo que usa '
        'la app hoy, solo para comparar).',
      );
    }
    final unknown = node.keys.toSet().difference({
      'file',
      'output',
      'reference',
      'layer',
      'zooms',
      'input',
      'optimize',
    });
    if (unknown.isNotEmpty) {
      problems.add('pmtiles: claves desconocidas ${unknown.join(', ')}.');
    }
    final output =
        _string(node, 'output', 'pmtiles.output', optional: true) ??
        '${id}_soil_polygons.pmtiles';
    if (output.contains('/') ||
        output.contains(r'\') ||
        !output.toLowerCase().endsWith('.pmtiles') ||
        output.length <= '.pmtiles'.length) {
      problems.add(
        'pmtiles.output: debe ser un nombre de archivo .pmtiles, sin carpetas.',
      );
    }
    final reference = node['reference'] == null
        ? null
        : _path(node, 'reference', 'pmtiles.reference');
    final layer =
        _string(node, 'layer', 'pmtiles.layer', optional: true) ??
        'soil_polygons';
    var minZoom = 4;
    var maxZoom = 14;
    final zooms = node['zooms'];
    if (zooms != null) {
      if (zooms is! Map || zooms['min'] is! int || zooms['max'] is! int) {
        problems.add(
          'pmtiles.zooms: debe ser { min: <entero>, max: <entero> }.',
        );
      } else {
        minZoom = zooms['min'] as int;
        maxZoom = zooms['max'] as int;
        final (minLow, minHigh) = PmtilesConfig.minZoomRange;
        final (maxLow, maxHigh) = PmtilesConfig.maxZoomRange;
        if (minZoom < minLow || minZoom > minHigh) {
          problems.add(
            'pmtiles.zooms.min: debe estar entre $minLow y $minHigh (build_map.sh).',
          );
        }
        if (maxZoom < maxLow || maxZoom > maxHigh) {
          problems.add(
            'pmtiles.zooms.max: debe estar entre $maxLow y $maxHigh (build_map.sh).',
          );
        }
      }
    }
    final input = _enum(
      node,
      'input',
      'pmtiles.input',
      PmtilesInput.values,
      (v) => v.key,
      fallback: PmtilesInput.auto,
    );
    final optimize = _enum(
      node,
      'optimize',
      'pmtiles.optimize',
      OptimizeMode.values,
      (v) => v.key,
      fallback: OptimizeMode.auto,
    );
    if (input == null || optimize == null) return null;
    return PmtilesConfig(
      output: output,
      reference: reference,
      layer: layer,
      minZoom: minZoom,
      maxZoom: maxZoom,
      input: input,
      optimize: optimize,
    );
  }

  // --- primitives ---------------------------------------------------------

  Map<String, Object?>? _map(
    Map<String, Object?> node,
    String key,
    String where,
  ) {
    final value = node[key];
    if (value is Map<String, Object?>) return value;
    problems.add(
      value == null ? '$where: falta.' : '$where: debe ser un mapa.',
    );
    return null;
  }

  String? _string(
    Map<String, Object?> node,
    String key,
    String where, {
    bool optional = false,
  }) {
    final value = node[key];
    if (value == null) {
      if (!optional) problems.add('$where: falta.');
      return null;
    }
    if (value is! String || value.trim().isEmpty) {
      problems.add('$where: debe ser un texto no vacío.');
      return null;
    }
    return value;
  }

  double? _number(
    Map<String, Object?> node,
    String key,
    String where, {
    required double fallback,
  }) {
    final value = node[key];
    if (value == null) return fallback;
    if (value is num && value >= 0 && value <= 100) return value.toDouble();
    problems.add('$where: debe ser un número entre 0 y 100.');
    return null;
  }

  String? _path(Map<String, Object?> node, String key, String where) {
    final raw = _string(node, key, where);
    if (raw == null) return null;
    try {
      return resolveConfigPath(
        raw,
        baseDir: baseDir,
        repoRoot: repoRoot,
        environment: environment,
      );
    } on ConfigException catch (e) {
      problems.add('$where: ${e.message}');
      return null;
    }
  }

  T? _enum<T>(
    Map<String, Object?> node,
    String key,
    String where,
    List<T> values,
    String Function(T) keyOf, {
    T? fallback,
  }) {
    final value = node[key];
    if (value == null) {
      if (fallback == null) {
        problems.add('$where: falta (${values.map(keyOf).join(' | ')}).');
      }
      return fallback;
    }
    for (final candidate in values) {
      if (keyOf(candidate) == value) return candidate;
    }
    problems.add(
      '$where: "$value" no es válido (${values.map(keyOf).join(' | ')}).',
    );
    return null;
  }

  RegExp? _regex(
    Map<String, Object?> node,
    String key,
    String where,
    List<String> groups,
  ) {
    final raw = _string(node, key, where);
    if (raw == null) return null;
    try {
      final regex = RegExp(raw, multiLine: false, unicode: true);
      for (final group in groups) {
        if (!raw.contains('(?<$group>')) {
          problems.add('$where: falta el grupo con nombre (?<$group>...).');
        }
      }
      return regex;
    } on FormatException catch (e) {
      problems.add('$where: expresión regular inválida: ${e.message}');
      return null;
    }
  }
}
