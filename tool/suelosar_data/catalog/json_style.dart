import 'dart:convert';

import '../config/province_definition.dart';

/// Serializes a catalog exactly the way the file the app ships today is
/// laid out, so a regenerated catalog only differs where its data does.
String encodeCatalogJson(Object? value, JsonStyle style) => switch (style) {
  JsonStyle.standard => const JsonEncoder.withIndent('  ').convert(value),
  JsonStyle.powershell => _PowerShellJson().encode(value),
};

/// Windows PowerShell 5.1 `ConvertTo-Json` layout: four-space indent,
/// `"key":  value` (two spaces), and `' < > &` escaped as `\u00XX`.
/// Supports the shape PowerShell itself produces for a list of flat
/// records; nested containers inside a record are rejected rather than
/// guessed at.
class _PowerShellJson {
  String encode(Object? value) {
    if (value is List) {
      if (value.isEmpty) return '[\n\n]';
      final items = [for (final item in value) _record(item, '    ')];
      return '[\n${items.join(',\n')}\n]';
    }
    return _record(value, '');
  }

  String _record(Object? value, String indent) {
    if (value is! Map) {
      throw UnsupportedError(
        'El estilo powershell solo admite registros planos.',
      );
    }
    final inner = '$indent    ';
    final fields = [
      for (final entry in value.entries)
        '$inner${_string(entry.key.toString())}:  ${_scalar(entry.value)}',
    ];
    return '$indent{\n${fields.join(',\n')}\n$indent}';
  }

  String _scalar(Object? value) {
    if (value == null || value is num || value is bool) {
      return jsonEncode(value);
    }
    if (value is String) return _string(value);
    throw UnsupportedError('El estilo powershell solo admite valores simples.');
  }

  String _string(String value) {
    final buffer = StringBuffer('"');
    for (final rune in value.runes) {
      switch (rune) {
        case 0x22:
          buffer.write(r'\"');
        case 0x5C:
          buffer.write(r'\\');
        case 0x0A:
          buffer.write(r'\n');
        case 0x0D:
          buffer.write(r'\r');
        case 0x09:
          buffer.write(r'\t');
        case 0x08:
          buffer.write(r'\b');
        case 0x0C:
          buffer.write(r'\f');
        case 0x27 || 0x3C || 0x3E || 0x26:
          buffer.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        default:
          if (rune < 0x20) {
            buffer.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
          } else {
            buffer.writeCharCode(rune);
          }
      }
    }
    buffer.write('"');
    return buffer.toString();
  }
}
