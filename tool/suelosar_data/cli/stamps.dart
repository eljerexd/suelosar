import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../validation/finding.dart';

/// What a resumable stage consumed and produced the last time it succeeded,
/// stored in `work/stamps/<stage>.json`.
class StageStamp {
  const StageStamp({
    required this.stage,
    required this.fingerprint,
    required this.outputs,
    required this.data,
    required this.findings,
    required this.extra,
    required this.durationMs,
    required this.createdAt,
  });

  factory StageStamp.fromJson(Map<String, Object?> json) => StageStamp(
    stage: json['stage']! as String,
    fingerprint: (json['fingerprint']! as Map).cast(),
    outputs: (json['outputs']! as Map).cast(),
    data: (json['data']! as Map).cast(),
    findings: [
      for (final f in json['findings']! as List)
        Finding.fromJson((f as Map).cast()),
    ],
    extra: (json['extra']! as Map).cast(),
    durationMs: json['durationMs']! as int,
    createdAt: DateTime.parse(json['createdAt']! as String),
  );

  final String stage;

  /// Hashes of the inputs, the relevant configuration and tool versions.
  final Map<String, Object?> fingerprint;

  /// Output path -> SHA-256 at the time the stage finished.
  final Map<String, String> outputs;

  /// The stage's report data and findings, replayed when it is reused.
  final Map<String, Object?> data;
  final List<Finding> findings;

  /// Whatever later stages need from this one (e.g. catalog keys).
  final Map<String, Object?> extra;
  final int durationMs;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'stage': stage,
    'createdAt': createdAt.toIso8601String(),
    'durationMs': durationMs,
    'fingerprint': fingerprint,
    'outputs': outputs,
    'data': data,
    'findings': [for (final f in findings) f.toJson()],
    'extra': extra,
  };
}

/// Hashes files once per run (keyed by path, size and modification time).
class FileHasher {
  final Map<String, String> _memo = {};

  Future<String> sha256(File file) async {
    final stat = file.statSync();
    final key =
        '${p.normalize(file.absolute.path)}|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    final cached = _memo[key];
    if (cached != null) return cached;
    final digest = (await crypto.sha256.bind(file.openRead()).first).toString();
    return _memo[key] = digest;
  }

  /// SHA-256 of [file], or `null` when it does not exist.
  Future<String?> sha256OrNull(File file) async =>
      file.existsSync() ? sha256(file) : null;
}

/// SHA-256 of a JSON-encodable value (configuration sections, key lists).
String hashJson(Object? value) =>
    crypto.sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// Reads and writes stage stamps. A stamp is only reused when its
/// fingerprint matches exactly, every recorded output still exists with the
/// same hash, and it did not record errors; anything else means "run again".
class StampStore {
  StampStore(this.directory, this.hasher);

  final String directory;
  final FileHasher hasher;

  File _file(String stage) => File(p.join(directory, '$stage.json'));

  StageStamp? load(String stage) {
    final file = _file(stage);
    if (!file.existsSync()) return null;
    try {
      return StageStamp.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast(),
      );
    } on Object {
      return null; // Unreadable stamp: treat as absent.
    }
  }

  void save(StageStamp stamp) {
    final file = _file(stamp.stage);
    file.parent.createSync(recursive: true);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(stamp.toJson()),
    );
    if (file.existsSync()) file.deleteSync();
    temp.renameSync(file.path);
  }

  void delete(String stage) {
    final file = _file(stage);
    if (file.existsSync()) file.deleteSync();
  }

  /// Why [stamp] cannot be reused for [fingerprint], or null when it can.
  Future<String?> rejectReason(
    StageStamp? stamp,
    Map<String, Object?> fingerprint,
  ) async {
    if (stamp == null) return 'sin huella previa';
    if (stamp.findings.any((f) => f.severity == Severity.error)) {
      return 'la corrida anterior tuvo errores';
    }
    if (jsonEncode(stamp.fingerprint) != jsonEncode(fingerprint)) {
      final changed = <String>[
        for (final key in {...stamp.fingerprint.keys, ...fingerprint.keys})
          if (jsonEncode(stamp.fingerprint[key]) !=
              jsonEncode(fingerprint[key]))
            key,
      ];
      return 'cambió: ${changed.join(', ')}';
    }
    for (final entry in stamp.outputs.entries) {
      final file = File(entry.key);
      if (!file.existsSync()) return 'falta la salida ${p.basename(entry.key)}';
      if (await hasher.sha256(file) != entry.value) {
        return 'la salida ${p.basename(entry.key)} fue modificada';
      }
    }
    return null;
  }
}
