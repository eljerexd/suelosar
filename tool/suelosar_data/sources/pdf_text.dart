import 'dart:io';

import '../../generate_soil_metadata.dart' show PdftotextExtractor;
import '../config/paths.dart';

/// Page-by-page PDF text, via poppler's `pdftotext` (the same extractor
/// `tool/generate_soil_metadata.dart` uses).
class PdfText {
  PdfText._(this.pages);

  /// Text already split into pages (tests, cached extractions).
  factory PdfText.fromPages(List<String> pages) => PdfText._(List.of(pages));

  /// Physical pages, index 0 = page 1.
  final List<String> pages;

  int get pageCount => pages.length;

  /// Text of physical page [number] (1-based).
  String page(int number) => pages[number - 1];

  static Future<PdfText> extract(File pdf, {required String executable}) async {
    final text = await PdftotextExtractor(
      executable: executable,
    ).extractText(pdf);
    final pages = text.split('\f');
    // pdftotext ends every page, including the last, with a form feed.
    if (pages.isNotEmpty && pages.last.trim().isEmpty) pages.removeLast();
    return PdfText._(pages);
  }
}

const _gitForWindowsPdftotext =
    r'C:\Program Files\Git\mingw64\bin\pdftotext.exe';

/// Finds a runnable `pdftotext`: [explicit] (`--pdftotext`), the
/// `PDFTOTEXT` environment variable, `pdftotext` on PATH, or the copy that
/// ships with Git for Windows.
Future<String> resolvePdftotext({String? explicit}) async {
  final candidates = [
    ?explicit,
    ?Platform.environment['PDFTOTEXT'],
    'pdftotext',
    if (Platform.isWindows) _gitForWindowsPdftotext,
  ];
  for (final candidate in candidates) {
    try {
      await Process.run(candidate, ['-v']);
      return candidate;
    } on ProcessException {
      continue;
    }
  }
  throw ConfigException(
    'No se encontró pdftotext (poppler). Instalalo, agregalo al PATH o '
    'indicá la ruta con --pdftotext / PDFTOTEXT.',
  );
}
