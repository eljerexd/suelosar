import 'dart:collection';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final options = _GeneratorOptions.fromArguments(arguments);
  final generator = SoilMetadataGenerator(
    inputDirectory: Directory(options.inputDirectory),
    outputFile: File(options.outputFile),
    textExtractor: PdftotextExtractor(executable: options.pdftotextExecutable),
  );

  final result = await generator.generate();
  stdout.writeln(
    'Generated ${result.entryCount} soil metadata entries at '
    '${options.outputFile}.',
  );
  if (result.skippedFiles.isNotEmpty) {
    stderr.writeln('Skipped ${result.skippedFiles.length} PDF files:');
    for (final skippedFile in result.skippedFiles) {
      stderr.writeln('  - $skippedFile');
    }
  }
}

class SoilMetadataGenerator {
  const SoilMetadataGenerator({
    required this.inputDirectory,
    required this.outputFile,
    required this.textExtractor,
  });

  final Directory inputDirectory;
  final File outputFile;
  final PdfTextExtractor textExtractor;

  Future<SoilMetadataGenerationResult> generate() async {
    if (!inputDirectory.existsSync()) {
      throw StateError('Input directory not found: ${inputDirectory.path}');
    }

    final entries = <String, Map<String, String>>{};
    final skippedFiles = <String>[];
    final pdfFiles =
        inputDirectory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.pdf'))
            .toList()
          ..sort((first, second) => first.path.compareTo(second.path));

    final parser = SoilReportMetadataParser();
    for (final pdfFile in pdfFiles) {
      final text = await textExtractor.extractText(pdfFile);
      final metadata = parser.parse(text, fallbackSeriesName: pdfFile);
      if (metadata == null) {
        skippedFiles.add(pdfFile.path);
        continue;
      }
      entries[metadata.seriesName] = metadata.toJson();
    }

    final sortedEntries = SplayTreeMap<String, Map<String, String>>.from(
      entries,
      (first, second) => first.toLowerCase().compareTo(second.toLowerCase()),
    );
    outputFile.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    outputFile.writeAsStringSync('${encoder.convert(sortedEntries)}\n');

    return SoilMetadataGenerationResult(
      entryCount: sortedEntries.length,
      skippedFiles: List<String>.unmodifiable(skippedFiles),
    );
  }
}

class SoilReportMetadataParser {
  const SoilReportMetadataParser();

  SoilReportMetadata? parse(String text, {required File fallbackSeriesName}) {
    final normalizedText = _normalizeText(text);
    final seriesName = _extractSeriesName(normalizedText, fallbackSeriesName);
    final taxonomy = _extractTaxonomy(normalizedText);
    if (seriesName == null || taxonomy == null) {
      return null;
    }
    return SoilReportMetadata(seriesName: seriesName, taxonomy: taxonomy);
  }

  String? _extractSeriesName(String text, File fallbackFile) {
    for (final pattern in _seriesNamePatterns) {
      final match = pattern.firstMatch(text);
      final value = _cleanCapturedValue(match?.namedGroup('value'));
      if (value != null) {
        return value;
      }
    }

    final fileName = fallbackFile.uri.pathSegments.last;
    final withoutExtension = fileName.replaceFirst(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    final value = withoutExtension.replaceAll('_', ' ').trim();
    return value.isEmpty ? null : value;
  }

  String? _extractTaxonomy(String text) {
    for (final pattern in _taxonomyPatterns) {
      final match = pattern.firstMatch(text);
      final value = _cleanCapturedValue(match?.namedGroup('value'));
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  static String _normalizeText(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp('[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }

  static String? _cleanCapturedValue(String? value) {
    final cleanValue = value
        ?.replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[.;,:\s]+$'), '')
        .trim();
    if (cleanValue == null || cleanValue.isEmpty) {
      return null;
    }
    return cleanValue;
  }

  static final List<RegExp> _seriesNamePatterns = [
    RegExp(
      r'\bSerie\s+(?<value>[A-ZÁÉÍÓÚÜÑ][^\n:]{2,80})',
      caseSensitive: false,
      unicode: true,
    ),
    RegExp(
      r'\bSeries?\s+de\s+suelos?\s*[:\-]\s*(?<value>[^\n]{2,80})',
      caseSensitive: false,
      unicode: true,
    ),
  ];

  static final List<RegExp> _taxonomyPatterns = [
    RegExp(
      r'\bTaxonom(?:ía|ia)\s*[:\-]\s*(?<value>[^\n]{3,120})',
      caseSensitive: false,
      unicode: true,
    ),
    RegExp(
      r'\bClasificaci(?:ón|on)\s+taxon(?:ómica|omica)\s*[:\-]\s*(?<value>[^\n]{3,120})',
      caseSensitive: false,
      unicode: true,
    ),
    RegExp(
      r'\bSubgrupo\s*[:\-]\s*(?<value>[^\n]{3,120})',
      caseSensitive: false,
      unicode: true,
    ),
  ];
}

class SoilReportMetadata {
  const SoilReportMetadata({required this.seriesName, required this.taxonomy});

  final String seriesName;
  final String taxonomy;

  Map<String, String> toJson() {
    return {'taxonomy': taxonomy};
  }
}

class SoilMetadataGenerationResult {
  const SoilMetadataGenerationResult({
    required this.entryCount,
    required this.skippedFiles,
  });

  final int entryCount;
  final List<String> skippedFiles;
}

abstract interface class PdfTextExtractor {
  Future<String> extractText(File pdfFile);
}

class PdftotextExtractor implements PdfTextExtractor {
  const PdftotextExtractor({required this.executable});

  final String executable;

  @override
  Future<String> extractText(File pdfFile) async {
    final result = await Process.run(executable, [
      '-layout',
      '-enc',
      'UTF-8',
      pdfFile.path,
      '-',
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to extract text from ${pdfFile.path}: ${result.stderr}',
      );
    }
    return result.stdout.toString();
  }
}

class _GeneratorOptions {
  const _GeneratorOptions({
    required this.inputDirectory,
    required this.outputFile,
    required this.pdftotextExecutable,
  });

  factory _GeneratorOptions.fromArguments(List<String> arguments) {
    var inputDirectory = 'assets/pdfs';
    var outputFile = 'assets/data/soil_metadata.json';
    var pdftotextExecutable = 'pdftotext';

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '--input':
          inputDirectory = _readOptionValue(arguments, ++index, argument);
        case '--output':
          outputFile = _readOptionValue(arguments, ++index, argument);
        case '--pdftotext':
          pdftotextExecutable = _readOptionValue(arguments, ++index, argument);
        case '--help':
        case '-h':
          _printUsage();
          exit(0);
        default:
          throw ArgumentError('Unknown option: $argument');
      }
    }

    return _GeneratorOptions(
      inputDirectory: inputDirectory,
      outputFile: outputFile,
      pdftotextExecutable: pdftotextExecutable,
    );
  }

  final String inputDirectory;
  final String outputFile;
  final String pdftotextExecutable;

  static String _readOptionValue(
    List<String> arguments,
    int index,
    String option,
  ) {
    if (index >= arguments.length) {
      throw ArgumentError('Missing value for $option');
    }
    return arguments[index];
  }

  static void _printUsage() {
    stdout.writeln('Generate soil metadata JSON from descriptive report PDFs.');
    stdout.writeln('');
    stdout.writeln('Usage:');
    stdout.writeln(
      '  dart run tool/generate_soil_metadata.dart '
      '[--input assets/pdfs] '
      '[--output assets/data/soil_metadata.json] '
      '[--pdftotext pdftotext]',
    );
  }
}
