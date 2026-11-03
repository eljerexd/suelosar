import 'dart:async';

import 'package:flutter/material.dart';

import '../services/windows_update_indicator_controller.dart';
import '../services/windows_update_models.dart';

enum WindowsUpdatePopoverState {
  checking,
  upToDate,
  error,
  previewDownloadDisabled,
  downloading,
  cancellingDownload,
  downloadCompleted,
  downloadCancelled,
  downloadFailed,
  preparingInstall,
  waitingForApplicationShutdown,
  installationFailed,
}

class WindowsUpdateStatusPopover extends StatelessWidget {
  const WindowsUpdateStatusPopover({
    required this.state,
    required this.installedVersion,
    required this.reduceAnimations,
    this.anchorX = 26,
    required this.onCheck,
    super.key,
    this.downloadProgress,
    this.downloadSpeedBytesPerSecond,
    this.downloadErrorMessage,
    this.downloadVersion,
    this.isPreviewDownload = false,
    this.onCancelDownload,
    this.onDismissDownload,
    this.onInstallUpdate,
    this.installEnabled = false,
    this.autofocus = true,
  });

  final WindowsUpdatePopoverState state;
  final String? installedVersion;
  final bool reduceAnimations;
  final double anchorX;
  final VoidCallback onCheck;
  final WindowsUpdateProgress? downloadProgress;
  final double? downloadSpeedBytesPerSecond;
  final String? downloadErrorMessage;
  final String? downloadVersion;
  final bool isPreviewDownload;
  final VoidCallback? onCancelDownload;
  final VoidCallback? onDismissDownload;
  final VoidCallback? onInstallUpdate;
  final bool installEnabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presentation = _presentation(state);
    return Focus(
      autofocus: autofocus,
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(left: anchorX - 8),
              child: const _PopoverAnchor(),
            ),
            AnimatedSize(
              duration: reduceAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: Container(
                key: const ValueKey('windows-update-status-popover'),
                constraints: const BoxConstraints(maxWidth: 340),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFAF8F0),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFDCDDD2)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x263F4638),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: AnimatedSwitcher(
                  duration: reduceAnimations
                      ? Duration.zero
                      : const Duration(milliseconds: 160),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: _content(theme, presentation),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(ThemeData theme, _PopoverPresentation presentation) {
    if (_isDownloadState) return _downloadContent(theme);
    final isUpToDate = state == WindowsUpdatePopoverState.upToDate;
    final isChecking = state == WindowsUpdatePopoverState.checking;
    return Column(
      key: ValueKey(state),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: presentation.iconSurface,
                shape: BoxShape.circle,
              ),
              child: isChecking && !reduceAnimations
                  ? SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: presentation.accent,
                      ),
                    )
                  : Icon(
                      presentation.icon,
                      size: 18,
                      color: presentation.accent,
                    ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    presentation.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: const Color(0xFF41443B),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (presentation.subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      presentation.subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF66685E),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (isUpToDate) ...[
          const Padding(
            padding: EdgeInsets.only(top: 13),
            child: Divider(height: 1, color: Color(0xFFE3E2D9)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 11),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Versión instalada',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF66685E),
                    ),
                  ),
                ),
                Text(
                  formatWindowsUpdateVersion(installedVersion ?? '—'),
                  key: const ValueKey('update-installed-version'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF41443B),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton.icon(
                key: const ValueKey('update-popover-check'),
                onPressed: onCheck,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('Buscar actualizaciones'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF4E693A),
                  backgroundColor: const Color(0xFFE8EFE2),
                  side: const BorderSide(color: Color(0xFFD3DFCA)),
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ),
        ],
        if (state == WindowsUpdatePopoverState.error) ...[
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton.icon(
                key: const ValueKey('update-popover-retry'),
                onPressed: onCheck,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('Reintentar'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF59634C),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  bool get _isDownloadState => switch (state) {
    WindowsUpdatePopoverState.downloading ||
    WindowsUpdatePopoverState.cancellingDownload ||
    WindowsUpdatePopoverState.downloadCompleted ||
    WindowsUpdatePopoverState.downloadCancelled ||
    WindowsUpdatePopoverState.downloadFailed => true,
    WindowsUpdatePopoverState.preparingInstall ||
    WindowsUpdatePopoverState.waitingForApplicationShutdown ||
    WindowsUpdatePopoverState.installationFailed => true,
    _ => false,
  };

  Widget _downloadContent(ThemeData theme) {
    final isActive = state == WindowsUpdatePopoverState.downloading;
    final isCancelling = state == WindowsUpdatePopoverState.cancellingDownload;
    final isPreparingInstall =
        state == WindowsUpdatePopoverState.preparingInstall;
    final isWaitingForShutdown =
        state == WindowsUpdatePopoverState.waitingForApplicationShutdown;
    final isInstallationFailed =
        state == WindowsUpdatePopoverState.installationFailed;
    final fraction = downloadProgress?.fraction;
    final progressText = fraction == null
        ? 'Preparando descarga...'
        : '${(fraction * 100).round()}%';
    final byteLabel = downloadProgress == null
        ? null
        : '${_formatMb(downloadProgress!.downloadedBytes)} MB'
              '${downloadProgress!.totalBytes == null ? '' : ' de ${_formatMb(downloadProgress!.totalBytes!)} MB'}';
    final title = switch (state) {
      WindowsUpdatePopoverState.downloading => 'Descargando SuelosAR',
      WindowsUpdatePopoverState.cancellingDownload => 'Cancelando descarga',
      WindowsUpdatePopoverState.downloadCompleted => 'Descarga completada',
      WindowsUpdatePopoverState.downloadCancelled => 'Descarga cancelada',
      WindowsUpdatePopoverState.downloadFailed => 'Falló la descarga',
      WindowsUpdatePopoverState.preparingInstall => 'Preparando actualización',
      WindowsUpdatePopoverState.waitingForApplicationShutdown =>
        'Cerrando SuelosAR',
      WindowsUpdatePopoverState.installationFailed =>
        'No se pudo iniciar la instalación',
      _ => '',
    };
    final subtitle = switch (state) {
      WindowsUpdatePopoverState.downloading => 'Descargando actualización...',
      WindowsUpdatePopoverState.cancellingDownload => 'Cancelando descarga...',
      WindowsUpdatePopoverState.downloadCompleted =>
        isPreviewDownload
            ? 'Demostración completada; no se creó ningún archivo.'
            : 'El instalador se descargó y verificó.',
      WindowsUpdatePopoverState.downloadCancelled => 'No se instaló nada.',
      WindowsUpdatePopoverState.downloadFailed =>
        downloadErrorMessage ?? 'No se pudo completar la descarga.',
      WindowsUpdatePopoverState.preparingInstall =>
        'Verificando el instalador y preparando Windows...',
      WindowsUpdatePopoverState.waitingForApplicationShutdown =>
        'SuelosAR se cerrará para continuar con el instalador.',
      WindowsUpdatePopoverState.installationFailed =>
        downloadErrorMessage ?? 'La actualización no se inició.',
      _ => null,
    };

    return Column(
      key: ValueKey(state),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFFE2EBDD),
                shape: BoxShape.circle,
              ),
              child: Icon(
                state == WindowsUpdatePopoverState.downloadCompleted
                    ? Icons.check_rounded
                    : isPreparingInstall || isWaitingForShutdown
                    ? Icons.hourglass_top_rounded
                    : state == WindowsUpdatePopoverState.downloadFailed
                    ? Icons.error_outline_rounded
                    : Icons.download_rounded,
                size: 18,
                color: const Color(0xFF547A3A),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: const Color(0xFF41443B),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (downloadVersion != null)
                    Text(
                      'Versión ${formatWindowsUpdateVersion(downloadVersion!)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF66685E),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (isPreparingInstall || isWaitingForShutdown) ...[
          const SizedBox(height: 14),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF5A5B52),
            ),
          ),
          const SizedBox(height: 9),
          const LinearProgressIndicator(
            minHeight: 7,
            backgroundColor: Color(0xFFE6E7DE),
            color: Color(0xFF71835B),
          ),
        ] else if (isActive || isCancelling) ...[
          const SizedBox(height: 14),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF5A5B52),
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              key: const ValueKey('windows-update-download-progress'),
              value: isCancelling ? fraction : fraction,
              minHeight: 8,
              backgroundColor: const Color(0xFFE6E7DE),
              color: const Color(0xFF71835B),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                progressText,
                key: const ValueKey('windows-update-download-percent'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF41443B),
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (downloadSpeedBytesPerSecond != null &&
                  downloadSpeedBytesPerSecond! > 0)
                SizedBox(
                  width: 88,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${_formatMb(downloadSpeedBytesPerSecond!)} MB/s',
                      key: const ValueKey('windows-update-download-speed'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF66685E),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (byteLabel != null) ...[
            const SizedBox(height: 3),
            Text(
              byteLabel,
              key: const ValueKey('windows-update-download-bytes'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF66685E),
              ),
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              key: const ValueKey('windows-update-download-cancel'),
              onPressed: isActive ? onCancelDownload : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF59634C),
                side: const BorderSide(color: Color(0xFF9AA48C)),
                shape: const StadiumBorder(),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(isCancelling ? 'Cancelando...' : 'Cancelar descarga'),
            ),
          ),
        ] else ...[
          const SizedBox(height: 8),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF66685E),
            ),
          ),
          if (state == WindowsUpdatePopoverState.downloadCompleted &&
              !isPreviewDownload) ...[
            if (!installEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'La instalación automática está pendiente de validación en Windows.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF777B6F),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  key: const ValueKey('windows-update-download-dismiss'),
                  onPressed: onDismissDownload,
                  child: const Text('Cerrar'),
                ),
                FilledButton.icon(
                  key: const ValueKey('windows-update-install'),
                  onPressed: installEnabled ? onInstallUpdate : null,
                  icon: const Icon(Icons.restart_alt_rounded, size: 17),
                  label: const Text('Actualizar y reiniciar'),
                ),
              ],
            ),
          ] else if (isInstallationFailed) ...[
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  key: const ValueKey('windows-update-download-dismiss'),
                  onPressed: onDismissDownload,
                  child: const Text('Cerrar'),
                ),
                if (installEnabled && onInstallUpdate != null) ...[
                  FilledButton.icon(
                    key: const ValueKey('windows-update-install-retry'),
                    onPressed: onInstallUpdate,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: const Text('Reintentar'),
                  ),
                ],
              ],
            ),
          ] else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('windows-update-download-dismiss'),
                onPressed: onDismissDownload,
                child: const Text('Cerrar'),
              ),
            ),
        ],
      ],
    );
  }

  String _formatMb(num bytes) =>
      (bytes / 1000000).toStringAsFixed(1).replaceAll('.', ',');

  _PopoverPresentation _presentation(
    WindowsUpdatePopoverState state,
  ) => switch (state) {
    WindowsUpdatePopoverState.checking => const _PopoverPresentation(
      title: 'Buscando actualizaciones...',
      icon: Icons.refresh_rounded,
      accent: Color(0xFF687654),
      iconSurface: Color(0xFFECEBE3),
    ),
    WindowsUpdatePopoverState.upToDate => const _PopoverPresentation(
      title: 'Ya tenés la última versión',
      subtitle: 'SuelosAR está actualizado.',
      icon: Icons.check_circle_outline_rounded,
      accent: Color(0xFF547A3A),
      iconSurface: Color(0xFFE2EBDD),
    ),
    WindowsUpdatePopoverState.error => const _PopoverPresentation(
      title: 'No se pudo comprobar si hay actualizaciones.',
      icon: Icons.cloud_off_outlined,
      accent: Color(0xFF777B6F),
      iconSurface: Color(0xFFE9E8E1),
    ),
    WindowsUpdatePopoverState.previewDownloadDisabled =>
      const _PopoverPresentation(
        title: 'Vista previa: descarga desactivada.',
        icon: Icons.cloud_off_outlined,
        accent: Color(0xFF777B6F),
        iconSurface: Color(0xFFE9E8E1),
      ),
    WindowsUpdatePopoverState.downloading => const _PopoverPresentation(
      title: 'Descargando SuelosAR',
      icon: Icons.download_rounded,
      accent: Color(0xFF547A3A),
      iconSurface: Color(0xFFE2EBDD),
    ),
    WindowsUpdatePopoverState.cancellingDownload => const _PopoverPresentation(
      title: 'Cancelando descarga',
      icon: Icons.download_rounded,
      accent: Color(0xFF547A3A),
      iconSurface: Color(0xFFE2EBDD),
    ),
    WindowsUpdatePopoverState.downloadCompleted => const _PopoverPresentation(
      title: 'Descarga completada',
      icon: Icons.check_rounded,
      accent: Color(0xFF547A3A),
      iconSurface: Color(0xFFE2EBDD),
    ),
    WindowsUpdatePopoverState.downloadCancelled => const _PopoverPresentation(
      title: 'Descarga cancelada',
      icon: Icons.close_rounded,
      accent: Color(0xFF777B6F),
      iconSurface: Color(0xFFE9E8E1),
    ),
    WindowsUpdatePopoverState.downloadFailed => const _PopoverPresentation(
      title: 'Falló la descarga',
      icon: Icons.error_outline_rounded,
      accent: Color(0xFF777B6F),
      iconSurface: Color(0xFFE9E8E1),
    ),
    WindowsUpdatePopoverState.preparingInstall => const _PopoverPresentation(
      title: 'Preparando actualización',
      icon: Icons.hourglass_top_rounded,
      accent: Color(0xFF547A3A),
      iconSurface: Color(0xFFE2EBDD),
    ),
    WindowsUpdatePopoverState.waitingForApplicationShutdown =>
      const _PopoverPresentation(
        title: 'Cerrando SuelosAR',
        icon: Icons.hourglass_top_rounded,
        accent: Color(0xFF547A3A),
        iconSurface: Color(0xFFE2EBDD),
      ),
    WindowsUpdatePopoverState.installationFailed => const _PopoverPresentation(
      title: 'No se pudo iniciar la instalación',
      icon: Icons.error_outline_rounded,
      accent: Color(0xFF777B6F),
      iconSurface: Color(0xFFE9E8E1),
    ),
  };
}

class WindowsUpdateDownloadPopupHost extends StatelessWidget {
  const WindowsUpdateDownloadPopupHost({
    required this.controller,
    required this.indicatorLink,
    required this.child,
    super.key,
  });

  final WindowsUpdateIndicatorController controller;
  final LayerLink indicatorLink;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: child,
    builder: (context, app) {
      if (!controller.hasDownloadPopup || !controller.isDownloadPopupExpanded) {
        return app!;
      }
      final popupState = switch (controller.downloadState) {
        WindowsUpdateDownloadState.downloading =>
          WindowsUpdatePopoverState.downloading,
        WindowsUpdateDownloadState.cancelling =>
          WindowsUpdatePopoverState.cancellingDownload,
        WindowsUpdateDownloadState.completed =>
          WindowsUpdatePopoverState.downloadCompleted,
        WindowsUpdateDownloadState.cancelled =>
          WindowsUpdatePopoverState.downloadCancelled,
        WindowsUpdateDownloadState.failed =>
          WindowsUpdatePopoverState.downloadFailed,
        WindowsUpdateDownloadState.preparingInstall =>
          WindowsUpdatePopoverState.preparingInstall,
        WindowsUpdateDownloadState.waitingForApplicationShutdown =>
          WindowsUpdatePopoverState.waitingForApplicationShutdown,
        WindowsUpdateDownloadState.installationFailed =>
          WindowsUpdatePopoverState.installationFailed,
        WindowsUpdateDownloadState.idle => WindowsUpdatePopoverState.checking,
      };
      final viewport = MediaQuery.sizeOf(context);
      final maxWidth = (viewport.width - 32).clamp(0.0, 340.0).toDouble();
      final maxHeight = (viewport.height - 80).clamp(0.0, 720.0).toDouble();
      return Stack(
        clipBehavior: Clip.none,
        children: [
          app!,
          Positioned.fill(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CompositedTransformFollower(
                  link: indicatorLink,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomLeft,
                  followerAnchor: Alignment.topLeft,
                  offset: const Offset(0, 3),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: maxWidth,
                      maxHeight: maxHeight,
                    ),
                    child: SingleChildScrollView(
                      child: WindowsUpdateStatusPopover(
                        state: popupState,
                        installedVersion: null,
                        reduceAnimations: MediaQuery.disableAnimationsOf(
                          context,
                        ),
                        onCheck: () {},
                        downloadProgress: controller.downloadProgress,
                        downloadSpeedBytesPerSecond:
                            controller.downloadSpeedBytesPerSecond,
                        downloadErrorMessage: controller.downloadErrorMessage,
                        downloadVersion: controller
                            .latestAvailableRelease
                            ?.version
                            .toString(),
                        isPreviewDownload: controller.isDevelopmentPreview,
                        onCancelDownload: controller.cancelDownload,
                        onDismissDownload: controller.dismissDownloadPopup,
                        onInstallUpdate: () =>
                            unawaited(controller.installAndRestart()),
                        installEnabled: controller.canInstallCurrentUpdate,
                        autofocus: false,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _PopoverPresentation {
  const _PopoverPresentation({
    required this.title,
    required this.icon,
    required this.accent,
    required this.iconSurface,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Color accent;
  final Color iconSurface;
}

class _PopoverAnchor extends StatelessWidget {
  const _PopoverAnchor();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(16, 8), painter: _PopoverAnchorPainter());
}

class _PopoverAnchorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFFAF8F0));
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFDCDDD2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _PopoverAnchorPainter oldDelegate) => false;
}
