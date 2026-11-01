import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _fields = <String>[
  'taxo_ppal',
  'taxo_2rio',
  'taxo_3rio',
  'taxo_4rio',
  'taxo_5',
  'taxo_6',
  'FASE1',
  'FASE2',
  'FASE3',
  'FASE4',
  'FASE5',
  'FASE6',
  'POSIC1',
  'POSIC2',
  'POSIC3',
  'POSIC4',
  'POSIC5',
  // POSIC6 is stored as opaque 0/1 values in this DBF and its local metadata
  // declares no value domain. Keep it out until its source coding is known.
];

void main(List<String> arguments) {
  final input = File(
    arguments.isEmpty ? 'docker/input/Suelos_BA_50mil_V2.dbf' : arguments[0],
  );
  final output = File(
    arguments.length < 2
        ? 'assets/data/buenos_aires_feature_metadata.json'
        : arguments[1],
  );
  final bytes = input.readAsBytesSync();
  final view = ByteData.sublistView(Uint8List.fromList(bytes));
  final recordCount = view.getUint32(4, Endian.little);
  final headerLength = view.getUint16(8, Endian.little);
  final recordLength = view.getUint16(10, Endian.little);

  final descriptors = <_DbfField>[];
  for (
    var offset = 32;
    offset < headerLength && bytes[offset] != 0x0d;
    offset += 32
  ) {
    final name = ascii
        .decode(bytes.sublist(offset, offset + 11))
        .replaceAll('\u0000', '')
        .trim();
    descriptors.add(_DbfField(name, bytes[offset + 16]));
  }
  var fieldOffset = 1;
  for (final field in descriptors) {
    field.offset = fieldOffset;
    fieldOffset += field.width;
  }
  final byName = {for (final field in descriptors) field.name: field};
  for (final required in ['OBJECTID', 'SIMBC', ..._fields]) {
    if (!byName.containsKey(required)) {
      throw FormatException('DBF is missing required field $required.');
    }
  }

  String readField(int recordOffset, String name) {
    final field = byName[name]!;
    return utf8
        .decode(
          bytes.sublist(
            recordOffset + field.offset,
            recordOffset + field.offset + field.width,
          ),
          allowMalformed: true,
        )
        .replaceAll('\u0000', '')
        .trim();
  }

  final features = <String, Map<String, Object?>>{};
  for (var index = 0; index < recordCount; index++) {
    final start = headerLength + index * recordLength;
    if (bytes[start] == 0x2a) continue;
    final id = int.tryParse(readField(start, 'OBJECTID'));
    final symbol = readField(start, 'SIMBC');
    if (id == null || symbol.isEmpty) continue;
    final metadata = <String, Object?>{'SIMBC': symbol};
    for (final field in _fields) {
      final value = readField(start, field);
      if (value.isNotEmpty) metadata[field] = value;
    }
    if (metadata.length > 1) {
      final key = jsonEncode([id.toString(), symbol]);
      final existing = features[key];
      if (existing != null && jsonEncode(existing) != jsonEncode(metadata)) {
        throw FormatException(
          'Conflicting Buenos Aires metadata for OBJECTID $id and SIMBC $symbol.',
        );
      }
      features[key] = metadata;
    }
  }

  output.parent.createSync(recursive: true);
  const encoder = JsonEncoder.withIndent('  ');
  output.writeAsStringSync(
    '${encoder.convert({
      'version': 1,
      'province': 'buenos_aires',
      'identityFields': ['OBJECTID', 'SIMBC'],
      'keyEncoding': 'json-array',
      'source': input.path.replaceAll('\\', '/'),
      'features': features,
    })}\n',
    flush: true,
  );
  stdout.writeln(
    'Wrote ${features.length} keyed metadata records to ${output.path}',
  );
}

class _DbfField {
  _DbfField(this.name, this.width);

  final String name;
  final int width;
  int offset = 0;
}
