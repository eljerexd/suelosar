import 'dart:collection';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/services/windows_differential_zip_preflight.dart';

void main() {
  group('WindowsDifferentialZipPreflight', () {
    test('accepts a bounded declared archive and returns central metadata', () {
      final archive = _zip({'data/app.so': utf8.encode('abc')});

      final entries = WindowsDifferentialZipPreflight.inspect(
        archive,
        expectedFiles: const {'data/app.so': 3},
      );

      expect(entries, hasLength(1));
      expect(entries.single.path, 'data/app.so');
      expect(entries.single.expandedSize, 3);
      expect(entries.single.compressedSize, greaterThan(0));
      expect(entries.single.crc32, isNot(0));
    });

    test('rejects traversal, absolute, device, ADS, mixed separator and Unicode names', () {
      final invalidPaths = <String>[
        '../app.dll',
        'data/../../app.dll',
        '/rooted.dll',
        r'\rooted.dll',
        r'\\server\share\app.dll',
        'C:/Windows/app.dll',
        r'data\..\app.dll',
        'data/app.dll:stream',
        'CON.txt',
        'dir/NUL.log',
        'trail./file',
        'trail /file',
        'café.txt',
        'x' * 241,
      ];

      for (final path in invalidPaths) {
        final archive = _zip({path: utf8.encode('x')});
        expect(
          () => WindowsDifferentialZipPreflight.inspect(
            archive,
            expectedFiles: {path: 1},
          ),
          throwsFormatException,
          reason: path,
        );
      }
    });

    test('rejects case-insensitive duplicate paths', () {
      final archive = _zip({
        'Data/App.dll': utf8.encode('one'),
        'data/app.DLL': utf8.encode('two'),
      });

      expect(
        () => WindowsDifferentialZipPreflight.inspect(
          archive,
          expectedFiles: const {'Data/App.dll': 3, 'data/app.DLL': 3},
        ),
        throwsFormatException,
      );
    });

    test('rejects undeclared entries and declared size mismatches', () {
      final archive = _zip({'unexpected.dll': utf8.encode('payload')});

      expect(
        () => WindowsDifferentialZipPreflight.inspect(
          archive,
          expectedFiles: const {'expected.dll': 7},
        ),
        throwsFormatException,
      );
      expect(
        () => WindowsDifferentialZipPreflight.inspect(
          archive,
          expectedFiles: const {'unexpected.dll': 999},
        ),
        throwsFormatException,
      );
    });

    test('rejects symbolic links before archive decoding', () {
      final archive = _zip({'link.txt': utf8.encode('target')});
      final central = _findSignature(archive, 0x02014b50);
      _put16(archive, central + 4, 0x0314); // Unix creator.
      _put32(archive, central + 38, 0xa1ff0000); // Symlink mode 0120777.

      expect(
        () => WindowsDifferentialZipPreflight.inspect(
          archive,
          expectedFiles: const {'link.txt': 6},
        ),
        throwsFormatException,
      );
    });

    test('rejects compression bombs above the configured ratio', () {
      final payload = List<int>.filled(2 * 1024 * 1024, 0);
      final archive = _zip({'zeros.bin': payload});

      expect(
        () => WindowsDifferentialZipPreflight.inspect(
          archive,
          expectedFiles: {'zeros.bin': payload.length},
        ),
        throwsFormatException,
      );
    });

    test('rejects truncation, damaged central directory and inconsistent local metadata', () {
      final valid = _zip({'app.dll': utf8.encode('payload')});
      final truncated = valid.sublist(0, valid.length - 1);
      expect(
        () => WindowsDifferentialZipPreflight.inspect(
          truncated,
          expectedFiles: const {'app.dll': 7},
        ),
        throwsFormatException,
      );

      final invalidCentral = List<int>.from(valid);
      final central = _findSignature(invalidCentral, 0x02014b50);
      _put32(invalidCentral, central, 0);
      expect(
        () => WindowsDifferentialZipPreflight.inspect(
          invalidCentral,
          expectedFiles: const {'app.dll': 7},
        ),
        throwsFormatException,
      );

      final invalidLocal = List<int>.from(valid);
      _put32(invalidLocal, 14, 1); // Local CRC differs from central CRC.
      expect(
        () => WindowsDifferentialZipPreflight.inspect(
          invalidLocal,
          expectedFiles: const {'app.dll': 7},
        ),
        throwsFormatException,
      );
    });

    test('rejects oversized archives before attempting to decode them', () {
      expect(
        () => WindowsDifferentialZipPreflight.inspect(
          _OversizedList(
            WindowsDifferentialZipPreflight.maximumArchiveBytes + 1,
          ),
          expectedFiles: const {},
        ),
        throwsFormatException,
      );
    });
  });
}

class _OversizedList extends ListBase<int> {
  _OversizedList(this._length);

  final int _length;

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('Fixed-size test list');

  @override
  int operator [](int index) => 0;

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('Fixed-size test list');
}

List<int> _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final file in files.entries) {
    archive.addFile(ArchiveFile(file.key, file.value.length, file.value));
  }
  return ZipEncoder().encode(archive);
}

int _findSignature(List<int> bytes, int signature) {
  for (var offset = 0; offset <= bytes.length - 4; offset++) {
    if (_u32(bytes, offset) == signature) return offset;
  }
  throw StateError('Signature not found: $signature');
}

int _u32(List<int> bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

void _put16(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
}

void _put32(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = (value >> 16) & 0xff;
  bytes[offset + 3] = (value >> 24) & 0xff;
}
