import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class DbfField {
  const DbfField(this.name, this.type, this.length, this.decimals);

  final String name;

  /// dBASE type letter (`C`, `N`, `F`, `L`, `D`, ...).
  final String type;
  final int length;
  final int decimals;

  String get description => '$type($length${decimals > 0 ? ',$decimals' : ''})';
}

/// A text value that could not be decoded with the table's encoding.
class DbfEncodingIssue {
  const DbfEncodingIssue(this.record, this.field);

  final int record;
  final String field;
}

/// Minimal dBASE III reader for shapefile attribute tables.
///
/// Values follow OGR's reading of a `.dbf`: text is right-trimmed and an
/// empty text becomes `null`; numbers are `int` when the field has no
/// decimals, else `double`; blank numbers are `null`.
class DbfTable {
  DbfTable._(
    this._bytes,
    this.fields,
    this.recordCount,
    this._headerLength,
    this._recordLength,
    this.encodingName,
    this._strictUtf8,
    this._latin1,
  );

  /// Opens [file]. [encoding] overrides the `.cpg` sidecar (`UTF-8`,
  /// `ISO-8859-1`/`latin1`, `1252`).
  static DbfTable open(File file, {String? encoding}) {
    final bytes = file.readAsBytesSync();
    if (bytes.length < 32) {
      throw FormatException('DBF demasiado corto: ${file.path}');
    }
    final data = ByteData.sublistView(bytes);
    final recordCount = data.getUint32(4, Endian.little);
    final headerLength = data.getUint16(8, Endian.little);
    final recordLength = data.getUint16(10, Endian.little);
    final fields = <DbfField>[];
    for (
      var offset = 32;
      offset + 32 <= headerLength && bytes[offset] != 0x0D;
      offset += 32
    ) {
      final rawName = bytes.sublist(offset, offset + 11);
      final end = rawName.indexOf(0);
      final name = latin1
          .decode(end == -1 ? rawName : rawName.sublist(0, end))
          .trim();
      fields.add(
        DbfField(
          name,
          String.fromCharCode(bytes[offset + 11]),
          bytes[offset + 16],
          bytes[offset + 17],
        ),
      );
    }
    final declared = encoding ?? _cpgEncoding(file);
    final normalized = (declared ?? '').toUpperCase().replaceAll(
      RegExp('[^A-Z0-9]'),
      '',
    );
    final isUtf8 = normalized == 'UTF8';
    final isLatin = const {
      'ISO88591',
      '88591',
      'LATIN1',
      '1252',
      'ANSI1252',
      'CP1252',
      'WINDOWS1252',
    }.contains(normalized);
    if (declared != null && !isUtf8 && !isLatin) {
      throw FormatException(
        'Codificación DBF no soportada: "$declared" (${file.path}).',
      );
    }
    return DbfTable._(
      bytes,
      fields,
      recordCount,
      headerLength,
      recordLength,
      declared ?? 'ISO-8859-1 (sin .cpg)',
      isUtf8,
      !isUtf8,
    );
  }

  static String? _cpgEncoding(File dbf) {
    final base = dbf.path.substring(0, dbf.path.length - 4);
    for (final candidate in ['$base.cpg', '$base.CPG']) {
      final cpg = File(candidate);
      if (cpg.existsSync()) return cpg.readAsStringSync().trim();
    }
    return null;
  }

  final Uint8List _bytes;
  final List<DbfField> fields;
  final int recordCount;
  final int _headerLength;
  final int _recordLength;
  final String encodingName;
  final bool _strictUtf8;
  final bool _latin1;
  final List<DbfEncodingIssue> encodingIssues = [];

  int _deleted = 0;

  /// Records skipped because they are flagged as deleted.
  int get deletedRecords => _deleted;

  /// Every non-deleted record, in file order, as `field -> value`. Records
  /// keep their original index so they stay aligned with the `.shp`.
  Iterable<(int, Map<String, Object?>)> records() sync* {
    _deleted = 0;
    encodingIssues.clear();
    for (var index = 0; index < recordCount; index++) {
      final start = _headerLength + index * _recordLength;
      if (start + _recordLength > _bytes.length) {
        throw FormatException('DBF truncado en el registro $index.');
      }
      if (_bytes[start] == 0x2A) {
        _deleted++;
        continue;
      }
      var offset = start + 1;
      final values = <String, Object?>{};
      for (final field in fields) {
        final raw = Uint8List.sublistView(
          _bytes,
          offset,
          offset + field.length,
        );
        offset += field.length;
        values[field.name] = _value(field, raw, index);
      }
      yield (index, values);
    }
  }

  Object? _value(DbfField field, Uint8List raw, int record) {
    switch (field.type) {
      case 'N':
      case 'F':
        final text = latin1.decode(raw).trim();
        if (text.isEmpty || RegExp(r'^\*+$').hasMatch(text)) return null;
        if (field.decimals == 0 && !text.contains('.')) {
          return int.tryParse(text) ?? double.tryParse(text);
        }
        return double.tryParse(text);
      case 'L':
        final text = latin1.decode(raw).trim().toUpperCase();
        if ('TY'.contains(text) && text.isNotEmpty) return true;
        if ('FN'.contains(text) && text.isNotEmpty) return false;
        return null;
      default:
        var end = raw.length;
        while (end > 0 && (raw[end - 1] == 0x20 || raw[end - 1] == 0x00)) {
          end--;
        }
        if (end == 0) return null;
        final slice = Uint8List.sublistView(raw, 0, end);
        if (_latin1) return latin1.decode(slice);
        if (_strictUtf8) {
          try {
            return const Utf8Decoder().convert(slice);
          } on FormatException {
            encodingIssues.add(DbfEncodingIssue(record, field.name));
            return const Utf8Decoder(allowMalformed: true).convert(slice);
          }
        }
        return latin1.decode(slice);
    }
  }
}
