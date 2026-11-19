import 'dart:convert';
import 'dart:typed_data';

/// Performs bounded structural validation of a ZIP before a ZIP decoder sees
/// the archive. The updater only accepts the simple, non-Zip64 archives made
/// by its distribution builder.
class WindowsDifferentialZipPreflight {
  const WindowsDifferentialZipPreflight._();

  static const int maximumArchiveBytes = 512 * 1024 * 1024;
  static const int maximumExpandedBytes = 512 * 1024 * 1024;
  static const int maximumEntryBytes = 256 * 1024 * 1024;
  static const int maximumEntries = 1024;
  static const int maximumPathBytes = 240;
  static const int maximumCompressionRatio = 100;

  static List<WindowsZipEntryInfo> inspect(
    List<int> bytes, {
    required Map<String, int> expectedFiles,
  }) {
    if (bytes.length < 22 || bytes.length > maximumArchiveBytes) {
      throw const FormatException('El tamaño del ZIP está fuera de límite.');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final eocd = _findEndOfCentralDirectory(data);
    final diskNumber = _u16(data, eocd + 4);
    final centralDisk = _u16(data, eocd + 6);
    final diskEntries = _u16(data, eocd + 8);
    final entryCount = _u16(data, eocd + 10);
    final centralSize = _u32(data, eocd + 12);
    final centralOffset = _u32(data, eocd + 16);
    final commentLength = _u16(data, eocd + 20);

    if (diskNumber != 0 ||
        centralDisk != 0 ||
        diskEntries != entryCount ||
        entryCount == 0 ||
        entryCount > maximumEntries ||
        commentLength != 0 ||
        centralOffset + centralSize != eocd) {
      throw const FormatException(
        'El directorio central del ZIP es inválido o no está soportado.',
      );
    }
    if (expectedFiles.length != entryCount) {
      throw const FormatException(
        'La cantidad de entradas del ZIP no coincide con el inventario.',
      );
    }

    final expectedByKey = <String, MapEntry<String, int>>{};
    for (final item in expectedFiles.entries) {
      final key = _normalizedKey(item.key);
      if (key == null || expectedByKey.containsKey(key) || item.value < 0) {
        throw const FormatException(
          'El inventario esperado contiene rutas inválidas.',
        );
      }
      expectedByKey[key] = item;
    }

    final entries = <WindowsZipEntryInfo>[];
    final seenPaths = <String>{};
    final localRanges = <(int, int)>[];
    var totalExpanded = 0;
    var offset = centralOffset;
    for (var index = 0; index < entryCount; index++) {
      _requireRange(data, offset, 46, centralOffset + centralSize);
      if (_u32(data, offset) != 0x02014b50) {
        throw const FormatException(
          'Registro del directorio central inválido.',
        );
      }

      final versionMadeBy = _u16(data, offset + 4);
      final flags = _u16(data, offset + 8);
      final method = _u16(data, offset + 10);
      final crc = _u32(data, offset + 16);
      final compressedSize = _u32(data, offset + 20);
      final expandedSize = _u32(data, offset + 24);
      final nameLength = _u16(data, offset + 28);
      final extraLength = _u16(data, offset + 30);
      final entryCommentLength = _u16(data, offset + 32);
      final diskStart = _u16(data, offset + 34);
      final externalAttributes = _u32(data, offset + 38);
      final localOffset = _u32(data, offset + 42);
      final recordLength = 46 + nameLength + extraLength + entryCommentLength;
      _requireRange(data, offset, recordLength, centralOffset + centralSize);

      final nameBytes = Uint8List.sublistView(
        data,
        offset + 46,
        offset + 46 + nameLength,
      );
      final path = _decodeSafePath(nameBytes);
      final key = _normalizedKey(path);
      if (key == null || !seenPaths.add(key)) {
        throw const FormatException(
          'El ZIP contiene una ruta inválida o duplicada.',
        );
      }
      final expected = expectedByKey[key];
      if (expected == null ||
          expected.key != path ||
          expected.value != expandedSize) {
        throw const FormatException(
          'Una entrada del ZIP no coincide con el inventario esperado.',
        );
      }

      final supportedFlags = 0x0006 | 0x0008 | 0x0800;
      if (diskStart != 0 ||
          (flags & ~supportedFlags) != 0 ||
          method != 0 && method != 8 ||
          expandedSize > maximumEntryBytes ||
          compressedSize > maximumArchiveBytes ||
          (expandedSize > 0 && compressedSize == 0) ||
          (expandedSize > compressedSize * maximumCompressionRatio) ||
          (method == 0 && expandedSize != compressedSize)) {
        throw const FormatException(
          'El ZIP contiene una entrada cifrada, demasiado grande o comprimida fuera de límite.',
        );
      }
      totalExpanded += expandedSize;
      if (totalExpanded > maximumExpandedBytes) {
        throw const FormatException(
          'El tamaño expandido total del ZIP excede el límite.',
        );
      }

      _validateFileAttributes(versionMadeBy, externalAttributes);
      _validateExtraFields(data, offset + 46 + nameLength, extraLength);
      final dataStart = _validateLocalHeader(
        data,
        localOffset: localOffset,
        centralOffset: centralOffset,
        expectedName: nameBytes,
        flags: flags,
        method: method,
        crc: crc,
        compressedSize: compressedSize,
        expandedSize: expandedSize,
      );
      final dataEnd = dataStart + compressedSize;
      if (dataEnd > centralOffset) {
        throw const FormatException(
          'Los datos de una entrada se solapan con el directorio central.',
        );
      }
      localRanges.add((localOffset, dataEnd));
      entries.add(
        WindowsZipEntryInfo(
          path: path,
          compressedSize: compressedSize,
          expandedSize: expandedSize,
          crc32: crc,
          compressionMethod: method,
        ),
      );
      offset += recordLength;
    }
    if (offset != centralOffset + centralSize ||
        seenPaths.length != expectedByKey.length) {
      throw const FormatException(
        'El directorio central no coincide con sus entradas.',
      );
    }
    localRanges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < localRanges.length; i++) {
      if (localRanges[i].$1 < localRanges[i - 1].$2) {
        throw const FormatException('Las entradas ZIP se superponen.');
      }
    }
    return List.unmodifiable(entries);
  }

  static int _findEndOfCentralDirectory(ByteData data) {
    final earliest = (data.lengthInBytes - 22 - 65535).clamp(
      0,
      data.lengthInBytes,
    );
    for (var offset = data.lengthInBytes - 22; offset >= earliest; offset--) {
      if (_u32(data, offset) == 0x06054b50) {
        final commentLength = _u16(data, offset + 20);
        if (offset + 22 + commentLength == data.lengthInBytes) return offset;
      }
    }
    throw const FormatException('No se encontró un final ZIP válido.');
  }

  static String _decodeSafePath(Uint8List nameBytes) {
    if (nameBytes.isEmpty ||
        nameBytes.length > maximumPathBytes ||
        nameBytes.any((byte) => byte < 0x20 || byte > 0x7e)) {
      throw const FormatException(
        'El ZIP contiene un nombre no ASCII o demasiado largo.',
      );
    }
    final path = ascii.decode(nameBytes, allowInvalid: false);
    if (_normalizedKey(path) == null) {
      throw const FormatException('El ZIP contiene una ruta no permitida.');
    }
    return path;
  }

  static String? _normalizedKey(String path) {
    if (path.isEmpty ||
        path.length > maximumPathBytes ||
        path.startsWith('/') ||
        path.startsWith('\\') ||
        path.contains('\\') ||
        path.contains(':') ||
        RegExp(r'[\x00-\x1f<>"|?*]').hasMatch(path)) {
      return null;
    }
    final components = path.split('/');
    for (final component in components) {
      if (component.isEmpty ||
          component == '.' ||
          component == '..' ||
          component.endsWith('.') ||
          component.endsWith(' ') ||
          RegExp(
            r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$',
            caseSensitive: false,
          ).hasMatch(component)) {
        return null;
      }
    }
    return path.toLowerCase();
  }

  static void _validateFileAttributes(int versionMadeBy, int attributes) {
    final operatingSystem = versionMadeBy >> 8;
    if (operatingSystem == 3) {
      final mode = (attributes >> 16) & 0xffff;
      if ((mode & 0xf000) != 0x8000) {
        throw const FormatException(
          'El ZIP contiene un enlace o archivo especial.',
        );
      }
    } else if ((attributes & 0x10) != 0) {
      throw const FormatException('El ZIP contiene una entrada de directorio.');
    }
  }

  static void _validateExtraFields(ByteData data, int offset, int length) {
    final end = offset + length;
    _requireRange(data, offset, length, data.lengthInBytes);
    while (offset < end) {
      if (end - offset < 4) {
        throw const FormatException('Un campo extra del ZIP está truncado.');
      }
      final id = _u16(data, offset);
      final size = _u16(data, offset + 2);
      if (offset + 4 + size > end || id == 0x0001 || id == 0x7075) {
        throw const FormatException(
          'El ZIP contiene metadatos extra no admitidos.',
        );
      }
      offset += 4 + size;
    }
  }

  static int _validateLocalHeader(
    ByteData data, {
    required int localOffset,
    required int centralOffset,
    required Uint8List expectedName,
    required int flags,
    required int method,
    required int crc,
    required int compressedSize,
    required int expandedSize,
  }) {
    _requireRange(data, localOffset, 30, centralOffset);
    if (_u32(data, localOffset) != 0x04034b50) {
      throw const FormatException('El encabezado local ZIP es inválido.');
    }
    final localFlags = _u16(data, localOffset + 6);
    final localMethod = _u16(data, localOffset + 8);
    final localCrc = _u32(data, localOffset + 14);
    final localCompressed = _u32(data, localOffset + 18);
    final localExpanded = _u32(data, localOffset + 22);
    final nameLength = _u16(data, localOffset + 26);
    final extraLength = _u16(data, localOffset + 28);
    final headerLength = 30 + nameLength + extraLength;
    _requireRange(data, localOffset, headerLength, centralOffset);
    final localName = Uint8List.sublistView(
      data,
      localOffset + 30,
      localOffset + 30 + nameLength,
    );
    if (localFlags != flags ||
        localMethod != method ||
        localName.length != expectedName.length ||
        !localName.asMap().entries.every(
          (entry) => expectedName[entry.key] == entry.value,
        )) {
      throw const FormatException(
        'Los metadatos locales no coinciden con el directorio central.',
      );
    }
    final hasDescriptor = flags & 0x0008 != 0;
    if ((!hasDescriptor &&
            (localCrc != crc ||
                localCompressed != compressedSize ||
                localExpanded != expandedSize)) ||
        (hasDescriptor &&
            ((localCrc != 0 && localCrc != crc) ||
                (localCompressed != 0 && localCompressed != compressedSize) ||
                (localExpanded != 0 && localExpanded != expandedSize)))) {
      throw const FormatException('Los tamaños o CRC locales no coinciden.');
    }
    _validateExtraFields(data, localOffset + 30 + nameLength, extraLength);
    return localOffset + headerLength;
  }

  static void _requireRange(ByteData data, int offset, int length, int limit) {
    if (offset < 0 ||
        length < 0 ||
        offset > limit ||
        length > limit - offset ||
        limit > data.lengthInBytes) {
      throw const FormatException(
        'La estructura ZIP está truncada o fuera de límites.',
      );
    }
  }

  static int _u16(ByteData data, int offset) {
    _requireRange(data, offset, 2, data.lengthInBytes);
    return data.getUint16(offset, Endian.little);
  }

  static int _u32(ByteData data, int offset) {
    _requireRange(data, offset, 4, data.lengthInBytes);
    return data.getUint32(offset, Endian.little);
  }
}

class WindowsZipEntryInfo {
  const WindowsZipEntryInfo({
    required this.path,
    required this.compressedSize,
    required this.expandedSize,
    required this.crc32,
    required this.compressionMethod,
  });

  final String path;
  final int compressedSize;
  final int expandedSize;
  final int crc32;
  final int compressionMethod;
}
