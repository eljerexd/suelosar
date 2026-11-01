import '../schema/suelosar_schema.dart';

/// One target field of the SuelosAR schema and where its value comes from.
sealed class FieldRule {
  const FieldRule(this.target);

  final String target;
}

/// `TARGET: { from: column, empty: <value> }` — copies the source value;
/// a missing or null source value becomes [emptyValue].
class CopyRule extends FieldRule {
  const CopyRule(super.target, {required this.source, this.emptyValue});

  final String source;
  final Object? emptyValue;
}

/// `TARGET: { absent: "why", value: "" }` — the province has no data for
/// this field. The column is still written (the pipeline requires it) with
/// [value] on every feature, and [reason] is shown in the report.
class AbsentRule extends FieldRule {
  const AbsentRule(super.target, {required this.reason, this.value = ''});

  final String reason;
  final Object? value;
}

/// Derivations that already exist in the project.
enum Derivation {
  /// Name of the dominant series (highest `PORCn`, else first `SERIEn`),
  /// looked up in the province catalog — the rule `remap_santa_fe.mjs`
  /// applied to Santa Fe's `Nombre_UC`.
  dominantSeriesName('dominant_series_name');

  const Derivation(this.key);
  final String key;
}

/// `TARGET: { derive: <derivation>, empty: <value> }`.
class DeriveRule extends FieldRule {
  const DeriveRule(super.target, {required this.derivation, this.emptyValue});

  final Derivation derivation;
  final Object? emptyValue;
}

/// A province's declarative `gis.mapping`, in declaration order.
class FieldMapping {
  const FieldMapping(this.rules);

  /// Parses the YAML `mapping` block. Throws [FormatException] listing
  /// every problem.
  factory FieldMapping.parse(Map<String, Object?> node) {
    final rules = <FieldRule>[];
    final problems = <String>[];
    node.forEach((rawTarget, rawRule) {
      try {
        rules.addAll(_parseEntry(rawTarget, rawRule));
      } on FormatException catch (e) {
        problems.add(e.message);
      }
    });
    final seen = <String>{};
    for (final rule in rules) {
      if (!seen.add(rule.target)) {
        problems.add('${rule.target}: declarado más de una vez.');
      }
    }
    if (problems.isNotEmpty) throw FormatException(problems.join(' | '));
    return FieldMapping(rules);
  }

  final List<FieldRule> rules;

  Iterable<String> get targets => rules.map((rule) => rule.target);

  /// Source columns the mapping reads, with the target that needs each.
  Map<String, String> get sourceColumns => {
    for (final rule in rules.whereType<CopyRule>()) rule.source: rule.target,
  };

  FieldRule? ruleFor(String target) {
    for (final rule in rules) {
      if (rule.target == target) return rule;
    }
    return null;
  }

  bool get usesDerivations => rules.any((rule) => rule is DeriveRule);

  /// Schema fields the mapping does not declare (CFG002).
  List<String> get missingRequiredTargets => [
    for (final field in SuelosArSchema.requiredFields)
      if (ruleFor(field) == null) field,
  ];

  static List<FieldRule> _parseEntry(String rawTarget, Object? rawRule) {
    if (rawRule is String) return _parseEntry(rawTarget, {'from': rawRule});
    if (rawRule is! Map) {
      throw FormatException(
        '$rawTarget: la regla debe ser un texto o un mapa.',
      );
    }
    final rule = rawRule.cast<String, Object?>();
    final kinds = ['from', 'absent', 'derive'].where(rule.containsKey).toList();
    if (kinds.length != 1) {
      throw FormatException(
        '$rawTarget: usar exactamente una de from | absent | derive.',
      );
    }
    final range = rule['n'];
    final isPattern = rawTarget.contains('{n}');
    if (isPattern != (range != null)) {
      throw FormatException(
        '$rawTarget: los patrones usan {n} en el campo y "n: [desde, hasta]".',
      );
    }
    final indices = <int?>[null];
    if (isPattern) {
      if (range is! List ||
          range.length != 2 ||
          range[0] is! int ||
          range[1] is! int ||
          (range[0] as int) < 1 ||
          (range[1] as int) < (range[0] as int)) {
        throw FormatException(
          '$rawTarget: "n" debe ser [desde, hasta] con enteros ≥ 1.',
        );
      }
      indices
        ..clear()
        ..addAll([
          for (var i = range[0] as int; i <= (range[1] as int); i++) i,
        ]);
    }
    final unknown = rule.keys.toSet().difference({
      'from',
      'absent',
      'derive',
      'empty',
      'value',
      'n',
    });
    if (unknown.isNotEmpty) {
      throw FormatException(
        '$rawTarget: claves desconocidas ${unknown.join(', ')}.',
      );
    }

    return [
      for (final n in indices)
        _build(
          n == null ? rawTarget : rawTarget.replaceAll('{n}', '$n'),
          kinds.single,
          rule,
          n,
        ),
    ];
  }

  static FieldRule _build(
    String target,
    String kind,
    Map<String, Object?> rule,
    int? n,
  ) {
    if (!SuelosArSchema.isKnown(target)) {
      throw FormatException(
        '$target: no es un campo del esquema SuelosAR '
        '(${[...SuelosArSchema.requiredFields, ...SuelosArSchema.optionalFields].join(', ')}).',
      );
    }
    switch (kind) {
      case 'from':
        final source = rule['from'];
        if (source is! String || source.isEmpty) {
          throw FormatException(
            '$target: "from" debe ser el nombre de una columna.',
          );
        }
        if (n != null && !source.contains('{n}')) {
          throw FormatException(
            '$target: la columna de un patrón debe usar {n}.',
          );
        }
        return CopyRule(
          target,
          source: n == null ? source : source.replaceAll('{n}', '$n'),
          emptyValue: rule['empty'],
        );
      case 'absent':
        final reason = rule['absent'];
        if (reason is! String || reason.trim().isEmpty) {
          throw FormatException(
            '$target: "absent" requiere el motivo como texto.',
          );
        }
        return AbsentRule(
          target,
          reason: reason,
          value: rule.containsKey('value') ? rule['value'] : '',
        );
      default:
        final name = rule['derive'];
        final derivation = Derivation.values
            .where((d) => d.key == name)
            .firstOrNull;
        if (derivation == null) {
          throw FormatException(
            '$target: derivación desconocida "$name" '
            '(${Derivation.values.map((d) => d.key).join(' | ')}).',
          );
        }
        return DeriveRule(
          target,
          derivation: derivation,
          emptyValue: rule['empty'],
        );
    }
  }
}
