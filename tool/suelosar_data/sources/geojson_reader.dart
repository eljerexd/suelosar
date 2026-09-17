import 'dart:convert';
import 'dart:io';

/// One GeoJSON feature: decoded properties and the geometry exactly as it
/// appears in the file (never re-serialized).
class GeoJsonFeature {
  const GeoJsonFeature(this.index, this.properties, this.rawGeometry);

  final int index;
  final Map<String, Object?> properties;

  /// Raw JSON text of `geometry`, or null when not requested / absent.
  final String? rawGeometry;
}

/// Reads a FeatureCollection written one feature per line — the layout of
/// GDAL's GeoJSON output and of `remap_santa_fe.mjs`. A line is a feature
/// when it contains `"type":"Feature"` (the same test the Santa Fe script
/// uses), with an optional trailing comma.
///
/// Only `properties` is decoded; `geometry` is sliced out as text, which
/// keeps a 250 MB file fast to scan and the geometry byte-for-byte intact.
Stream<GeoJsonFeature> readGeoJsonLines(
  File file, {
  bool withGeometry = false,
}) async* {
  var index = 0;
  final lines = file
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  await for (final line in lines) {
    if (!line.contains('"type":"Feature"')) continue;
    final text = line.trimRight();
    final objectText = text.endsWith(',')
        ? text.substring(0, text.length - 1)
        : text;
    final members = topLevelMembers(objectText);
    final rawProperties = members['properties'];
    final properties = rawProperties == null || rawProperties == 'null'
        ? <String, Object?>{}
        : (jsonDecode(rawProperties) as Map).cast<String, Object?>();
    final rawGeometry = members['geometry'];
    yield GeoJsonFeature(
      index++,
      properties,
      withGeometry && rawGeometry != 'null' ? rawGeometry : null,
    );
  }
}

/// Reads a regular (not line-delimited) GeoJSON FeatureCollection by
/// decoding the whole file. Meant for small sources.
Stream<GeoJsonFeature> readGeoJsonDocument(
  File file, {
  bool withGeometry = false,
}) async* {
  final document = jsonDecode(await file.readAsString());
  if (document is! Map || document['type'] != 'FeatureCollection') {
    throw FormatException('No es un FeatureCollection GeoJSON: ${file.path}');
  }
  var index = 0;
  for (final feature in document['features'] as List) {
    final map = feature as Map;
    final geometry = map['geometry'];
    yield GeoJsonFeature(
      index++,
      ((map['properties'] as Map?) ?? {}).cast<String, Object?>(),
      withGeometry && geometry != null ? jsonEncode(geometry) : null,
    );
  }
}

/// Splits a JSON object's text into `key -> raw value text` for its
/// top-level members, without decoding the values.
Map<String, String> topLevelMembers(String objectText) {
  final members = <String, String>{};
  var i = objectText.indexOf('{');
  if (i < 0) {
    throw FormatException(
      'Se esperaba un objeto JSON: ${_preview(objectText)}',
    );
  }
  i++;
  final length = objectText.length;

  int skipWhitespace(int at) {
    while (at < length) {
      final c = objectText.codeUnitAt(at);
      if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) break;
      at++;
    }
    return at;
  }

  int endOfString(int at) {
    // [at] is the opening quote.
    at++;
    while (at < length) {
      final c = objectText.codeUnitAt(at);
      if (c == 0x5C) {
        at += 2;
        continue;
      }
      if (c == 0x22) return at + 1;
      at++;
    }
    throw FormatException('Texto JSON sin cerrar: ${_preview(objectText)}');
  }

  while (true) {
    i = skipWhitespace(i);
    if (i >= length) {
      throw FormatException('Objeto JSON sin cerrar: ${_preview(objectText)}');
    }
    if (objectText.codeUnitAt(i) == 0x7D) break; // }
    if (objectText.codeUnitAt(i) != 0x22) {
      throw FormatException('Clave JSON inválida: ${_preview(objectText)}');
    }
    final keyEnd = endOfString(i);
    final key = jsonDecode(objectText.substring(i, keyEnd)) as String;
    i = skipWhitespace(keyEnd);
    if (i >= length || objectText.codeUnitAt(i) != 0x3A) {
      throw FormatException('Falta ":" en JSON: ${_preview(objectText)}');
    }
    i = skipWhitespace(i + 1);
    final valueStart = i;
    var depth = 0;
    while (i < length) {
      final c = objectText.codeUnitAt(i);
      if (c == 0x22) {
        i = endOfString(i);
        continue;
      }
      if (c == 0x7B || c == 0x5B) depth++;
      if (c == 0x7D || c == 0x5D) {
        if (depth == 0) break;
        depth--;
      }
      if (c == 0x2C && depth == 0) break;
      i++;
    }
    members[key] = objectText.substring(valueStart, i).trimRight();
    if (i < length && objectText.codeUnitAt(i) == 0x2C) i++;
  }
  return members;
}

String _preview(String text) =>
    text.length <= 80 ? text : '${text.substring(0, 80)}…';
