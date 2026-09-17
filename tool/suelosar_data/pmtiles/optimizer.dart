// Generic PMTiles attribute optimizer, extracted from
// tool/optimize_buenos_aires_pmtiles.dart (which is now a thin wrapper).
//
// Takes an archive produced by the Docker pipeline and writes a copy that
// keeps only the attributes of the SuelosAR schema. Geometry, feature ids,
// zoom levels, bounds, metadata and gzip compression are carried through
// byte-for-byte; every tile is verified after its transformation. When the
// archive has nothing to remove (OptimizeMode.auto), the file is copied, not
// rewritten.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pmtiles/pmtiles.dart';
import 'package:pmtiles/src/directory.dart' as pmdir;
import 'package:vector_tile/raw/raw_vector_tile.dart' as raw;

import '../config/province_definition.dart' show OptimizeMode;
import '../schema/suelosar_schema.dart';

class PmtilesStructureException implements Exception {
  PmtilesStructureException(this.message);
  final String message;
  @override
  String toString() => 'PmtilesStructureException: $message';
}

Never _fail(String message) => throw PmtilesStructureException(message);

Uint8List _gunzip(List<int> bytes) =>
    Uint8List.fromList(GZipCodec().decode(bytes));
Uint8List _gzip(List<int> bytes) =>
    Uint8List.fromList(GZipCodec(level: 9).encode(bytes));

/// What the optimizer found and did.
class OptimizeReport {
  OptimizeReport({
    required this.input,
    required this.output,
    required this.mode,
    required this.rewritten,
    required this.sizeBefore,
    required this.sizeAfter,
    required this.sha256Before,
    required this.sha256After,
    required this.uniqueTiles,
    required this.tileEntries,
    required this.layers,
    required this.attributesFound,
    required this.attributesRemoved,
    required this.attributeTileCounts,
    required this.attributesByZoom,
    required this.tilesByZoom,
    required this.minZoom,
    required this.maxZoom,
    required this.durationMs,
  });

  factory OptimizeReport.fromJson(Map<String, Object?> json) {
    Set<String> strings(String key) => {
      for (final v in json[key]! as List) v as String,
    };
    return OptimizeReport(
      input: json['input']! as String,
      output: json['output']! as String,
      mode: OptimizeMode.values.firstWhere((m) => m.key == json['mode']),
      rewritten: json['rewritten']! as bool,
      sizeBefore: json['sizeBefore']! as int,
      sizeAfter: json['sizeAfter']! as int,
      sha256Before: json['sha256Before']! as String,
      sha256After: json['sha256After']! as String,
      uniqueTiles: json['uniqueTiles']! as int,
      tileEntries: json['tileEntries']! as int,
      layers: strings('layers'),
      attributesFound: strings('attributesFound'),
      attributesRemoved: strings('attributesRemoved'),
      attributeTileCounts: (json['attributeTileCounts']! as Map)
          .cast<String, int>(),
      attributesByZoom: {
        for (final e in (json['attributesByZoom']! as Map).entries)
          int.parse(e.key as String): {
            for (final v in e.value as List) v as String,
          },
      },
      tilesByZoom: {
        for (final e in (json['tilesByZoom']! as Map).entries)
          int.parse(e.key as String): e.value as int,
      },
      minZoom: json['minZoom']! as int,
      maxZoom: json['maxZoom']! as int,
      durationMs: json['durationMs']! as int,
    );
  }

  final String input;
  final String output;
  final OptimizeMode mode;

  /// False when the archive was copied unchanged.
  final bool rewritten;
  final int sizeBefore;
  final int sizeAfter;
  final String sha256Before;
  final String sha256After;
  final int uniqueTiles;
  final int tileEntries;
  final Set<String> layers;

  /// Every attribute referenced by at least one feature of the input.
  final Set<String> attributesFound;

  /// Attributes removed from the output.
  final Set<String> attributesRemoved;

  /// Kept attribute -> number of unique tiles where some feature has it.
  final Map<String, int> attributeTileCounts;

  /// Zoom -> attributes kept in the output at that zoom.
  final Map<int, Set<String>> attributesByZoom;

  /// Zoom -> addressed tiles (run lengths expanded).
  final Map<int, int> tilesByZoom;
  final int minZoom;
  final int maxZoom;
  final int durationMs;

  /// Attributes present in the output.
  Set<String> get attributesKept => attributeTileCounts.keys.toSet();

  Map<String, Object?> toJson() => {
    'input': input,
    'output': output,
    'mode': mode.key,
    'rewritten': rewritten,
    'sizeBefore': sizeBefore,
    'sizeAfter': sizeAfter,
    'savedBytes': sizeBefore - sizeAfter,
    'savedPercent': sizeBefore == 0
        ? 0
        : double.parse(
            ((sizeBefore - sizeAfter) * 100 / sizeBefore).toStringAsFixed(2),
          ),
    'sha256Before': sha256Before,
    'sha256After': sha256After,
    'uniqueTiles': uniqueTiles,
    'tileEntries': tileEntries,
    'layers': layers.toList()..sort(),
    'attributesFound': attributesFound.toList()..sort(),
    'attributesRemoved': attributesRemoved.toList()..sort(),
    'attributesKept': attributesKept.toList()..sort(),
    'attributeTileCounts': Map.fromEntries(
      attributeTileCounts.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    ),
    'attributesByZoom': {
      for (final z in attributesByZoom.keys.toList()..sort())
        '$z': attributesByZoom[z]!.toList()..sort(),
    },
    'tilesByZoom': {
      for (final z in tilesByZoom.keys.toList()..sort()) '$z': tilesByZoom[z],
    },
    'minZoom': minZoom,
    'maxZoom': maxZoom,
    'durationMs': durationMs,
  };
}

/// SHA-256 sidecar content: lowercase hex and a newline, the format the
/// app's loader and docker/build_map.sh use.
void writeSha256Sidecar(File archive, String sha256) =>
    File('${archive.path}.sha256').writeAsStringSync('$sha256\n');

Future<String> sha256OfFile(File file) async =>
    (await crypto.sha256.bind(file.openRead()).first).toString();

class PmtilesOptimizer {
  PmtilesOptimizer({Set<String>? keep, void Function(String)? log})
    : keep = keep ?? SuelosArSchema.appAttributes,
      _log = log ?? ((_) {});

  /// Attributes that survive. Defaults to the central schema.
  final Set<String> keep;
  final void Function(String) _log;

  /// Optimizes [input] into [output] (and `<output>.sha256`). The output is
  /// written to a temporary file and renamed only after validation, so a
  /// failed run never leaves a half-written archive behind.
  Future<OptimizeReport> run(
    File input,
    File output, {
    OptimizeMode mode = OptimizeMode.auto,
  }) async {
    final watch = Stopwatch()..start();
    if (!input.existsSync()) _fail('No existe ${input.path}.');
    if (input.absolute.path == output.absolute.path) {
      _fail('La entrada y la salida deben ser archivos distintos.');
    }
    final raf = input.openSync();
    final archive = await PmTilesArchive.fromFile(input);
    try {
      final h = archive.header;
      _log('Source: ${input.path} (${input.lengthSync()} bytes)');
      if (h.version != 3) {
        _fail('Expected PMTiles version 3, found version ${h.version}.');
      }
      if (h.tileType != TileType.mvt) {
        _fail('Expected MVT tiles, found tile type ${h.tileType}.');
      }
      if (h.tileCompression != Compression.gzip) {
        _fail(
          'Expected gzip tile compression, found ${h.tileCompression}. '
          'This tool only ever reads/writes gzip.',
        );
      }
      if (h.internalCompression != Compression.gzip) {
        _fail(
          'Expected gzip internal (directory/metadata) compression, found ${h.internalCompression}.',
        );
      }
      if (h.clustered != Clustered.clustered) {
        _fail('Expected a clustered archive.');
      }
      _log(
        'Header OK: v${h.version}, MVT, gzip, zoom ${h.minZoom}-${h.maxZoom}, clustered.',
      );

      // ---- Directories (2 levels: root + leaves, discovered) ----
      final leafNodes = <List<pmdir.Entry>>[];
      final rootEntries = archive.root.entries;
      final rootLeafRefs = <int?>[];
      Future<List<pmdir.Entry>> loadLeafEntries(int offset, int length) async {
        final rawBytes = Uint8List(length);
        raf.setPositionSync(h.leafDirectoriesOffset + offset);
        raf.readIntoSync(rawBytes);
        return pmdir.Directory.from(_gunzip(rawBytes), header: h).entries;
      }

      for (final e in rootEntries) {
        if (!e.isLeaf) {
          rootLeafRefs.add(null);
          continue;
        }
        final entries = await loadLeafEntries(e.offset, e.length);
        if (entries.any((sub) => sub.isLeaf)) {
          _fail(
            'Found a 3-level directory (a leaf entry pointing to another leaf); '
            'only the 2-level root+leaf shape is supported.',
          );
        }
        leafNodes.add(entries);
        rootLeafRefs.add(leafNodes.length - 1);
      }

      final uniqueOldOffsets = <int>{};
      final oldOffsetToLength = <int, int>{};
      final offsetZooms = <int, Set<int>>{};
      final tilesByZoom = <int, int>{};
      final sampleByZoom = <int, (int, int, int, int)>{};
      var tileEntries = 0;
      void trackEntry(pmdir.Entry e) {
        tileEntries++;
        uniqueOldOffsets.add(e.offset);
        oldOffsetToLength[e.offset] = e.length;
        final z = e.zxy.z;
        offsetZooms.putIfAbsent(e.offset, () => {}).add(z);
        tilesByZoom[z] =
            (tilesByZoom[z] ?? 0) + (e.runLength == 0 ? 1 : e.runLength);
        if (e.runLength == 0) return;
        final existing = sampleByZoom[z];
        if (existing == null || e.length > existing.$4) {
          sampleByZoom[z] = (e.zxy.x, e.zxy.y, e.runLength, e.length);
        }
      }

      for (final leaf in leafNodes) {
        leaf.forEach(trackEntry);
      }
      for (final e in rootEntries) {
        if (!e.isLeaf) trackEntry(e);
      }
      final sortedOldOffsets = uniqueOldOffsets.toList()..sort();
      _log(
        'Directory: ${rootEntries.length} root entries, ${leafNodes.length} leaf '
        'directories, ${sortedOldOffsets.length} unique tiles.',
      );

      Uint8List readTile(int offset) {
        final bytes = Uint8List(oldOffsetToLength[offset]!);
        raf.setPositionSync(h.tileDataOffset + offset);
        raf.readIntoSync(bytes);
        return bytes;
      }

      // ---- Pass 1: discover the attributes every feature carries ----
      final layers = <String>{};
      final found = <String>{};
      for (final offset in sortedOldOffsets) {
        final tile = _parse(_gunzip(readTile(offset)));
        for (final layer in tile.layers) {
          layers.add(layer.name);
          for (final f in layer.features) {
            for (var i = 0; i < f.tags.length; i += 2) {
              if (f.tags[i] >= layer.keys.length) {
                _fail(
                  'Feature tag references a key index out of range in layer "${layer.name}".',
                );
              }
              found.add(layer.keys[f.tags[i]]);
            }
          }
        }
      }
      final removable = found.difference(keep);
      final rewrite = switch (mode) {
        OptimizeMode.always => true,
        OptimizeMode.never => false,
        OptimizeMode.auto => removable.isNotEmpty,
      };
      _log(
        'Attributes found: ${found.length}; outside the schema: '
        '${removable.isEmpty ? 'none' : (removable.toList()..sort()).join(', ')}; '
        '${rewrite ? 'rewriting' : 'copying unchanged'} (mode ${mode.key}).',
      );

      final attributeTileCounts = <String, int>{};
      final attributesByZoom = <int, Set<String>>{};
      void countKept(int offset, Set<String> keptInTile) {
        for (final a in keptInTile) {
          attributeTileCounts[a] = (attributeTileCounts[a] ?? 0) + 1;
        }
        for (final z in offsetZooms[offset]!) {
          attributesByZoom.putIfAbsent(z, () => {}).addAll(keptInTile);
        }
      }

      final temp = File('${output.path}.tmp');
      output.parent.createSync(recursive: true);
      final sizeBefore = input.lengthSync();
      final shaBefore = await sha256OfFile(input);

      if (!rewrite) {
        // The output is the input: its attributes are all of them.
        for (final offset in sortedOldOffsets) {
          final tile = _parse(_gunzip(readTile(offset)));
          final inTile = <String>{};
          for (final layer in tile.layers) {
            for (final f in layer.features) {
              for (var i = 0; i < f.tags.length; i += 2) {
                inTile.add(layer.keys[f.tags[i]]);
              }
            }
          }
          countKept(offset, inTile);
        }
        raf.closeSync();
        await archive.close();
        await input.copy(temp.path);
        final shaCopy = await sha256OfFile(temp);
        if (shaCopy != shaBefore) _fail('La copia no coincide con la entrada.');
        _replace(temp, output);
        writeSha256Sidecar(output, shaCopy);
        return OptimizeReport(
          input: input.path,
          output: output.path,
          mode: mode,
          rewritten: false,
          sizeBefore: sizeBefore,
          sizeAfter: output.lengthSync(),
          sha256Before: shaBefore,
          sha256After: shaCopy,
          uniqueTiles: sortedOldOffsets.length,
          tileEntries: tileEntries,
          layers: layers,
          attributesFound: found,
          attributesRemoved: const {},
          attributeTileCounts: attributeTileCounts,
          attributesByZoom: attributesByZoom,
          tilesByZoom: tilesByZoom,
          minZoom: h.minZoom,
          maxZoom: h.maxZoom,
          durationMs: watch.elapsedMilliseconds,
        );
      }

      // ---- Pass 2: strip and verify every unique tile ----
      final oldOffsetToNewBytes = <int, Uint8List>{};
      var processed = 0;
      for (final oldOffset in sortedOldOffsets) {
        final decompressed = _gunzip(readTile(oldOffset));
        final stripped = _stripAttributes(decompressed);
        final keptInTile = _verifyTileTransform(decompressed, stripped);
        countKept(oldOffset, keptInTile);
        oldOffsetToNewBytes[oldOffset] = _gzip(stripped);
        processed++;
        if (processed % 20000 == 0) {
          _log('processed $processed/${sortedOldOffsets.length}...');
        }
      }

      // ---- Reassemble tile data and directories ----
      final oldOffsetToNewOffset = <int, int>{};
      var cursor = 0;
      final tileDataOut = BytesBuilder(copy: false);
      for (final oldOffset in sortedOldOffsets) {
        oldOffsetToNewOffset[oldOffset] = cursor;
        final bytes = oldOffsetToNewBytes[oldOffset]!;
        tileDataOut.add(bytes);
        cursor += bytes.length;
      }
      final newTileData = tileDataOut.toBytes();

      final leafDirsOut = BytesBuilder();
      final leafNewOffsetLength = <int, (int, int)>{};
      for (var i = 0; i < leafNodes.length; i++) {
        final newEntries = [
          for (final e in leafNodes[i])
            pmdir.Entry(
              tileId: e.tileId,
              runLength: e.runLength,
              offset: oldOffsetToNewOffset[e.offset]!,
              length: oldOffsetToNewBytes[e.offset]!.length,
            ),
        ];
        final compressed = _gzip(_serializeDirectory(newEntries));
        leafNewOffsetLength[i] = (leafDirsOut.length, compressed.length);
        leafDirsOut.add(compressed);
      }
      final newLeafDirsBytes = leafDirsOut.toBytes();

      final newRootEntries = <pmdir.Entry>[];
      for (var i = 0; i < rootEntries.length; i++) {
        final e = rootEntries[i];
        if (e.isLeaf) {
          final (newOffset, newLength) = leafNewOffsetLength[rootLeafRefs[i]!]!;
          newRootEntries.add(
            pmdir.Entry(
              tileId: e.tileId,
              runLength: 0,
              offset: newOffset,
              length: newLength,
            ),
          );
        } else {
          newRootEntries.add(
            pmdir.Entry(
              tileId: e.tileId,
              runLength: e.runLength,
              offset: oldOffsetToNewOffset[e.offset]!,
              length: oldOffsetToNewBytes[e.offset]!.length,
            ),
          );
        }
      }
      final newRootCompressed = _gzip(_serializeDirectory(newRootEntries));

      final metaRaw = Uint8List(h.metadataLength);
      raf.setPositionSync(h.metadataOffset);
      raf.readIntoSync(metaRaw);

      const rootOffset = 127;
      final rootLength = newRootCompressed.length;
      final metadataOffset = rootOffset + rootLength;
      final metadataLength = h.metadataLength;
      final leafDirsOffset = metadataOffset + metadataLength;
      final leafDirsLength = newLeafDirsBytes.length;
      final tileDataOffset = leafDirsOffset + leafDirsLength;

      final headerBytes = Uint8List(127);
      raf.setPositionSync(0);
      raf.readIntoSync(headerBytes);
      ByteData.sublistView(headerBytes)
        ..setUint64(0x10, rootLength, Endian.little)
        ..setUint64(0x18, metadataOffset, Endian.little)
        ..setUint64(0x20, metadataLength, Endian.little)
        ..setUint64(0x28, leafDirsOffset, Endian.little)
        ..setUint64(0x30, leafDirsLength, Endian.little)
        ..setUint64(0x38, tileDataOffset, Endian.little)
        ..setUint64(0x40, newTileData.length, Endian.little);

      final sink = temp.openSync(mode: FileMode.write);
      try {
        sink
          ..writeFromSync(headerBytes)
          ..writeFromSync(newRootCompressed)
          ..writeFromSync(metaRaw)
          ..writeFromSync(newLeafDirsBytes)
          ..writeFromSync(newTileData);
      } finally {
        sink.closeSync();
      }
      raf.closeSync();
      await archive.close();

      await _validateResult(input, temp, sampleByZoom);
      final shaAfter = await sha256OfFile(temp);
      _replace(temp, output);
      writeSha256Sidecar(output, shaAfter);
      final sizeAfter = output.lengthSync();
      _log(
        'Wrote ${output.path}: $sizeBefore -> $sizeAfter bytes '
        '(${((sizeBefore - sizeAfter) * 100 / sizeBefore).toStringAsFixed(2)} % menos), SHA-256 $shaAfter',
      );
      return OptimizeReport(
        input: input.path,
        output: output.path,
        mode: mode,
        rewritten: true,
        sizeBefore: sizeBefore,
        sizeAfter: sizeAfter,
        sha256Before: shaBefore,
        sha256After: shaAfter,
        uniqueTiles: sortedOldOffsets.length,
        tileEntries: tileEntries,
        layers: layers,
        attributesFound: found,
        attributesRemoved: removable,
        attributeTileCounts: attributeTileCounts,
        attributesByZoom: attributesByZoom,
        tilesByZoom: tilesByZoom,
        minZoom: h.minZoom,
        maxZoom: h.maxZoom,
        durationMs: watch.elapsedMilliseconds,
      );
    } finally {
      // Both may already be closed on the success paths.
      try {
        raf.closeSync();
      } on Object {
        // Already closed.
      }
      try {
        await archive.close();
      } on Object {
        // Already closed.
      }
      final temp = File('${output.path}.tmp');
      if (temp.existsSync()) temp.deleteSync();
    }
  }

  static void _replace(File temp, File output) {
    if (output.existsSync()) output.deleteSync();
    temp.renameSync(output.path);
  }

  static raw.VectorTile _parse(Uint8List bytes) {
    try {
      return raw.VectorTile.fromBuffer(bytes);
    } on Object catch (e) {
      _fail('Could not parse a tile as a Mapbox Vector Tile protobuf: $e');
    }
  }

  /// Strips every attribute not in [keep]. Feature ids, geometry type and
  /// the raw geometry command list are copied untouched.
  Uint8List _stripAttributes(Uint8List mvtBytes) {
    final tile = _parse(mvtBytes);
    final newLayers = <raw.VectorTile_Layer>[];
    for (final layer in tile.layers) {
      final oldKeys = layer.keys;
      final oldValues = layer.values;
      final newKeys = <String>[];
      final keyIndexMap = <int, int>{};
      for (var i = 0; i < oldKeys.length; i++) {
        if (keep.contains(oldKeys[i])) {
          keyIndexMap[i] = newKeys.length;
          newKeys.add(oldKeys[i]);
        }
      }
      final referencedOldValueIndices = <int>{};
      final newFeaturesTags = <List<int>>[];
      for (final f in layer.features) {
        final newTags = <int>[];
        for (var i = 0; i < f.tags.length; i += 2) {
          final oldKeyIdx = f.tags[i];
          final oldValIdx = f.tags[i + 1];
          if (oldKeyIdx >= oldKeys.length || oldValIdx >= oldValues.length) {
            _fail(
              'Feature tag references key/value index out of range '
              '(key=$oldKeyIdx of ${oldKeys.length}, value=$oldValIdx of ${oldValues.length}).',
            );
          }
          final newKeyIdx = keyIndexMap[oldKeyIdx];
          if (newKeyIdx == null) continue;
          newTags
            ..add(newKeyIdx)
            ..add(oldValIdx);
          referencedOldValueIndices.add(oldValIdx);
        }
        newFeaturesTags.add(newTags);
      }
      final sortedOldValueIndices = referencedOldValueIndices.toList()..sort();
      final valueIndexMap = <int, int>{};
      final newValues = <raw.VectorTile_Value>[];
      for (final oldIdx in sortedOldValueIndices) {
        valueIndexMap[oldIdx] = newValues.length;
        newValues.add(oldValues[oldIdx]);
      }
      final newFeatures = <raw.VectorTile_Feature>[];
      for (var i = 0; i < layer.features.length; i++) {
        final f = layer.features[i];
        final rawTags = newFeaturesTags[i];
        final remappedTags = <int>[];
        for (var j = 0; j < rawTags.length; j += 2) {
          remappedTags
            ..add(rawTags[j])
            ..add(valueIndexMap[rawTags[j + 1]]!);
        }
        newFeatures.add(
          raw.VectorTile_Feature(
            id: f.id,
            tags: remappedTags,
            type: f.type,
            geometry: f.geometry,
          ),
        );
      }
      newLayers.add(
        raw.VectorTile_Layer(
          name: layer.name,
          extent: layer.extent,
          version: layer.version,
          keys: newKeys,
          values: newValues,
          features: newFeatures,
        ),
      );
    }
    return Uint8List.fromList(
      raw.VectorTile(layers: newLayers).writeToBuffer(),
    );
  }

  /// Checks one tile's transformation: same layers, features, ids, geometry
  /// types and geometry commands; surviving attributes exactly the original
  /// ones that are in [keep]. Returns the attributes kept in the tile.
  Set<String> _verifyTileTransform(
    Uint8List originalMvt,
    Uint8List strippedMvt,
  ) {
    final originalTile = _parse(originalMvt);
    final strippedTile = _parse(strippedMvt);
    final keptInTile = <String>{};
    if (originalTile.layers.length != strippedTile.layers.length) {
      _fail(
        'Layer count changed (${originalTile.layers.length} -> ${strippedTile.layers.length}).',
      );
    }
    for (var li = 0; li < originalTile.layers.length; li++) {
      final ol = originalTile.layers[li];
      final nl = strippedTile.layers[li];
      if (ol.features.length != nl.features.length) {
        _fail(
          'Feature count changed in layer "${ol.name}" (${ol.features.length} -> ${nl.features.length}).',
        );
      }
      for (var fi = 0; fi < ol.features.length; fi++) {
        final of = ol.features[fi];
        final nf = nl.features[fi];
        if (of.id != nf.id) {
          _fail(
            'Feature id changed in layer "${ol.name}" (${of.id} -> ${nf.id}).',
          );
        }
        if (of.type != nf.type) {
          _fail(
            'Geometry type changed for feature ${of.id} in layer "${ol.name}".',
          );
        }
        final og = of.geometry;
        final ng = nf.geometry;
        if (og.length != ng.length) {
          _fail(
            'Geometry command count changed for feature ${of.id} in layer "${ol.name}".',
          );
        }
        for (var i = 0; i < og.length; i++) {
          if (og[i] != ng[i]) {
            _fail(
              'Geometry command $i differs for feature ${of.id} in layer "${ol.name}".',
            );
          }
        }
        final oldProps = <String>{
          for (var i = 0; i < of.tags.length; i += 2) ol.keys[of.tags[i]],
        };
        final newProps = <String>{
          for (var i = 0; i < nf.tags.length; i += 2) nl.keys[nf.tags[i]],
        };
        final expected = oldProps.intersection(keep);
        if (newProps.length != expected.length ||
            !newProps.containsAll(expected)) {
          _fail(
            'Feature ${of.id} in layer "${ol.name}" has an unexpected surviving '
            'attribute set. Expected exactly $expected, got $newProps.',
          );
        }
        final leaked = newProps.difference(keep);
        if (leaked.isNotEmpty) {
          _fail(
            'Feature ${of.id} in layer "${ol.name}" still has attribute(s) that must be removed: $leaked.',
          );
        }
        keptInTile.addAll(newProps);
      }
    }
    return keptInTile;
  }

  /// Re-opens the written file with the app's reader and compares it with
  /// the original: header fields, full metadata, and a decoded sample of the
  /// three deepest zooms.
  Future<void> _validateResult(
    File inputFile,
    File outputFile,
    Map<int, (int, int, int, int)> sampleByZoom,
  ) async {
    final original = await PmTilesArchive.fromFile(inputFile);
    final result = await PmTilesArchive.fromFile(outputFile);
    try {
      void checkEqual(String label, Object a, Object b) {
        if (a.toString() != b.toString()) {
          _fail('Validation failed: $label differs (original=$a, result=$b).');
        }
      }

      checkEqual('version', original.version, result.version);
      checkEqual('tileType', original.tileType, result.tileType);
      checkEqual(
        'tileCompression',
        original.tileCompression,
        result.tileCompression,
      );
      checkEqual('minZoom', original.minZoom, result.minZoom);
      checkEqual('maxZoom', original.maxZoom, result.maxZoom);
      checkEqual('minPosition', original.minPosition, result.minPosition);
      checkEqual('maxPosition', original.maxPosition, result.maxPosition);
      checkEqual(
        'centerPosition',
        original.centerPosition,
        result.centerPosition,
      );
      checkEqual(
        'numberOfAddressedTiles',
        original.header.numberOfAddressedTiles,
        result.header.numberOfAddressedTiles,
      );
      checkEqual(
        'numberOfTileEntries',
        original.header.numberOfTileEntries,
        result.header.numberOfTileEntries,
      );
      checkEqual(
        'numberOfTileContents',
        original.header.numberOfTileContents,
        result.header.numberOfTileContents,
      );
      checkEqual(
        'metadata',
        jsonEncode(await original.metadata),
        jsonEncode(await result.metadata),
      );

      final maxZoom = original.maxZoom;
      for (final z in [maxZoom - 2, maxZoom - 1, maxZoom]) {
        final sample = sampleByZoom[z];
        if (sample == null) continue;
        final (x, y, _, _) = sample;
        final tile = await result.tile(ZXY(z, x, y).toTileId());
        final vt = _parse(Uint8List.fromList(tile.bytes()));
        final total = vt.layers.fold<int>(0, (a, l) => a + l.features.length);
        if (total == 0) {
          _fail(
            'Validation failed: sample tile z$z/$x/$y decoded with zero features.',
          );
        }
      }
      _log('Validation passed (header, metadata and deep-zoom samples).');
    } finally {
      await original.close();
      await result.close();
    }
  }

  static void _writeVarint(BytesBuilder out, int value) {
    var v = value;
    while (true) {
      if (v & ~0x7F == 0) {
        out.addByte(v);
        return;
      }
      out.addByte((v & 0x7F) | 0x80);
      v = v >> 7;
    }
  }

  static Uint8List _serializeDirectory(List<pmdir.Entry> entries) {
    final out = BytesBuilder();
    _writeVarint(out, entries.length);
    var lastId = 0;
    for (final e in entries) {
      _writeVarint(out, e.tileId - lastId);
      lastId = e.tileId;
    }
    for (final e in entries) {
      _writeVarint(out, e.runLength);
    }
    for (final e in entries) {
      _writeVarint(out, e.length);
    }
    for (final e in entries) {
      _writeVarint(out, e.offset + 1);
    }
    return out.toBytes();
  }
}
