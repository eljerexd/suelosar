// Second, optional stage after the main Docker GIS pipeline
// (`docker/build_map.sh`): takes the PMTiles archive that pipeline already
// produced and writes a second, separate archive with the same PMTiles
// container, MVT tiles, gzip compression, zoom range, bounds, metadata,
// feature ids and geometries -- but with the attributes SuelosAR never
// reads removed from every feature. See `docker/README.md` for the full
// two-stage flow and the exact field lists this reproduces.
//
// This never touches the Docker pipeline, Tippecanoe, or GDAL: it operates
// purely on the PMTiles container and the Mapbox Vector Tile protobuf
// structure already inside it, using this project's own `pmtiles` and
// `vector_tile` packages (the same ones `lib/gis/gis_repository.dart` uses
// to read these archives at runtime) for every read, so the output is
// guaranteed parseable by the exact same code the app ships with. Writing a
// PMTiles container has no existing library support (the `pmtiles` package
// is read-only), so the directory/header serialization below is this
// script's own -- validated by having every other property this script
// asserts round-trip correctly, and by re-opening the result with the same
// reader used everywhere else.
//
// Usage:
//   dart run tool/optimize_buenos_aires_pmtiles.dart <input.pmtiles> <output.pmtiles>
//
// The input file is only ever read, never modified. Fails loudly (non-zero
// exit, descriptive message) on any structural assumption that doesn't
// hold, rather than silently producing a subtly-wrong archive.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:pmtiles/pmtiles.dart';
import 'package:pmtiles/src/directory.dart' as pmdir;
import 'package:vector_tile/raw/raw_vector_tile.dart' as raw;

/// The 16 attributes SuelosAR's own code reads from a Buenos Aires
/// feature's properties (`lib/gis/gis_map_screen.dart`,
/// `lib/gis/gis_soil_series.dart`, `lib/gis/engine/maplibre_engine.dart`) —
/// everything else in the source dataset's 36-field schema is dead weight
/// the app never touches.
const keptAttributes = {
  'SIMBC', 'CAP_USO', 'Nombre_UC',
  'SERIE1', 'SERIE2', 'SERIE3', 'SERIE4', 'SERIE5', 'SERIE6',
  'PORC1', 'PORC2', 'PORC3', 'PORC4', 'PORC5', 'PORC6',
  'OBJECTID',
};

/// The 20 attributes confirmed (by exhaustive grep of `lib/`) to have zero
/// readers anywhere in the app. Not load-bearing for the transformation
/// itself (anything not in [keptAttributes] is dropped regardless) — kept
/// here only so [_validateResult] can assert none of them survived, as a
/// second, independent check against the same intent.
const droppedAttributes = {
  'FASE1', 'FASE2', 'FASE3', 'FASE4', 'FASE5',
  'OBJECTID_1', 'PAISAJE',
  'POSIC1', 'POSIC2', 'POSIC3', 'POSIC4', 'POSIC5', 'POSIC6',
  'TIPO', 'taxo_2rio', 'taxo_3rio', 'taxo_4rio', 'taxo_5', 'taxo_6', 'taxo_ppal',
};

class PmtilesStructureException implements Exception {
  PmtilesStructureException(this.message);
  final String message;
  @override
  String toString() => 'PmtilesStructureException: $message';
}

Never _fail(String message) => throw PmtilesStructureException(message);

Uint8List _gunzip(List<int> bytes) => Uint8List.fromList(GZipCodec().decode(bytes));
Uint8List _gzip(List<int> bytes) => Uint8List.fromList(GZipCodec(level: 9).encode(bytes));

void _writeVarint(BytesBuilder out, int value) {
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

Uint8List _serializeDirectory(List<pmdir.Entry> entries) {
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

/// Strips every attribute not in [keptAttributes] from the tile's layer(s).
/// Feature ids, geometry type, and the raw geometry command list are copied
/// through completely untouched -- this function never decodes, and never
/// re-encodes, a single coordinate.
Uint8List _stripAttributes(Uint8List mvtBytes) {
  final raw.VectorTile tile;
  try {
    tile = raw.VectorTile.fromBuffer(mvtBytes);
  } catch (e) {
    _fail('Could not parse a tile as a Mapbox Vector Tile protobuf: $e');
  }
  final newLayers = <raw.VectorTile_Layer>[];
  for (final layer in tile.layers) {
    final oldKeys = layer.keys;
    final oldValues = layer.values;

    final newKeys = <String>[];
    final keyIndexMap = <int, int>{};
    for (var i = 0; i < oldKeys.length; i++) {
      if (keptAttributes.contains(oldKeys[i])) {
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
            '(key=$oldKeyIdx of ${oldKeys.length}, '
            'value=$oldValIdx of ${oldValues.length}) -- unexpected MVT '
            'structure, refusing to guess.',
          );
        }
        final newKeyIdx = keyIndexMap[oldKeyIdx];
        if (newKeyIdx == null) continue;
        newTags.add(newKeyIdx);
        newTags.add(oldValIdx);
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
        remappedTags.add(rawTags[j]);
        remappedTags.add(valueIndexMap[rawTags[j + 1]]!);
      }
      newFeatures.add(
        raw.VectorTile_Feature(
          id: f.id,
          tags: remappedTags,
          type: f.type,
          geometry: f.geometry, // untouched: same list instance, same ints.
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
  return Uint8List.fromList(raw.VectorTile(layers: newLayers).writeToBuffer());
}

class _OptimizationStats {
  int tilesProcessed = 0;
  int oldTileBytes = 0;
  int newTileBytes = 0;
  final Set<String> attributesSeen = {};

  /// One representative (z, x, y) per requested zoom level, picked from
  /// the real, discovered directory entries as they're walked (never
  /// computed from a hand-rolled projection formula) -- whichever tile
  /// happens to have the most features at that zoom, so the sample is a
  /// meaningful one rather than possibly-empty.
  final Map<int, (int, int, int, int)> bestSampleByZoom = {}; // zoom -> (x, y, runLength, featureCountProxy)
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/optimize_buenos_aires_pmtiles.dart '
      '<input.pmtiles> <output.pmtiles>',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  final inputPath = arguments[0];
  final outputPath = arguments[1];
  final inputFile = File(inputPath);
  final outputFile = File(outputPath);

  if (!inputFile.existsSync()) {
    stderr.writeln('[optimize] ERROR: input file not found: $inputPath');
    exitCode = 66; // EX_NOINPUT
    return;
  }
  if (inputFile.absolute.path == outputFile.absolute.path) {
    stderr.writeln('[optimize] ERROR: input and output must be different files.');
    exitCode = 64;
    return;
  }

  try {
    final stats = await _run(inputFile, outputFile);
    stdout.writeln('');
    stdout.writeln('[optimize] Done.');
    stdout.writeln(
      '[optimize] Tiles processed: ${stats.tilesProcessed}',
    );
    stdout.writeln(
      '[optimize] Attributes actually seen in the source data '
      '(${stats.attributesSeen.length}/${keptAttributes.length} expected kept ones): '
      '${(stats.attributesSeen.toList()..sort()).join(', ')}',
    );
  } on PmtilesStructureException catch (e) {
    stderr.writeln('[optimize] ERROR: ${e.message}');
    exitCode = 1;
  }
}

Future<_OptimizationStats> _run(File inputFile, File outputFile) async {
  final stats = _OptimizationStats();
  final raf = inputFile.openSync();
  final archive = await PmTilesArchive.fromFile(inputFile);
  final h = archive.header;

  stdout.writeln('[optimize] Source: ${inputFile.path} (${inputFile.lengthSync()} bytes)');

  // ---- Structural preconditions (req. 7: fail loudly, never guess) ----
  if (h.version != 3) {
    _fail('Expected PMTiles version 3, found version ${h.version}.');
  }
  if (h.tileType != TileType.mvt) {
    _fail('Expected MVT tiles, found tile type ${h.tileType}.');
  }
  if (h.tileCompression != Compression.gzip) {
    _fail(
      'Expected gzip tile compression, found ${h.tileCompression}. '
      'This tool only ever reads/writes gzip -- it never introduces '
      'Brotli or Zstd.',
    );
  }
  if (h.internalCompression != Compression.gzip) {
    _fail('Expected gzip internal (directory/metadata) compression, found ${h.internalCompression}.');
  }
  if (h.clustered != Clustered.clustered) {
    _fail('Expected a clustered archive.');
  }

  stdout.writeln(
    '[optimize] Header OK: v${h.version}, MVT, gzip, '
    'zoom ${h.minZoom}-${h.maxZoom}, clustered.',
  );

  // ---- Walk root + leaf directories (req. 8: no assumption about how ----
  // ---- many objects/tiles/leaves exist -- purely discovered). ----
  final leafNodes = <List<pmdir.Entry>>[];
  final rootEntries = archive.root.entries;
  final rootLeafRefs = <int?>[];

  Future<List<pmdir.Entry>> loadLeafEntries(int offset, int length) async {
    final rawBytes = Uint8List(length);
    raf.setPositionSync(h.leafDirectoriesOffset + offset);
    raf.readIntoSync(rawBytes);
    final decompressed = _gunzip(rawBytes);
    return pmdir.Directory.from(decompressed, header: h).entries;
  }

  for (final e in rootEntries) {
    if (!e.isLeaf) {
      rootLeafRefs.add(null);
      continue;
    }
    final entries = await loadLeafEntries(e.offset, e.length);
    for (final sub in entries) {
      if (sub.isLeaf) {
        _fail(
          'Found a 3-level directory (a leaf entry pointing to another '
          'leaf) -- this tool only understands the 2-level root+leaf shape '
          'this archive has always used. Refusing to guess how to handle '
          'deeper nesting.',
        );
      }
    }
    leafNodes.add(entries);
    rootLeafRefs.add(leafNodes.length - 1);
  }
  stdout.writeln(
    '[optimize] Directory: ${rootEntries.length} root entries, '
    '${leafNodes.length} leaf directories (discovered, not assumed).',
  );

  final uniqueOldOffsets = <int>{};
  final oldOffsetToLength = <int, int>{};
  const sampleZooms = {12, 13, 14};
  void trackEntry(pmdir.Entry e) {
    uniqueOldOffsets.add(e.offset);
    oldOffsetToLength[e.offset] = e.length;
    if (e.runLength == 0 || !sampleZooms.contains(e.zxy.z)) return;
    // Track, per requested zoom, whichever real discovered tile has the
    // most bytes -- a proxy for "has real content" without needing to
    // decode anything during this discovery pass.
    final existing = stats.bestSampleByZoom[e.zxy.z];
    if (existing == null || e.length > existing.$4) {
      stats.bestSampleByZoom[e.zxy.z] = (e.zxy.x, e.zxy.y, e.runLength, e.length);
    }
  }

  for (final leaf in leafNodes) {
    for (final e in leaf) {
      trackEntry(e);
    }
  }
  for (final e in rootEntries) {
    if (!e.isLeaf) trackEntry(e);
  }
  final sortedOldOffsets = uniqueOldOffsets.toList()..sort();
  stdout.writeln('[optimize] Unique tiles to process: ${sortedOldOffsets.length} (discovered, not assumed).');

  // ---- Transform every unique tile ----
  final oldOffsetToNewBytes = <int, Uint8List>{};
  var reported = 0;
  for (final oldOffset in sortedOldOffsets) {
    final oldLength = oldOffsetToLength[oldOffset]!;
    final rawBytes = Uint8List(oldLength);
    raf.setPositionSync(h.tileDataOffset + oldOffset);
    raf.readIntoSync(rawBytes);
    final decompressed = _gunzip(rawBytes);

    final strippedMvt = _stripAttributes(decompressed);

    // req. "comprobar IDs y geometrías idénticos" + "eliminar únicamente los
    // 20 atributos": verify this exact tile, right now, deterministically,
    // rather than sampling after the fact -- every tile gets checked, not
    // just a handful.
    _verifyTileTransform(decompressed, strippedMvt, stats);

    final newCompressed = _gzip(strippedMvt);
    oldOffsetToNewBytes[oldOffset] = newCompressed;
    stats.oldTileBytes += oldLength;
    stats.newTileBytes += newCompressed.length;
    stats.tilesProcessed++;
    reported++;
    if (reported % 20000 == 0) {
      stdout.writeln('[optimize]   processed $reported/${sortedOldOffsets.length}...');
    }
  }

  for (final required in keptAttributes) {
    if (!stats.attributesSeen.contains(required)) {
      stdout.writeln(
        '[optimize] NOTE: "$required" is in the keep-list but was never '
        'seen in any tile\'s attribute pool -- not an error (a field can '
        'legitimately be unused in this particular dataset), just '
        'reported for visibility.',
      );
    }
  }

  // ---- Reassemble tile data + directories with new (smaller) sizes ----
  final oldOffsetToNewOffset = <int, int>{};
  var cursor = 0;
  final tileDataOut = BytesBuilder();
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
    final newEntries = leafNodes[i].map((e) {
      return pmdir.Entry(
        tileId: e.tileId,
        runLength: e.runLength,
        offset: oldOffsetToNewOffset[e.offset]!,
        length: oldOffsetToNewBytes[e.offset]!.length,
      );
    }).toList();
    final serialized = _serializeDirectory(newEntries);
    final compressed = _gzip(serialized);
    leafNewOffsetLength[i] = (leafDirsOut.length, compressed.length);
    leafDirsOut.add(compressed);
  }
  final newLeafDirsBytes = leafDirsOut.toBytes();

  final newRootEntries = <pmdir.Entry>[];
  for (var i = 0; i < rootEntries.length; i++) {
    final e = rootEntries[i];
    if (e.isLeaf) {
      final leafIdx = rootLeafRefs[i]!;
      final (newOffset, newLength) = leafNewOffsetLength[leafIdx]!;
      newRootEntries.add(pmdir.Entry(tileId: e.tileId, runLength: 0, offset: newOffset, length: newLength));
    } else {
      newRootEntries.add(pmdir.Entry(
        tileId: e.tileId,
        runLength: e.runLength,
        offset: oldOffsetToNewOffset[e.offset]!,
        length: oldOffsetToNewBytes[e.offset]!.length,
      ));
    }
  }
  final newRootSerialized = _serializeDirectory(newRootEntries);
  final newRootCompressed = _gzip(newRootSerialized);

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
  final tileDataLength = newTileData.length;

  final origHeaderBytes = Uint8List(127);
  raf.setPositionSync(0);
  raf.readIntoSync(origHeaderBytes);
  final newHeader = ByteData.sublistView(origHeaderBytes);
  newHeader.setUint64(0x10, rootLength, Endian.little);
  newHeader.setUint64(0x18, metadataOffset, Endian.little);
  newHeader.setUint64(0x20, metadataLength, Endian.little);
  newHeader.setUint64(0x28, leafDirsOffset, Endian.little);
  newHeader.setUint64(0x30, leafDirsLength, Endian.little);
  newHeader.setUint64(0x38, tileDataOffset, Endian.little);
  newHeader.setUint64(0x40, tileDataLength, Endian.little);

  final out = BytesBuilder();
  out.add(origHeaderBytes);
  out.add(newRootCompressed);
  out.add(metaRaw);
  out.add(newLeafDirsBytes);
  out.add(newTileData);
  final finalBytes = out.toBytes();

  outputFile.writeAsBytesSync(finalBytes);
  raf.closeSync();
  await archive.close();

  final originalSize = inputFile.lengthSync();
  final newSize = finalBytes.length;
  final savedBytes = originalSize - newSize;
  final savedPercent = savedBytes / originalSize * 100;
  final digest = sha256.convert(finalBytes);

  stdout.writeln('');
  stdout.writeln('[optimize] Wrote ${outputFile.path}');
  stdout.writeln('[optimize] Original size: $originalSize bytes (${(originalSize / 1048576).toStringAsFixed(2)} MiB)');
  stdout.writeln('[optimize] New size:      $newSize bytes (${(newSize / 1048576).toStringAsFixed(2)} MiB)');
  stdout.writeln(
    '[optimize] Saved:         $savedBytes bytes (${savedPercent.toStringAsFixed(2)}%)',
  );
  stdout.writeln('[optimize] SHA-256:       $digest');

  await _validateResult(inputFile, outputFile, stats.bestSampleByZoom);

  return stats;
}

/// Compares one tile's decoded original vs. stripped MVT bytes, asserting
/// (per feature, per layer): identical id, identical geometry type,
/// identical geometry command list (byte-for-byte, not just "similar"),
/// and that its surviving attribute set is exactly the intersection of its
/// original attributes with [keptAttributes] -- nothing extra, nothing
/// from [droppedAttributes]. Aborts the whole run immediately (rather than
/// collecting errors) on the first violation, since a single unexpected
/// tile means a structural assumption this tool relies on doesn't hold.
void _verifyTileTransform(
  Uint8List originalMvt,
  Uint8List strippedMvt,
  _OptimizationStats stats,
) {
  final originalTile = raw.VectorTile.fromBuffer(originalMvt);
  final strippedTile = raw.VectorTile.fromBuffer(strippedMvt);
  if (originalTile.layers.length != strippedTile.layers.length) {
    _fail('Layer count changed (${originalTile.layers.length} -> ${strippedTile.layers.length}).');
  }
  for (var li = 0; li < originalTile.layers.length; li++) {
    final ol = originalTile.layers[li];
    final nl = strippedTile.layers[li];
    if (ol.features.length != nl.features.length) {
      _fail('Feature count changed in layer "${ol.name}" (${ol.features.length} -> ${nl.features.length}).');
    }
    for (var fi = 0; fi < ol.features.length; fi++) {
      final of = ol.features[fi];
      final nf = nl.features[fi];
      if (of.id != nf.id) {
        _fail('Feature id changed in layer "${ol.name}" (${of.id} -> ${nf.id}).');
      }
      if (of.type != nf.type) {
        _fail('Geometry type changed for feature ${of.id} in layer "${ol.name}".');
      }
      final og = of.geometry;
      final ng = nf.geometry;
      if (og.length != ng.length) {
        _fail('Geometry command count changed for feature ${of.id} in layer "${ol.name}".');
      }
      for (var i = 0; i < og.length; i++) {
        if (og[i] != ng[i]) {
          _fail('Geometry command $i differs for feature ${of.id} in layer "${ol.name}" -- geometry must be byte-identical.');
        }
      }

      final oldProps = <String>{};
      for (var i = 0; i < of.tags.length; i += 2) {
        oldProps.add(ol.keys[of.tags[i]]);
      }
      final newProps = <String>{};
      for (var i = 0; i < nf.tags.length; i += 2) {
        newProps.add(nl.keys[nf.tags[i]]);
      }
      final expected = oldProps.intersection(keptAttributes);
      if (!setEquals(newProps, expected)) {
        _fail(
          'Feature ${of.id} in layer "${ol.name}" has an unexpected '
          'surviving attribute set. Expected exactly $expected, got $newProps.',
        );
      }
      final leaked = newProps.intersection(droppedAttributes);
      if (leaked.isNotEmpty) {
        _fail('Feature ${of.id} in layer "${ol.name}" still has attribute(s) that must be removed: $leaked.');
      }
      stats.attributesSeen.addAll(oldProps.intersection(keptAttributes));
    }
  }
}

bool setEquals<T>(Set<T> a, Set<T> b) => a.length == b.length && a.containsAll(b);

/// Final, independent re-check: re-opens the freshly written file with the
/// same `pmtiles`/`vector_tile` reader the app itself uses (not anything
/// this script built up internally), and compares it against the original
/// on every axis the task requires: PMTiles version, tile type, tile
/// compression, min/max zoom, bounds, and full metadata JSON equality, plus
/// decoding a representative z12/z13/z14 sample.
Future<void> _validateResult(
  File inputFile,
  File outputFile,
  Map<int, (int, int, int, int)> sampleByZoom,
) async {
  stdout.writeln('');
  stdout.writeln('[optimize] Running independent post-build validation (re-opening with the app\'s own reader)...');

  final original = await PmTilesArchive.fromFile(inputFile);
  final result = await PmTilesArchive.fromFile(outputFile);

  void checkEqual(String label, Object a, Object b) {
    if (a.toString() != b.toString()) {
      _fail('Validation failed: $label differs (original=$a, result=$b).');
    }
    stdout.writeln('[optimize]   OK  $label = $a');
  }

  checkEqual('version', original.version, result.version);
  checkEqual('tileType', original.tileType, result.tileType);
  checkEqual('tileCompression', original.tileCompression, result.tileCompression);
  checkEqual('minZoom', original.minZoom, result.minZoom);
  checkEqual('maxZoom', original.maxZoom, result.maxZoom);
  checkEqual('minPosition (bounds)', original.minPosition, result.minPosition);
  checkEqual('maxPosition (bounds)', original.maxPosition, result.maxPosition);
  checkEqual('centerPosition', original.centerPosition, result.centerPosition);
  checkEqual('numberOfAddressedTiles', original.header.numberOfAddressedTiles, result.header.numberOfAddressedTiles);
  checkEqual('numberOfTileEntries', original.header.numberOfTileEntries, result.header.numberOfTileEntries);
  checkEqual('numberOfTileContents', original.header.numberOfTileContents, result.header.numberOfTileContents);

  final originalMeta = await original.metadata;
  final resultMeta = await result.metadata;
  checkEqual('metadata (full JSON)', jsonEncode(originalMeta), jsonEncode(resultMeta));

  stdout.writeln('[optimize] Decoding the representative z12/z13/z14 sample discovered during processing...');
  var sampleChecked = 0;
  for (final z in [12, 13, 14]) {
    final sample = sampleByZoom[z];
    if (sample == null) {
      stdout.writeln('[optimize]   z$z: no tile was discovered at this zoom in the source archive.');
      continue;
    }
    final (x, y, runLength, _) = sample;
    final tileId = ZXY(z, x, y).toTileId();
    final tile = await result.tile(tileId);
    final bytes = Uint8List.fromList(tile.bytes());
    final vt = raw.VectorTile.fromBuffer(bytes);
    final total = vt.layers.fold<int>(0, (a, l) => a + l.features.length);
    if (total == 0) {
      _fail('Validation failed: sample tile z$z/$x/$y decoded with zero features in the result.');
    }
    stdout.writeln('[optimize]   z$z/$x/$y (run length $runLength): $total feature(s) decoded successfully, OK');
    sampleChecked++;
  }

  stdout.writeln('[optimize] Validation passed ($sampleChecked/3 sampled zoom levels confirmed).');
  await original.close();
  await result.close();
}
