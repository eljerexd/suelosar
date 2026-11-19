typedef InstalledVersionReader = Future<String> Function();
typedef InstallerStarter = Future<void> Function(String path);
typedef InstallerLifecycleStarter = Future<void> Function(
  String installerPath,
  String sha256,
  String version,
  String updateDirectory,
);

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

  String toDisplayString() =>
      '$major.$minor.$patch'
      '${preRelease == null ? '' : '-$preRelease'}';

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

/// A stable semantic version plus the optional numeric Flutter build number.
///
/// SemVer ignores build metadata for precedence. Windows releases use it as a
/// separately ordered package build, so update comparisons must go through
/// [compareRemoteToInstalled] instead of [SemanticVersion.compareTo].
class UpdateVersion {
  const UpdateVersion({required this.semanticVersion, this.buildNumber});

  final SemanticVersion semanticVersion;
  final int? buildNumber;

  bool get isStable => semanticVersion.isStable;

  String get assetVersion => toString();

  static final RegExp _numericBuildPattern = RegExp(r'^(0|[1-9]\d*)$');
  static const int _maxWindowsBuildNumber = 65535;

  static UpdateVersion? tryParse(String value) {
    final semantic = SemanticVersion.tryParse(value);
    if (semantic == null) return null;
    final metadata = semantic.buildMetadata;
    if (metadata == null) {
      return UpdateVersion(semanticVersion: semantic);
    }
    if (!_numericBuildPattern.hasMatch(metadata)) return null;
    final build = int.tryParse(metadata);
    if (build == null || build > _maxWindowsBuildNumber) return null;
    return UpdateVersion(semanticVersion: semantic, buildNumber: build);
  }

  /// Composes the two Windows fields returned by package_info_plus.
  ///
  /// On Windows, package_info_plus splits the executable ProductVersion at
  /// `+`: `version=1.8.0`, `buildNumber=25` for `1.8.0+25`.
  static UpdateVersion? fromPackageInfo({
    required String version,
    required String buildNumber,
  }) {
    final semantic = SemanticVersion.tryParse(version.trim());
    if (semantic == null) return null;
    final fieldBuild = buildNumber.trim();
    final metadata = semantic.buildMetadata;

    int? parsedBuild;
    if (fieldBuild.isNotEmpty) {
      if (!_numericBuildPattern.hasMatch(fieldBuild)) return null;
      parsedBuild = int.tryParse(fieldBuild);
      if (parsedBuild == null || parsedBuild > _maxWindowsBuildNumber) {
        return null;
      }
    }

    int? metadataBuild;
    if (metadata != null) {
      if (!_numericBuildPattern.hasMatch(metadata)) return null;
      metadataBuild = int.tryParse(metadata);
      if (metadataBuild == null || metadataBuild > _maxWindowsBuildNumber) {
        return null;
      }
    }
    if (parsedBuild != null &&
        metadataBuild != null &&
        parsedBuild != metadataBuild) {
      return null;
    }
    return UpdateVersion(
      semanticVersion: semantic,
      buildNumber: parsedBuild ?? metadataBuild,
    );
  }

  /// Returns remote-versus-installed precedence, or null if it is unsafe to
  /// compare equal semantic versions because the installed build is unknown.
  /// Legacy remote tags without `+build` retain their historical
  /// semantic-version-only behavior and are never treated as a newer build.
  static int? compareRemoteToInstalled({
    required UpdateVersion remote,
    required UpdateVersion installed,
  }) {
    final semantic = remote.semanticVersion.compareTo(
      installed.semanticVersion,
    );
    if (semantic != 0) return semantic;
    if (remote.buildNumber == null) return 0;
    if (installed.buildNumber == null) return null;
    return remote.buildNumber!.compareTo(installed.buildNumber!);
  }

  String toDisplayString() => toString();

  @override
  String toString() {
    final core = semanticVersion.toDisplayString();
    return buildNumber == null ? core : '$core+$buildNumber';
  }
}

String formatWindowsUpdateVersion(String value) =>
    UpdateVersion.tryParse(value)?.toDisplayString() ?? value;

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

  UpdateVersion get updateVersion =>
      UpdateVersion.tryParse(version.toString())!;
}

class WindowsUpdateCheckResult {
  const WindowsUpdateCheckResult({
    required this.status,
    this.installedVersion,
    this.release,
    this.installer,
    this.sha256,
    this.differentialPackage,
    this.differentialPackageSha256,
    this.differentialManifest,
    this.differentialManifestJson,
    this.differentialManifestSha256,
    this.error,
  });

  final WindowsUpdateStatus status;
  final SemanticVersion? installedVersion;
  final WindowsReleaseInfo? release;
  final WindowsReleaseAsset? installer;
  final String? sha256;
  final WindowsReleaseAsset? differentialPackage;
  final String? differentialPackageSha256;
  final Map<String, dynamic>? differentialManifest;
  final String? differentialManifestJson;
  final String? differentialManifestSha256;
  final WindowsUpdateError? error;

  bool get usesDifferentialPackage =>
      differentialPackage != null &&
      differentialPackageSha256 != null &&
      differentialManifest != null &&
      differentialManifestSha256 != null;

  WindowsReleaseAsset? get downloadAsset =>
      usesDifferentialPackage ? differentialPackage : installer;

  String? get downloadSha256 =>
      usesDifferentialPackage ? differentialPackageSha256 : sha256;

  UpdateVersion? get installedUpdateVersion {
    final installed = installedVersion;
    if (installed == null) return null;
    return UpdateVersion.tryParse(installed.toString());
  }

  int? get remoteVersionComparison {
    final installed = installedUpdateVersion;
    final release = this.release;
    if (installed == null || release == null) return null;
    return UpdateVersion.compareRemoteToInstalled(
      remote: release.updateVersion,
      installed: installed,
    );
  }

  bool get updateAvailable =>
      remoteVersionComparison != null && remoteVersionComparison! > 0;
  bool get canDownload =>
      status == WindowsUpdateStatus.updateAvailable &&
      updateAvailable &&
      downloadAsset != null &&
      downloadSha256 != null;
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
    this.differential = false,
    this.error,
  });

  final WindowsUpdateOperationStatus status;
  final String? installerPath;
  final String? sha256;
  final bool differential;
  final WindowsUpdateError? error;

  bool get succeeded => status == WindowsUpdateOperationStatus.succeeded;
}
