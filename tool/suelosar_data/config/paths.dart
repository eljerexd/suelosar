import 'dart:io';

import 'package:path/path.dart' as p;

/// Invalid usage or configuration — the CLI maps it to exit code 2.
class ConfigException implements Exception {
  ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Locates the SuelosAR repository root: the nearest ancestor of [start]
/// (default: the working directory) holding `pubspec.yaml` and
/// `tool/suelosar_data.dart`.
Directory findRepoRoot([Directory? start]) {
  var dir = (start ?? Directory.current).absolute;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        File(p.join(dir.path, 'tool', 'suelosar_data.dart')).existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw ConfigException(
        'No se encontró la raíz del repositorio SuelosAR desde '
        '${(start ?? Directory.current).path}. Ejecutá la herramienta desde el repo.',
      );
    }
    dir = parent;
  }
}

final _variable = RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}');

/// Expands `${REPO}`, `${PROVINCE}` and environment variables, then resolves
/// a relative result against [baseDir] (the province directory).
String resolveConfigPath(
  String raw, {
  required String baseDir,
  required String repoRoot,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final expanded = raw.replaceAllMapped(_variable, (match) {
    final name = match.group(1)!;
    if (name == 'REPO') return repoRoot;
    if (name == 'PROVINCE') return baseDir;
    final value =
        env[name] ??
        // Windows environment names are case-insensitive.
        env.entries
            .where((e) => e.key.toUpperCase() == name.toUpperCase())
            .map((e) => e.value)
            .firstOrNull;
    if (value == null) {
      throw ConfigException(
        'Variable de entorno no definida: \${$name} (en "$raw").',
      );
    }
    return value;
  });
  final path = p.isAbsolute(expanded) ? expanded : p.join(baseDir, expanded);
  return p.normalize(path);
}

/// [path] relative to [repoRoot] with forward slashes when inside the repo;
/// otherwise the absolute path. Used for readable report locations.
String displayPath(String path, String repoRoot) {
  if (p.isWithin(repoRoot, path)) {
    return p.relative(path, from: repoRoot).replaceAll(r'\', '/');
  }
  return path;
}
