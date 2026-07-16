class SupabaseSyncConfig {
  const SupabaseSyncConfig({required this.url, required this.publishableKey});

  static const String _url = String.fromEnvironment('SUPABASE_URL');
  static const String _publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );
  static const String _legacyAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
  );

  final String url;
  final String publishableKey;

  bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;

  factory SupabaseSyncConfig.fromEnvironment() {
    return SupabaseSyncConfig(
      url: _url.trim(),
      publishableKey:
          (_publishableKey.isNotEmpty ? _publishableKey : _legacyAnonKey)
              .trim(),
    );
  }
}
