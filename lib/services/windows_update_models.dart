typedef InstalledVersionReader = Future<String> Function();
typedef InstallerStarter = Future<void> Function(String path);

class SemanticVersion implements Comparable<SemanticVersion> {
  const SemanticVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease,
    this.buildMetadata,
  });

  final int major;
  final int minor;
  final int patch;
  final String? preRelease;
  final String? buildMetadata;

  static final RegExp _pattern = RegExp(
    r'^(?:v)?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    caseSensitive: false,
  );

  static SemanticVersion? tryParse(String value) {
    var normalized = value.trim();
    if (normalized.startsWith('v') || normalized.startsWith('V')) {
      normalized = normalized.substring(1);
    }
    final match = _pattern.firstMatch(normalized);
    if (match == null) return null;
    final preRelease = match.group(4);
    if (preRelease != null &&
        preRelease
            .split('.')
            .any(
              (identifier) =>
                  identifier.length > 1 &&
                  identifier.startsWith('0') &&
                  int.tryParse(identifier) != null,
            )) {
      return null;
    }
    return SemanticVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      preRelease: preRelease,
      buildMetadata: match.group(5),
    );
  }

  bool get isStable => preRelease == null;

  @override
  int compareTo(SemanticVersion other) {
    final core = major.compareTo(other.major);
    if (core != 0) return core;
    final minorComparison = minor.compareTo(other.minor);
    if (minorComparison != 0) return minorComparison;
    final patchComparison = patch.compareTo(other.patch);
    if (patchComparison != 0) return patchComparison;

    final left = preRelease?.split('.');
    final right = other.preRelease?.split('.');
    if (left == null) return right == null ? 0 : 1;
    if (right == null) return -1;
    for (var index = 0; index < left.length && index < right.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a == b) continue;
      final aNumber = int.tryParse(a);
      final bNumber = int.tryParse(b);
      if (aNumber != null && bNumber != null) return aNumber.compareTo(bNumber);
      if (aNumber != null) return -1;
      if (bNumber != null) return 1;
      final lexical = a.compareTo(b);
      if (lexical != 0) return lexical;
    }
    return left.length.compareTo(right.length);
  }

  @override
  String toString() =>
      '$major.$minor.$patch'
      '${preRelease == null ? '' : '-$preRelease'}'
      '${buildMetadata == null ? '' : '+$buildMetadata'}';
}

enum WindowsUpdateStatus {
  updateAvailable,
  upToDate,
  unsupportedPlatform,
  noStableRelease,
  releaseUnavailable,
  invalidRelease,
  installerAssetMissing,
  checksumUnavailable,
  failed,
}

enum WindowsUpdateErrorCode {
  unsupportedPlatform,
  networkUnavailable,
  timeout,
  rateLimited,
  httpError,
  invalidJson,
  invalidRelease,
  noStableRelease,
  installerAssetMissing,
  checksumUnavailable,
  downloadInProgress,
  downloadCancelled,
  downloadFailed,
  sizeMismatch,
  checksumMismatch,
  installerNotVerified,
  installerLifecycleUnavailable,
  launchFailed,
}

class WindowsUpdateError {
  const WindowsUpdateError({required this.code, required this.message});

  final WindowsUpdateErrorCode code;
  final String message;
}

class WindowsReleaseAsset {
  const WindowsReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    this.digest,
    this.id,
  });

  final String name;
  final Uri downloadUrl;
  final int size;
  final String? digest;
  final int? id;
}

class WindowsReleaseInfo {
  const WindowsReleaseInfo({
    required this.tag,
    required this.version,
    required this.name,
    required this.description,
    required this.publishedAt,
    required this.assets,
    required this.htmlUrl,
  });

  final String tag;
  final SemanticVersion version;
  final String name;
  final String description;
  final DateTime publishedAt;
  final List<WindowsReleaseAsset> assets;
  final Uri htmlUrl;
}

class WindowsUpdateCheckResult {
  const WindowsUpdateCheckResult({
    required this.status,
    this.installedVersion,
    this.release,
    this.installer,
    this.sha256,
    this.error,
  });

  final WindowsUpdateStatus status;
  final SemanticVersion? installedVersion;
  final WindowsReleaseInfo? release;
  final WindowsReleaseAsset? installer;
  final String? sha256;
  final WindowsUpdateError? error;

  bool get updateAvailable =>
      installedVersion != null &&
      release != null &&
      release!.version.compareTo(installedVersion!) > 0;
  bool get canDownload =>
      status == WindowsUpdateStatus.updateAvailable &&
      updateAvailable &&
      installer != null &&
      sha256 != null;
}

class WindowsUpdateProgress {
  const WindowsUpdateProgress({required this.downloadedBytes, this.totalBytes});

  final int downloadedBytes;
  final int? totalBytes;

  double? get fraction => totalBytes == null || totalBytes! <= 0
      ? null
      : (downloadedBytes / totalBytes!).clamp(0, 1).toDouble();
}

enum WindowsUpdateOperationStatus {
  succeeded,
  unsupportedPlatform,
  cancelled,
  failed,
  lifecycleUnavailable,
}

class WindowsUpdateOperationResult {
  const WindowsUpdateOperationResult({
    required this.status,
    this.installerPath,
    this.sha256,
    this.error,
  });

  final WindowsUpdateOperationStatus status;
  final String? installerPath;
  final String? sha256;
  final WindowsUpdateError? error;

  bool get succeeded => status == WindowsUpdateOperationStatus.succeeded;
}
