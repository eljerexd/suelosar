import '../sync/sync_entity.dart';
import '../sync/sync_state.dart';
import '../sync/uuid_v4.dart';

class FavoriteSoilFeature implements SyncEntity {
  FavoriteSoilFeature({
    required this.id,
    required this.unitName,
    required this.unitSymbol,
    required this.soilSeries,
    required this.pdfIdentifier,
    String? uuid,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.deletedAt,
    this.syncState = SyncState.pendingUpload,
  }) : uuid = uuid ?? UuidV4.generate(),
       createdAt = (createdAt ?? DateTime.now()).toUtc(),
       updatedAt = (updatedAt ?? createdAt ?? DateTime.now()).toUtc();

  factory FavoriteSoilFeature.fromJson(Map<String, dynamic> json) {
    final rawSeries = json['soilSeries'];
    final createdAt =
        parseSyncDate(json['createdAt']) ?? DateTime.now().toUtc();
    final storedUuid = json['uuid']?.toString() ?? '';
    return FavoriteSoilFeature(
      id: json['id']?.toString() ?? '',
      unitName: json['unitName']?.toString() ?? '',
      unitSymbol: json['unitSymbol']?.toString() ?? '',
      soilSeries: rawSeries is List
          ? rawSeries.map((value) => value.toString()).toList()
          : const <String>[],
      pdfIdentifier: json['pdfIdentifier']?.toString(),
      uuid: UuidV4.isValid(storedUuid) ? storedUuid : UuidV4.generate(),
      createdAt: createdAt,
      updatedAt: parseSyncDate(json['updatedAt']) ?? createdAt,
      deletedAt: parseSyncDate(json['deletedAt']),
      syncState: SyncState.fromJson(json['syncState']),
    );
  }

  static const String storageKey = 'gis.favorite_soil_features';

  final String id;
  final String unitName;
  final String unitSymbol;
  final List<String> soilSeries;
  final String? pdfIdentifier;
  @override
  final String uuid;
  @override
  final DateTime createdAt;
  @override
  final DateTime updatedAt;
  @override
  final DateTime? deletedAt;
  @override
  final SyncState syncState;

  String get dominantSoilSeries =>
      soilSeries.isEmpty ? 'Sin datos' : soilSeries.first;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'unitName': unitName,
      'unitSymbol': unitSymbol,
      'soilSeries': soilSeries,
      'pdfIdentifier': pdfIdentifier,
      'uuid': uuid,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'deletedAt': deletedAt?.toIso8601String(),
      'syncState': syncState.name,
    };
  }
}
