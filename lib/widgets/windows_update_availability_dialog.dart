import 'package:flutter/material.dart';

import '../services/windows_update_models.dart';
import '../services/windows_update_preview_mode.dart';

enum WindowsUpdateDialogAction { later, download }

Future<WindowsUpdateDialogAction?> showWindowsUpdateAvailabilityDialog(
  BuildContext context, {
  required WindowsReleaseInfo release,
  required String? installedVersion,
  required WindowsUpdateCheckResult? verifiedCheck,
  required bool isPreview,
  required String? downloadUnavailableReason,
  Listenable? releaseUpdates,
  WindowsReleaseInfo? Function()? latestRelease,
  bool Function()? releaseNotesAreFromCache,
}) => showDialog<WindowsUpdateDialogAction>(
  context: context,
  builder: (_) {
    Widget buildDialog(WindowsReleaseInfo displayedRelease, bool fromCache) =>
        WindowsUpdateAvailabilityDialog(
          release: displayedRelease,
          installedVersion: installedVersion,
          verifiedCheck: verifiedCheck,
          isPreview: isPreview,
          downloadUnavailableReason: downloadUnavailableReason,
          releaseNotesAreFromCache: fromCache,
        );

    if (releaseUpdates == null) return buildDialog(release, false);
    return AnimatedBuilder(
      animation: releaseUpdates,
      builder: (context, _) {
        final latest = latestRelease?.call();
        final displayedRelease =
            latest != null && latest.version.compareTo(release.version) == 0
            ? latest
            : release;
        return buildDialog(
          displayedRelease,
          releaseNotesAreFromCache?.call() ?? false,
        );
      },
    );
  },
  animationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
);

class WindowsUpdateAvailabilityDialog extends StatelessWidget {
  const WindowsUpdateAvailabilityDialog({
    required this.release,
    required this.installedVersion,
    required this.verifiedCheck,
    required this.isPreview,
    required this.downloadUnavailableReason,
    this.releaseNotesAreFromCache = false,
    super.key,
  });

  final WindowsReleaseInfo release;
  final String? installedVersion;
  final WindowsUpdateCheckResult? verifiedCheck;
  final bool isPreview;
  final String? downloadUnavailableReason;
  final bool releaseNotesAreFromCache;

  bool get _previewEnabled => isPreview && updatePreviewModeEnabled;

  bool get _canStartDownload =>
      _previewEnabled || verifiedCheck?.canDownload == true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final notes = release.description.trim();
    return Dialog(
      key: const ValueKey('windows-update-availability-dialog'),
      backgroundColor: const Color(0xFFFAF8F0),
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFDCDDD2)),
      ),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          key: const ValueKey('update-dialog-surface'),
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: const BoxDecoration(
                        color: Color(0xFFE8EFE2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.system_update_alt_rounded,
                        color: colors.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Nueva versión disponible',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: const Color(0xFF3F4038),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _VersionBadge(version: release.version.toDisplayString()),
                  ],
                ),
                const SizedBox(height: 20),
                _VersionLine(
                  label: 'Versión instalada',
                  version: formatWindowsUpdateVersion(
                    installedVersion ?? 'No disponible',
                  ),
                ),
                const SizedBox(height: 8),
                _VersionLine(
                  label: 'Nueva versión',
                  version: release.version.toDisplayString(),
                ),
                const SizedBox(height: 16),
                if (notes.isEmpty)
                  Text(
                    'Este release no incluye notas.',
                    key: const ValueKey('update-dialog-empty-release-notes'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF6B6D64),
                      fontStyle: FontStyle.italic,
                    ),
                  )
                else
                  _ReleaseNotes(text: notes),
                if (releaseNotesAreFromCache) ...[
                  const SizedBox(height: 10),
                  Row(
                    key: const ValueKey('update-dialog-cached-release-note'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.history_rounded,
                        size: 16,
                        color: Color(0xFF777B6F),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          'Información previamente obtenida; se actualizará al conectarse.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF686B5D),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 22),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      height: 42,
                      child: OutlinedButton(
                        key: const ValueKey('update-dialog-later'),
                        onPressed: () => Navigator.of(
                          context,
                        ).pop(WindowsUpdateDialogAction.later),
                        style: _secondaryButtonStyle,
                        child: const Text('Más tarde'),
                      ),
                    ),
                    SizedBox(
                      height: 42,
                      child: FilledButton.icon(
                        key: const ValueKey('update-dialog-download'),
                        onPressed: _canStartDownload
                            ? () => Navigator.of(
                                context,
                              ).pop(WindowsUpdateDialogAction.download)
                            : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF687654),
                          disabledBackgroundColor: const Color(0xFFE7E7E0),
                          foregroundColor: Colors.white,
                          disabledForegroundColor: const Color(0xFF777B6F),
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        icon: const Icon(Icons.download_rounded, size: 18),
                        label: const Text('Descargar'),
                      ),
                    ),
                  ],
                ),
                if (!_canStartDownload) ...[
                  const SizedBox(height: 10),
                  Text(
                    _downloadUnavailableMessage,
                    key: const ValueKey('update-dialog-download-message'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF686B5D),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _downloadUnavailableMessage {
    if (verifiedCheck?.status == WindowsUpdateStatus.installerAssetMissing) {
      return 'Este release no incluye un instalador de Windows.';
    }
    if (verifiedCheck?.status == WindowsUpdateStatus.checksumUnavailable) {
      return 'No hay un SHA-256 verificable para este instalador.';
    }
    return downloadUnavailableReason ??
        'No se pudo verificar un instalador para esta versión.';
  }

  static final _secondaryButtonStyle = OutlinedButton.styleFrom(
    foregroundColor: const Color(0xFF59634C),
    backgroundColor: const Color(0xFFFAF8F0),
    side: const BorderSide(color: Color(0xFF9AA48C)),
    shape: const StadiumBorder(),
    padding: const EdgeInsets.symmetric(horizontal: 16),
  );
}

class _VersionBadge extends StatelessWidget {
  const _VersionBadge({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('update-dialog-version-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFE8EFE2),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFD3DFCA)),
    ),
    child: Text(
      version,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: const Color(0xFF4E693A),
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: const Color(0xFF5A5B52),
      height: 1.4,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final height = painter.height.clamp(0.0, 220.0).toDouble();
        return SizedBox(
          height: height,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              key: const ValueKey('update-dialog-release-notes'),
              style: style,
            ),
          ),
        );
      },
    );
  }
}

class _VersionLine extends StatelessWidget {
  const _VersionLine({required this.label, required this.version});

  final String label;
  final String version;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF66685E)),
        ),
      ),
      Text(
        version,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: const Color(0xFF41443B),
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}
