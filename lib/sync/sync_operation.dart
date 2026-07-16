import 'uuid_v4.dart';

enum SyncEntityType { marker, measurement, favorite, settings }

enum SyncOperationType { create, update, delete }

class SyncOperation {
  SyncOperation({
    required this.uuid,
    required this.entityType,
    required this.operationType,
    required this.createdAt,
    required this.retryCount,
    required this.payloadReference,
    String? operationId,
  }) : operationId = operationId ?? UuidV4.generate();

  final String operationId;
  final String uuid;
  final SyncEntityType entityType;
  final SyncOperationType operationType;
  final DateTime createdAt;
  final int retryCount;
  final String payloadReference;

  SyncOperation copyWith({int? retryCount}) => SyncOperation(
    operationId: operationId,
    uuid: uuid,
    entityType: entityType,
    operationType: operationType,
    createdAt: createdAt,
    retryCount: retryCount ?? this.retryCount,
    payloadReference: payloadReference,
  );

  Map<String, Object> toJson() => <String, Object>{
    'operationId': operationId,
    'uuid': uuid,
    'entityType': entityType.name,
    'operationType': operationType.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'retryCount': retryCount,
    'payloadReference': payloadReference,
  };

  factory SyncOperation.fromJson(Map<String, dynamic> json) {
    return SyncOperation(
      operationId: json['operationId']?.toString(),
      uuid: json['uuid']?.toString() ?? '',
      entityType: SyncEntityType.values.firstWhere(
        (value) => value.name == json['entityType'],
      ),
      operationType: SyncOperationType.values.firstWhere(
        (value) => value.name == json['operationType'],
      ),
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      retryCount: (json['retryCount'] as num?)?.toInt() ?? 0,
      payloadReference: json['payloadReference']?.toString() ?? '',
    );
  }
}
