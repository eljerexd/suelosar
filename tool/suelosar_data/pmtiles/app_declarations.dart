import 'dart:io';

import 'package:path/path.dart' as p;

import 'pmtiles_metadata.dart';

/// What the Flutter app currently hard-codes about one province's
/// archive, read (never written) from `lib/gis/province_config.dart`,
/// `lib/gis/map_coverage.dart` and `lib/constants/asset_paths.dart`.
class AppProvinceDeclaration {
  const AppProvinceDeclaration({
    required this.field,
    required this.id,
    required this.pmtilesAsset,
    required this.downloadSizeBytes,
    required this.bounds,
  });

  /// `ProvinceConfig.<field>` / `MapCoverage.<field>`.
  final String field;
  final String? id;
  final String? pmtilesAsset;
  final int? downloadSizeBytes;
  final GeoBoundsValue? bounds;
}

/// Parses the app sources. The parser is deliberately literal — it only
/// understands the shapes those files have today — and every lookup is
/// optional, so an unexpected shape yields "not found", never a wrong value.
class AppDeclarations {
  AppDeclarations._(this.provinces);

  static AppDeclarations read(String repoRoot) {
    String source(String relative) {
      final file = File(p.join(repoRoot, relative));
      return file.existsSync()
          ? stripDartComments(file.readAsStringSync())
          : '';
    }

    return parse(
      assetPaths: source('lib/constants/asset_paths.dart'),
      provinceConfig: source('lib/gis/province_config.dart'),
      mapCoverage: source('lib/gis/map_coverage.dart'),
    );
  }

  static AppDeclarations parse({
    required String assetPaths,
    required String provinceConfig,
    required String mapCoverage,
  }) {
    final constants = {
      for (final m in RegExp(
        r"static\s+const\s+String\s+(\w+)\s*=\s*'([^']*)'",
      ).allMatches(assetPaths))
        m.group(1)!: m.group(2)!,
    };

    String? resolveAsset(String? expression) {
      if (expression == null) return null;
      final constant = RegExp(r'^AssetPaths\.(\w+)$').firstMatch(expression);
      if (constant != null) return constants[constant.group(1)];
      final literal = RegExp(r"^'([^']*)'$").firstMatch(expression);
      return literal?.group(1);
    }

    final bounds = <String, GeoBoundsValue>{};
    for (final m in RegExp(
      r'static\s+final\s+MapCoverage\s+(\w+)\s*=\s*MapCoverage\(',
    ).allMatches(mapCoverage)) {
      final block = balanced(mapCoverage, m.end - 1, '(', ')');
      final config = RegExp(
        r'config:\s*ProvinceConfig\.(\w+)',
      ).firstMatch(block)?.group(1);
      double? number(String name) => double.tryParse(
        RegExp('$name:\\s*(-?[0-9.]+)').firstMatch(block)?.group(1) ?? '',
      );
      final values = [
        number('minLatitude'),
        number('maxLatitude'),
        number('minLongitude'),
        number('maxLongitude'),
      ];
      if (config != null && values.every((v) => v != null)) {
        bounds[config] = GeoBoundsValue(
          minLatitude: values[0]!,
          maxLatitude: values[1]!,
          minLongitude: values[2]!,
          maxLongitude: values[3]!,
        );
      }
    }

    final provinces = <AppProvinceDeclaration>[];
    final statics = RegExp(
      r'static\s+final\s+ProvinceConfig\s+(\w+)\s*=\s*(?:ProvinceConfig\(|(_\w+)\(\)\s*;)',
    );
    for (final m in statics.allMatches(provinceConfig)) {
      final field = m.group(1)!;
      final builder = m.group(2);
      final String block;
      if (builder == null) {
        block = balanced(provinceConfig, m.end - 1, '(', ')');
      } else {
        final function = RegExp(
          'ProvinceConfig\\s+${RegExp.escape(builder)}\\s*\\(\\)\\s*\\{',
        ).firstMatch(provinceConfig);
        if (function == null) continue;
        block = balanced(provinceConfig, function.end - 1, '{', '}');
      }
      final size = RegExp(
        r'pmtilesDownloadSizeBytes:\s*([0-9_]+)',
      ).firstMatch(block)?.group(1);
      provinces.add(
        AppProvinceDeclaration(
          field: field,
          id: RegExp(r"\bid:\s*'([^']+)'").firstMatch(block)?.group(1),
          pmtilesAsset: resolveAsset(
            RegExp(
              r"pmtilesAsset:\s*(AssetPaths\.\w+|'[^']*')",
            ).firstMatch(block)?.group(1),
          ),
          downloadSizeBytes: size == null
              ? null
              : int.parse(size.replaceAll('_', '')),
          bounds: bounds[field],
        ),
      );
    }
    return AppDeclarations._(provinces);
  }

  final List<AppProvinceDeclaration> provinces;

  /// The province whose `pmtilesAsset` is [assetPath] (repo-relative,
  /// forward slashes).
  AppProvinceDeclaration? forAsset(String assetPath) => provinces
      .where((province) => province.pmtilesAsset == assetPath)
      .firstOrNull;

  /// Text between the bracket at [openIndex] and its matching close,
  /// skipping string literals.
  static String balanced(
    String source,
    int openIndex,
    String open,
    String close,
  ) {
    var depth = 0;
    String? quote;
    for (var i = openIndex; i < source.length; i++) {
      final c = source[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
      } else if (c == open) {
        depth++;
      } else if (c == close) {
        depth--;
        if (depth == 0) return source.substring(openIndex, i + 1);
      }
    }
    return source.substring(openIndex);
  }
}

/// Removes `//` and `/* */` comments outside string literals (comments in
/// these files contain brackets and numbers that would confuse the parser).
String stripDartComments(String source) {
  final out = StringBuffer();
  String? quote;
  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < source.length) {
        out.write(source[++i]);
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
    } else if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      out.write('\n');
    } else if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      final end = source.indexOf('*/', i + 2);
      i = end == -1 ? source.length : end + 1;
    } else {
      out.write(c);
    }
  }
  return out.toString();
}
