/// Severity of a pipeline [Finding]. Only [error] makes a run fail.
enum Severity {
  error('ERROR', '✗'),
  warning('WARNING', '⚠'),
  info('INFO', 'ℹ');

  const Severity(this.label, this.symbol);

  final String label;
  final String symbol;

  static Severity parse(String label) =>
      values.firstWhere((severity) => severity.label == label);
}

/// One validation result: a stable [code] (see `tool/suelosar_data/README.md`),
/// a human message, and — when known — where it happened.
class Finding {
  const Finding({
    required this.code,
    required this.severity,
    required this.message,
    this.location,
    this.examples = const [],
    this.count,
  });

  factory Finding.fromJson(Map<String, dynamic> json) => Finding(
    code: json['code'] as String,
    severity: Severity.parse(json['severity'] as String),
    message: json['message'] as String,
    location: json['location'] as String?,
    examples: [for (final e in json['examples'] as List? ?? []) e as String],
    count: json['count'] as int?,
  );

  /// How many examples a finding keeps; the rest are only counted.
  static const maxExamples = 12;

  final String code;
  final Severity severity;
  final String message;

  /// File, record, field or page the finding refers to.
  final String? location;

  /// Up to [maxExamples] affected items.
  final List<String> examples;

  /// Total affected items, when that differs from [examples].
  final int? count;

  Map<String, dynamic> toJson() => {
    'code': code,
    'severity': severity.label,
    'message': message,
    if (location != null) 'location': location,
    if (examples.isNotEmpty) 'examples': examples,
    if (count != null) 'count': count,
  };

  @override
  String toString() =>
      '${severity.label} $code: $message'
      '${location == null ? '' : ' [$location]'}';
}

/// Collects findings for one stage.
class FindingSink {
  final List<Finding> findings = [];

  void add(
    Severity severity,
    String code,
    String message, {
    String? location,
    Iterable<String> examples = const [],
    int? count,
  }) {
    findings.add(
      Finding(
        code: code,
        severity: severity,
        message: message,
        location: location,
        examples: examples.take(Finding.maxExamples).toList(),
        count: count,
      ),
    );
  }

  void error(
    String code,
    String message, {
    String? location,
    Iterable<String> examples = const [],
    int? count,
  }) => add(
    Severity.error,
    code,
    message,
    location: location,
    examples: examples,
    count: count,
  );

  void warning(
    String code,
    String message, {
    String? location,
    Iterable<String> examples = const [],
    int? count,
  }) => add(
    Severity.warning,
    code,
    message,
    location: location,
    examples: examples,
    count: count,
  );

  void info(
    String code,
    String message, {
    String? location,
    Iterable<String> examples = const [],
    int? count,
  }) => add(
    Severity.info,
    code,
    message,
    location: location,
    examples: examples,
    count: count,
  );
}

int countBySeverity(Iterable<Finding> findings, Severity severity) =>
    findings.where((finding) => finding.severity == severity).length;
