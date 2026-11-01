import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'suelosar_data/config/province_definition.dart';
import 'suelosar_data/cordoba_feature_metadata_builder.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length > 1) {
    stderr.writeln(
      'Usage: dart run tool/build_cordoba_feature_metadata.dart [output.json]',
    );
    exitCode = 64;
    return;
  }

  final root = Directory.current.path;
  final definition = ProvinceDefinition.load(
    id: 'cordoba',
    provincesDir: p.join(root, 'data', 'provinces'),
    repoRoot: root,
  );
  final index = await buildCordobaFeatureMetadataIndex(definition);
  final output = File(
    arguments.isEmpty
        ? p.join(root, 'assets', 'data', 'cordoba_feature_metadata.json')
        : p.absolute(arguments.single),
  );
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(index));
  stdout.writeln(
    'Escritas ${(index['features']! as Map).length} fichas en ${output.path}',
  );
}
