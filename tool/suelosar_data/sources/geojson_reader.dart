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
    if (members['type'] == '"FeatureCollection"') {
      // A whole collection on one line (e.g. a WFS export): reading it
      // as one feature would silently lose every feature.
      throw FormatException(
        'El archivo no tiene un feature por línea (la línea ${index + 1} es '
        'un FeatureCollection completo); usar gis.format: geojson. '
        '${file.path}',
      );
    }
    yield _feature(index++, members, withGeometry);
  }
}

GeoJsonFeature _feature(
  int index,
  Map<String, String> members,
  bool withGeometry,
) {
  final rawProperties = members['properties'];
  final properties = rawProperties == null || rawProperties == 'null'
      ? <String, Object?>{}
      : (jsonDecode(rawProperties) as Map).cast<String, Object?>();
  final rawGeometry = members['geometry'];
  return GeoJsonFeature(
    index,
    properties,
    withGeometry && rawGeometry != null && rawGeometry != 'null'
        ? rawGeometry
        : null,
  );
}

/// Reads a regular GeoJSON FeatureCollection, whatever its layout (pretty
/// printed, or the whole document on one line as WFS services write it).
///
/// The file is scanned as a character stream: only the text of the
/// feature being read is buffered, so memory is bounded by the largest
/// single feature, not by the file. Each feature then goes through the
/// same path as [readGeoJsonLines]: `properties` is decoded and `geometry`
/// is kept as the exact source text.
Stream<GeoJsonFeature> readGeoJsonDocument(
  File file, {
  bool withGeometry = false,
}) async* {
  final scanner = FeatureCollectionScanner();
  var index = 0;
  final chunks = file.openRead().transform(
    const Utf8Decoder(allowMalformed: true),
  );
  await for (final chunk in chunks) {
    final List<String> finished;
    try {
      finished = scanner.add(chunk);
    } on FormatException catch (e) {
      throw FormatException('${e.message} ${file.path}');
    }
    for (final featureText in finished) {
      yield _checkedFeature(file, index++, featureText, withGeometry);
    }
  }
  scanner.close(file.path);
}

GeoJsonFeature _checkedFeature(
  File file,
  int index,
  String featureText,
  bool withGeometry,
) {
  final members = topLevelMembers(featureText);
  if (members['type'] != '"Feature"') {
    throw FormatException(
      'El elemento ${index + 1} de "features" no es un Feature '
      '(type: ${members['type']}): ${file.path}',
    );
  }
  return _feature(index, members, withGeometry);
}

/// Incremental scanner for a FeatureCollection document. Feed it decoded
/// text chunks with [add]; it returns the complete text of every element
/// of the top-level `features` array finished in that chunk. Strings are
/// tracked (with escapes) across chunk boundaries, so braces inside
/// values never confuse it.
class FeatureCollectionScanner {
  // Nesting depth: 0 outside the document, 1 inside the root object.
  int _depth = 0;
  bool _inString = false;
  bool _escaped = false;
  bool _started = false;
  bool _finished = false;

  // Root member bookkeeping (depth 1 only).
  final StringBuffer _key = StringBuffer();
  bool _capturingKey = false;
  String? _lastKey;
  bool _expectValue = false;
  String? _type;
  final StringBuffer _typeValue = StringBuffer();
  bool _capturingType = false;

  // `features` array state.
  bool _sawFeatures = false;
  int? _featuresDepth; // depth inside the array
  final StringBuffer _feature = StringBuffer();
  int _featureDepth = -1; // depth at which the current element started
  int _features = 0;

  List<String> add(String chunk) {
    final out = <String>[];
    var captureFrom = _featureDepth >= 0 ? 0 : -1;
    final length = chunk.length;
    for (var i = 0; i < length; i++) {
      final c = chunk.codeUnitAt(i);
      if (_inString) {
        if (_escaped) {
          _escaped = false;
        } else if (c == 0x5C) {
          _escaped = true;
        } else if (c == 0x22) {
          _inString = false;
          if (_capturingKey) {
            _capturingKey = false;
            _lastKey = _key.toString();
          } else if (_capturingType) {
            _capturingType = false;
            _type = _typeValue.toString();
          }
        }
        if (_inString) {
          if (_capturingKey) _key.writeCharCode(c);
          if (_capturingType) _typeValue.writeCharCode(c);
        }
        continue;
      }
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) continue;
      if (_finished) {
        throw const FormatException('Contenido después del cierre del JSON.');
      }
      if (!_started) {
        if (c == 0xFEFF) continue; // UTF-8 byte order mark
        if (c != 0x7B) {
          throw const FormatException(
            'No es un FeatureCollection GeoJSON: el documento no es un objeto.',
          );
        }
        _started = true;
        _depth = 1;
        continue;
      }

      final inFeaturesArray =
          _featuresDepth != null && _depth == _featuresDepth;
      if (inFeaturesArray && _featureDepth < 0) {
        // Between elements of `features`.
        if (c == 0x2C) continue;
        if (c == 0x5D) {
          _featuresDepth = null;
          _depth--;
          continue;
        }
        if (c != 0x7B) {
          throw FormatException(
            'El elemento ${_features + 1} de "features" no es un objeto.',
          );
        }
        _featureDepth = _depth;
        captureFrom = i;
      }

      if (_depth == 1) {
        // Root object: keys, ':' and the start of each value.
        if (_expectValue) {
          _expectValue = false;

          if (_lastKey == 'features' && c == 0x5B) {
            _sawFeatures = true;
            _depth++;
            _featuresDepth = _depth;
            continue;
          }
          if (_lastKey == 'type' && c == 0x22) {
            _inString = true;
            _capturingType = true;
            _typeValue.clear();
            continue;
          }
        } else if (c == 0x22) {
          _inString = true;
          _capturingKey = true;
          _key.clear();
          continue;
        } else if (c == 0x3A) {
          _expectValue = true;
          continue;
        }
      }

      switch (c) {
        case 0x22:
          _inString = true;
        case 0x7B || 0x5B:
          _depth++;
        case 0x7D || 0x5D:
          _depth--;
          if (_featureDepth >= 0 && _depth == _featureDepth) {
            _feature.write(chunk.substring(captureFrom, i + 1));
            out.add(_feature.toString());
            _feature.clear();
            _featureDepth = -1;
            captureFrom = -1;
            _features++;
          } else if (_depth == 0) {
            _finished = true;
          }
      }
    }
    if (_featureDepth >= 0 && captureFrom >= 0) {
      _feature.write(chunk.substring(captureFrom));
    }
    return out;
  }

  /// Checks the document ended as a complete FeatureCollection.
  void close(String location) {
    if (!_finished || _inString) {
      throw FormatException('GeoJSON incompleto o sin cerrar: $location');
    }
    if (_type != 'FeatureCollection') {
      throw FormatException(
        'No es un FeatureCollection GeoJSON (type: ${_type ?? 'ausente'}): '
        '$location',
      );
    }
    if (!_sawFeatures) {
      throw FormatException(
        'El FeatureCollection no tiene un arreglo "features": $location',
      );
    }
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
