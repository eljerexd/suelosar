import 'sync_operation.dart';

class PreparedSyncUpload {
  const PreparedSyncUpload({required this.operation, required this.payload});

  final SyncOperation operation;
  final Map<String, Object?> payload;
}

class SyncDownloadRequest {
  const SyncDownloadRequest({this.cursor, this.limit = 100});

  final String? cursor;
  final int limit;
}

class SyncDownloadBatch {
  const SyncDownloadBatch({required this.changes, required this.nextCursor});

  final List<Map<String, Object?>> changes;
  final String? nextCursor;
}

/// Future cloud implementations (for example Supabase) live behind this
/// boundary. Phase 2 intentionally provides no implementation and SyncEngine
/// never invokes a backend adapter.
abstract interface class SyncBackendAdapter {
  Future<void> upload(List<PreparedSyncUpload> batch);

  Future<SyncDownloadBatch> download(SyncDownloadRequest request);
}
