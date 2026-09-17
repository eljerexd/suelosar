import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../config/paths.dart';

/// Files baked into the `suelosar-gis-builder` image.
const dockerScriptFiles = [
  'Dockerfile',
  'build_map.sh',
  'validate_map.py',
  'profile_map.py',
];

/// Image label carrying [dockerScriptsHash] of the scripts it was built from.
const dockerScriptsLabel = 'suelosar.scripts';

/// Content hash of the Docker scripts (line endings normalized, so a CRLF
/// checkout hashes like the LF one).
String dockerScriptsHash(String repoRoot) {
  final builder = BytesBuilder();
  for (final name in dockerScriptFiles) {
    final file = File(p.join(repoRoot, 'docker', name));
    builder
      ..add(utf8.encode('$name\n'))
      ..add(
        file.existsSync()
            ? utf8.encode(file.readAsStringSync().replaceAll('\r\n', '\n'))
            : const <int>[],
      );
  }
  return crypto.sha256.convert(builder.toBytes()).toString();
}

class DockerRunResult {
  const DockerRunResult({
    required this.exitCode,
    required this.durationMs,
    required this.logTail,
  });

  final int exitCode;
  final int durationMs;
  final List<String> logTail;
}

/// Runs `docker/build_map.sh` inside `suelosar-gis-builder` with explicit
/// mounts: the input directory read-only and a work directory for the
/// output. `docker-compose.yml` is not used — it writes into `assets/maps`.
class DockerMapBuilder {
  DockerMapBuilder({
    required this.repoRoot,
    required this.image,
    void Function(String)? log,
  }) : _log = log ?? ((_) {});

  final String repoRoot;
  final String image;
  final void Function(String) _log;

  /// Throws [ConfigException] (exit code 2, DKR001) when Docker cannot run.
  Future<void> ensureAvailable() async {
    try {
      final result = await Process.run('docker', [
        'info',
        '--format',
        '{{.ServerVersion}}',
      ]);
      if (result.exitCode != 0) {
        throw ConfigException(
          'DKR001 Docker no responde (¿Docker Desktop está iniciado?): '
          '${(result.stderr as String).trim()}',
        );
      }
    } on ProcessException catch (e) {
      throw ConfigException(
        'DKR001 No se encontró el comando docker: ${e.message}',
      );
    }
  }

  /// Image id, rebuilding the image first when its label does not match the
  /// current scripts (the build uses Docker's cache).
  Future<({String imageId, bool rebuilt})> ensureImage(File buildLog) async {
    final expected = dockerScriptsHash(repoRoot);
    final current = await _inspectLabel();
    var rebuilt = false;
    if (current != expected) {
      _log(
        current == null
            ? 'Construyendo la imagen $image...'
            : 'Los scripts Docker cambiaron: reconstruyendo $image...',
      );
      final exitCode = await _stream(
        [
          'build',
          '--label',
          '$dockerScriptsLabel=$expected',
          '-t',
          image,
          p.join(repoRoot, 'docker'),
        ],
        buildLog,
        echoPrefix: null,
      );
      if (exitCode != 0) {
        throw ConfigException(
          'DKR001 No se pudo construir la imagen $image (ver ${buildLog.path}).',
        );
      }
      rebuilt = true;
      if (await _inspectLabel() != expected) {
        throw ConfigException(
          'DKR001 La imagen $image no quedó con la etiqueta esperada.',
        );
      }
    }
    final id = await Process.run('docker', [
      'image',
      'inspect',
      '--format',
      '{{.Id}}',
      image,
    ]);
    return (imageId: (id.stdout as String).trim(), rebuilt: rebuilt);
  }

  Future<String?> _inspectLabel() async {
    final result = await Process.run('docker', [
      'image',
      'inspect',
      '--format',
      '{{ index .Config.Labels "$dockerScriptsLabel" }}',
      image,
    ]);
    if (result.exitCode != 0) return null;
    final value = (result.stdout as String).trim();
    return value.isEmpty || value == '<no value>' ? null : value;
  }

  /// Arguments of the `docker run` that builds [outputName] from
  /// [inputFile] (see docker/build_map.sh for the variables).
  List<String> runArguments({
    required String inputFile,
    required String outputDir,
    required String outputName,
    required Map<String, String> environment,
  }) => [
    'run',
    '--rm',
    '--mount',
    'type=bind,source=${p.dirname(p.absolute(inputFile))},target=/data/input,readonly',
    '--mount',
    'type=bind,source=${p.absolute(outputDir)},target=/data/output',
    '-e',
    'SOURCE_SHAPEFILE=${p.basename(inputFile)}',
    '-e',
    'OUTPUT_NAME=$outputName',
    for (final entry in environment.entries) ...[
      '-e',
      '${entry.key}=${entry.value}',
    ],
    image,
  ];

  Future<DockerRunResult> run({
    required String inputFile,
    required String outputDir,
    required String outputName,
    required Map<String, String> environment,
    required File log,
  }) async {
    Directory(outputDir).createSync(recursive: true);
    final watch = Stopwatch()..start();
    final tail = <String>[];
    final exitCode = await _stream(
      runArguments(
        inputFile: inputFile,
        outputDir: outputDir,
        outputName: outputName,
        environment: environment,
      ),
      log,
      echoPrefix: '[SuelosAR GIS]',
      tail: tail,
    );
    return DockerRunResult(
      exitCode: exitCode,
      durationMs: watch.elapsedMilliseconds,
      logTail: tail,
    );
  }

  /// Runs docker with [arguments], writing every output line to [log];
  /// lines starting with [echoPrefix] are also shown on the console.
  Future<int> _stream(
    List<String> arguments,
    File log, {
    required String? echoPrefix,
    List<String>? tail,
  }) async {
    log.parent.createSync(recursive: true);
    final sink = log.openWrite();
    sink.writeln('\$ docker ${arguments.join(' ')}');
    try {
      final process = await Process.start('docker', arguments);
      void onLine(String line) {
        sink.writeln(line);
        // Tippecanoe rewrites its progress with carriage returns.
        final clean = line.split('\r').last.trim();
        if (clean.isEmpty) return;
        if (tail != null) {
          tail.add(clean);
          if (tail.length > 40) tail.removeAt(0);
        }
        if (echoPrefix != null && clean.startsWith(echoPrefix)) _log(clean);
      }

      final done = Future.wait([
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach(onLine),
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach(onLine),
      ]);
      final code = await process.exitCode;
      await done;
      sink.writeln('# exit code $code');
      return code;
    } on ProcessException catch (e) {
      throw ConfigException('DKR001 No se pudo ejecutar docker: ${e.message}');
    } finally {
      await sink.close();
    }
  }
}
