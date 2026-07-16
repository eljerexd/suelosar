enum SyncState {
  local,
  pendingUpload,
  synced,
  conflict;

  static SyncState fromJson(Object? value) {
    return values.firstWhere(
      (state) => state.name == value,
      orElse: () => local,
    );
  }
}
