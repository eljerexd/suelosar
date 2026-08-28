import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../analytics/analytics_service.dart';
import '../app/instant_pop_material_page_route.dart';
import '../constants/app_icons.dart';
import '../services/settings_service.dart';
import '../widgets/app_notification.dart';
import '../widgets/destructive_action_confirmation.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/measurement_color_selector.dart';
import 'synchronization_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FloatingHeaderScaffold(
      bottomPadding: 32,
      header: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingAppBarBackButton(
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 14),
          const FloatingAppBarTitle('Configuración'),
          const SizedBox(width: 10),
        ],
      ),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsSection(
                  icon: AppIcons.map,
                  title: 'Mapa',
                  showComingSoon: false,
                  children: [
                    _FollowLocationSetting(),
                    _ShowGpsAccuracyCircleSetting(),
                    _ShowZoomLevelSetting(),
                  ],
                ),
                SizedBox(height: 18),
                _SettingsSection(
                  icon: AppIcons.ruler,
                  title: 'Mediciones',
                  showComingSoon: false,
                  children: [
                    _MeasurementColorSetting(),
                    _ConfirmBeforeDeletingSetting(),
                  ],
                ),
                SizedBox(height: 18),
                _SettingsSection(
                  icon: AppIcons.performance,
                  title: 'Rendimiento',
                  showComingSoon: false,
                  children: [_ReduceAnimationsSetting()],
                ),
                SizedBox(height: 18),
                _SettingsSection(
                  icon: AppIcons.delete,
                  title: 'Datos y almacenamiento',
                  showComingSoon: false,
                  children: [_ClearMapsCacheSetting()],
                ),
                SizedBox(height: 18),
                _SettingsSection(
                  icon: AppIcons.synchronization,
                  title: 'Sincronización',
                  showComingSoon: false,
                  children: [_SynchronizationSetting()],
                ),
                SizedBox(height: 18),
                _SettingsSection(
                  icon: AppIcons.information,
                  title: 'Acerca de',
                  children: [
                    _AboutSuelosArSetting(),
                    _OpenSourceLicensesSetting(),
                    _VersionSetting(),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AboutSuelosArScreen extends StatelessWidget {
  const AboutSuelosArScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FloatingHeaderScaffold(
      bottomPadding: 32,
      header: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingAppBarBackButton(
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 14),
          const FloatingAppBarTitle('Acerca de'),
          const SizedBox(width: 10),
        ],
      ),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AboutCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SuelosAR',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Aplicación profesional para visualizar cartas de '
                        'suelo, realizar mediciones de campo y consultar '
                        'memorias descriptivas de la Provincia de Buenos Aires.',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 18),
                      FutureBuilder<PackageInfo?>(
                        future: _loadPackageInfo(),
                        builder: (context, snapshot) => _AboutInfoRow(
                          label: 'Versión',
                          value:
                              snapshot.connectionState == ConnectionState.done
                              ? _formatVersion(snapshot.data)
                              : '...',
                        ),
                      ),
                      const SizedBox(height: 8),
                      const _AboutInfoRow(
                        label: 'Desarrollador',
                        value: 'Jeremías Moisés Arata',
                      ),
                      const SizedBox(height: 8),
                      const _AboutInfoRow(
                        label: 'Derechos de autor',
                        value: '© 2026',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const _AboutCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _AboutSectionTitle('Funciones principales'),
                      SizedBox(height: 12),
                      _AboutFeature('Visualización de mapas de suelo'),
                      _AboutFeature('Mediciones de área y distancia'),
                      _AboutFeature('Análisis de lote'),
                      _AboutFeature('Marcadores personales'),
                      _AboutFeature('Favoritos'),
                      _AboutFeature('Exportación PDF, JSON y CSV'),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const _ProblemReportCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.white,
      elevation: 1,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.12),
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: const EdgeInsets.all(20), child: child),
    );
  }
}

class _AboutSectionTitle extends StatelessWidget {
  const _AboutSectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _AboutInfoRow extends StatelessWidget {
  const _AboutInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _AboutFeature extends StatelessWidget {
  const _AboutFeature(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            AppIcons.check,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _ProblemReportCard extends StatelessWidget {
  const _ProblemReportCard();

  @override
  Widget build(BuildContext context) {
    return _AboutCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _AboutSectionTitle('Reportar un problema'),
          const SizedBox(height: 10),
          Text(
            '¿Encontraste un error o tenés una sugerencia?\n'
            'Podés enviarme un correo y lo revisaré para una futura '
            'actualización.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.tonalIcon(
            onPressed: () => _openProblemReportEmail(context),
            icon: const Icon(AppIcons.mail),
            label: const Text('Enviar reporte'),
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.children,
    this.showComingSoon = true,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final bool showComingSoon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.white,
      elevation: 1,
      shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.12),
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 21, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (var index = 0; index < children.length; index++) ...[
              children[index],
              if (index != children.length - 1)
                Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.65,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReduceAnimationsSetting extends StatelessWidget {
  const _ReduceAnimationsSetting();

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => _SettingsRow(
        title: 'Reducir animaciones',
        trailing: Switch(
          value: settings.reduceAnimations,
          onChanged: settings.setReduceAnimations,
        ),
      ),
    );
  }
}

class _FollowLocationSetting extends StatelessWidget {
  const _FollowLocationSetting();

  Future<void> _setEnabled(SettingsService settings, bool value) async {
    await settings.setFollowLocationAutomatically(value);
    if (value) {
      unawaited(AnalyticsService.instance.logGpsEnabled());
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => _SettingsRow(
        title: 'Seguir mi ubicación automáticamente',
        trailing: Switch(
          value: settings.followLocationAutomatically,
          onChanged: (value) => unawaited(_setEnabled(settings, value)),
        ),
      ),
    );
  }
}

class _ConfirmBeforeDeletingSetting extends StatelessWidget {
  const _ConfirmBeforeDeletingSetting();

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => _SettingsRow(
        title: 'Confirmar antes de eliminar',
        trailing: Switch(
          value: settings.confirmBeforeDeleting,
          onChanged: settings.setConfirmBeforeDeleting,
        ),
      ),
    );
  }
}

class _ShowGpsAccuracyCircleSetting extends StatelessWidget {
  const _ShowGpsAccuracyCircleSetting();

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => _SettingsRow(
        title: 'Mostrar círculo de precisión GPS',
        trailing: Switch(
          value: settings.showGpsAccuracyCircle,
          onChanged: settings.setShowGpsAccuracyCircle,
        ),
      ),
    );
  }
}

class _ShowZoomLevelSetting extends StatelessWidget {
  const _ShowZoomLevelSetting();

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => _SettingsRow(
        title: 'Mostrar nivel de zoom',
        trailing: Switch(
          value: settings.showZoomLevel,
          onChanged: settings.setShowZoomLevel,
        ),
      ),
    );
  }
}

/// Directory where PmTilesGisRepository copies each province's bundled
/// PMTiles archive so it can be opened as a real file (PMTiles needs random
/// file access; asset bundles don't support that) — see
/// `PmTilesGisRepository._prepareAssetArchive` in gis_repository.dart. That
/// file is off-limits to touch for this settings cleanup, so the path is
/// duplicated here by convention (`suelosar_maps` under the app's support
/// directory) rather than imported — if that directory name ever changes
/// there, this needs updating too. Confirmed by direct inspection (both on
/// the real Windows support directory and by reading `_prepareAssetArchive`)
/// that this directory holds *only* those copies — nothing the user
/// created, no favorites/measurements/markers/settings (those live
/// elsewhere: SharedPreferences for settings, and their own sync-backed
/// stores for the rest) — but the file matching below is a second,
/// independent safety net on top of that directory scoping: only files
/// whose name matches the PMTiles cache's own naming pattern are ever
/// touched, regardless of what else might one day end up in this
/// directory.
Future<Directory> _mapsCacheDirectory() async {
  final supportDirectory = await getApplicationSupportDirectory();
  return Directory(
    '${supportDirectory.path}${Platform.pathSeparator}suelosar_maps',
  );
}

/// Matches `_prepareAssetArchive`'s own output — `province-64hexCharSha256
/// .pmtiles`, plus the `.tmp` staging file it briefly writes while
/// copying before renaming to its final name (left behind only if the app
/// was killed mid-copy). Nothing else in this directory is ever touched.
final RegExp _mapsCacheFilePattern = RegExp(
  r'^[a-z0-9_]+-[a-f0-9]{64}\.pmtiles(\.tmp)?$',
);

Future<List<File>> _mapsCacheFiles() async {
  final directory = await _mapsCacheDirectory();
  if (!directory.existsSync()) return const [];
  return directory
      .listSync()
      .whereType<File>()
      .where(
        (file) => _mapsCacheFilePattern.hasMatch(
          file.uri.pathSegments.last,
        ),
      )
      .toList();
}

/// The province a cached file belongs to — the part of its name before the
/// content hash, e.g. `soil_polygons` or `santa_fe_soil_polygons`.
String _mapsCacheStem(File file) {
  final name = file.uri.pathSegments.last;
  final withoutSuffix = name.replaceFirst(
    RegExp(r'\.pmtiles(\.tmp)?$'),
    '',
  );
  final hashStart = withoutSuffix.length - 64;
  return hashStart > 1
      ? withoutSuffix.substring(0, hashStart - 1)
      : withoutSuffix;
}

Future<int> _mapsCacheSizeBytes() async {
  var total = 0;
  for (final file in await _mapsCacheFiles()) {
    total += await file.length();
  }
  return total;
}

// Reviewed against the real cache on disk before picking this: today the
// two provinces' current copies total ~249 MB together, and
// `_prepareAssetArchive` already removes an old version's file itself as
// soon as it finishes copying in a replacement, so in normal operation this
// directory never accumulates old versions to begin with — this threshold
// is a backstop for the one case that isn't self-cleaning: the app being
// killed before that removal step runs, leaving an orphaned older file
// behind. 500 MB gives headroom for that plus a future third
// smaller-than-Buenos-Aires-sized province before it would ever trigger.
const int _mapsCacheAutoTrimThresholdBytes = 500 * 1024 * 1024;

/// Best-effort, lazy safety net — runs only when the cache size is checked
/// (i.e. whenever Configuración's "Limpiar caché de mapas" row builds),
/// never on a timer or in the background. Only ever removes an *older*
/// duplicate for a province that already has a newer file cached; the most
/// recently modified file per province is always kept, since that's the
/// one the map screen actually needs.
Future<void> _autoTrimMapsCacheIfNeeded() async {
  final files = await _mapsCacheFiles();
  if (files.length <= 1) return;

  final modified = <File, DateTime>{};
  final sizes = <File, int>{};
  var total = 0;
  for (final file in files) {
    modified[file] = await file.lastModified();
    final size = await file.length();
    sizes[file] = size;
    total += size;
  }
  if (total <= _mapsCacheAutoTrimThresholdBytes) return;

  final newestPerStem = <String, File>{};
  for (final file in files) {
    final stem = _mapsCacheStem(file);
    final current = newestPerStem[stem];
    if (current == null || modified[file]!.isAfter(modified[current]!)) {
      newestPerStem[stem] = file;
    }
  }
  final removable =
      files.where((file) => newestPerStem[_mapsCacheStem(file)] != file)
          .toList()
        ..sort((a, b) => modified[a]!.compareTo(modified[b]!));

  for (final file in removable) {
    if (total <= _mapsCacheAutoTrimThresholdBytes) break;
    try {
      await file.delete();
      total -= sizes[file]!;
    } on FileSystemException {
      // Skip a file that's still open/locked; try the next one.
    }
  }
}

/// Deletes every currently-cached copy (unlike the automatic trim above,
/// this is the user explicitly asking to reclaim the space right now, so it
/// removes the current file per province too, not just orphaned old ones —
/// they're only ever a copy of what's already bundled in the app, so the
/// map screen just recreates whichever it needs next time it's opened;
/// nothing the user created is stored here).
Future<bool> _clearMapsCache() async {
  var allDeleted = true;
  for (final file in await _mapsCacheFiles()) {
    try {
      await file.delete();
    } on FileSystemException {
      // Most likely still held open by an active map screen elsewhere in
      // the app (Windows in particular refuses to delete open files).
      allDeleted = false;
    }
  }
  return allDeleted;
}

Future<int> _loadMapsCacheSize() async {
  await _autoTrimMapsCacheIfNeeded();
  return _mapsCacheSizeBytes();
}

String _formatCacheSize(int bytes) {
  if (bytes <= 0) return '0 MB';
  final megabytes = bytes / (1024 * 1024);
  if (megabytes < 1) return '<1 MB';
  return '${megabytes.round()} MB';
}

class _ClearMapsCacheSetting extends StatefulWidget {
  const _ClearMapsCacheSetting();

  @override
  State<_ClearMapsCacheSetting> createState() =>
      _ClearMapsCacheSettingState();
}

class _ClearMapsCacheSettingState extends State<_ClearMapsCacheSetting> {
  late Future<int> _sizeFuture = _loadMapsCacheSize();
  bool _clearing = false;

  Future<void> _handleTap(int currentSize) async {
    if (currentSize <= _mapsCacheAutoTrimThresholdBytes) return;
    final confirmed = await confirmDestructiveAction(
      context,
      title: 'Limpiar caché de mapas',
      message:
          'Se van a borrar ${_formatCacheSize(currentSize)} de mapas '
          'preparados para uso sin conexión. Se vuelven a preparar '
          'automáticamente la próxima vez que abras el mapa.',
    );
    if (!confirmed || !mounted) return;

    setState(() => _clearing = true);
    final success = await _clearMapsCache();
    if (!mounted) return;
    setState(() {
      _clearing = false;
      _sizeFuture = _mapsCacheSizeBytes();
    });
    AppNotification.show(
      context,
      message: success
          ? 'Caché de mapas liberada.'
          : 'No se pudo liberar la caché. Cerrá el mapa e intentá de nuevo.',
      type: success ? AppNotificationType.success : AppNotificationType.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FutureBuilder<int>(
      future: _sizeFuture,
      builder: (context, snapshot) {
        final size = snapshot.data;
        // Below the same threshold the automatic trim uses, there's nothing
        // worth reclaiming yet — say so and disable the button, rather than
        // inviting a delete that would just get re-downloaded immediately.
        final belowThreshold =
            size != null && size <= _mapsCacheAutoTrimThresholdBytes;
        final label = size == null
            ? '...'
            : belowThreshold
            ? 'Nada que limpiar'
            : _formatCacheSize(size);
        return _SettingsRow(
          title: 'Limpiar caché de mapas',
          trailing: _clearing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Limpiar caché de mapas',
                      onPressed: (size != null && !belowThreshold)
                          ? () => unawaited(_handleTap(size))
                          : null,
                      icon: const Icon(AppIcons.delete, size: 20),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _NavigationSetting extends StatelessWidget {
  const _NavigationSetting({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: _SettingsRow(
          title: title,
          trailing: Icon(
            AppIcons.chevronRight,
            size: 19,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _AboutSuelosArSetting extends StatelessWidget {
  const _AboutSuelosArSetting();

  @override
  Widget build(BuildContext context) {
    return _NavigationSetting(
      title: 'Acerca de SuelosAR',
      onTap: () {
        Navigator.of(context).push(
          InstantPopMaterialPageRoute(
            builder: (_) => const AboutSuelosArScreen(),
          ),
        );
      },
    );
  }
}

class _SynchronizationSetting extends StatelessWidget {
  const _SynchronizationSetting();

  @override
  Widget build(BuildContext context) {
    return _NavigationSetting(
      title: 'Estado y administración',
      onTap: () {
        Navigator.of(context).push(
          InstantPopMaterialPageRoute(
            builder: (_) => const SynchronizationScreen(),
          ),
        );
      },
    );
  }
}

class _OpenSourceLicensesSetting extends StatelessWidget {
  const _OpenSourceLicensesSetting();

  @override
  Widget build(BuildContext context) {
    return _NavigationSetting(
      title: 'Licencias de código abierto',
      onTap: () async {
        final packageInfo = await _loadPackageInfo();
        if (!context.mounted) return;
        showLicensePage(
          context: context,
          applicationName: 'SuelosAR',
          applicationVersion: _formatVersion(packageInfo),
        );
      },
    );
  }
}

class _VersionSetting extends StatelessWidget {
  const _VersionSetting();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo?>(
      future: _loadPackageInfo(),
      builder: (context, snapshot) {
        return _SettingsRow(
          title: 'Versión de la aplicación',
          trailing: Text(
            snapshot.connectionState == ConnectionState.done
                ? _formatVersion(snapshot.data)
                : '...',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}

class _MeasurementColorSetting extends StatelessWidget {
  const _MeasurementColorSetting();

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => _SettingsRow(
        title: 'Color predeterminado',
        trailing: MeasurementColorSelector(
          selectedColor: settings.defaultMeasurementColor,
          onChanged: settings.setDefaultMeasurementColor,
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.title, required this.trailing});

  final String title;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodyLarge),
          ),
          const SizedBox(width: 16),
          trailing,
        ],
      ),
    );
  }
}

Future<PackageInfo?> _loadPackageInfo() async {
  try {
    return await PackageInfo.fromPlatform();
  } catch (_) {
    return null;
  }
}

String _formatVersion(PackageInfo? packageInfo) {
  if (packageInfo == null) {
    return 'No disponible';
  }

  return packageInfo.version;
}

Future<void> _openProblemReportEmail(BuildContext context) async {
  final packageInfo = await _loadPackageInfo();
  final device = await _loadReportDeviceName();
  final now = DateTime.now();
  final body =
      '''SuelosAR - Reporte de problema

Versión: ${packageInfo == null ? '' : _reportVersion(packageInfo)}
Sistema operativo: ${_reportOperatingSystem()}
Dispositivo: $device
Modo de ejecución: ${_reportBuildMode()}

Fecha: ${_formatReportDate(now)}

Descripción del problema:

Pasos para reproducir:

Resultado esperado:

Resultado obtenido:

Información adicional:
''';
  final uri = Uri(
    scheme: 'mailto',
    path: 'jere.arata@gmail.com',
    queryParameters: <String, String>{
      'subject': 'SuelosAR - Reporte de problema',
      'body': body,
    },
  );

  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (launched) {
      unawaited(AnalyticsService.instance.logFeedbackOpened());
      return;
    }
  } catch (_) {}
  if (!context.mounted) return;
  AppNotification.show(
    context,
    message: 'No se pudo abrir la aplicación de correo.',
    type: AppNotificationType.error,
  );
}

Future<String> _loadReportDeviceName() async {
  try {
    final deviceInfo = DeviceInfoPlugin();
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => _androidDeviceName(
        await deviceInfo.androidInfo,
      ),
      TargetPlatform.windows => (await deviceInfo.windowsInfo).computerName,
      TargetPlatform.macOS => (await deviceInfo.macOsInfo).modelName,
      TargetPlatform.iOS => (await deviceInfo.iosInfo).modelName,
      TargetPlatform.linux || TargetPlatform.fuchsia => '',
    };
  } catch (_) {
    return '';
  }
}

String _androidDeviceName(AndroidDeviceInfo info) {
  final manufacturer = info.manufacturer.trim();
  final model = info.model.trim();
  if (manufacturer.isEmpty) return model;
  if (model.isEmpty) return manufacturer;
  if (model.toLowerCase().startsWith(manufacturer.toLowerCase())) return model;
  return '$manufacturer $model';
}

String _reportOperatingSystem() => switch (defaultTargetPlatform) {
  TargetPlatform.android => 'Android',
  TargetPlatform.windows => 'Windows',
  TargetPlatform.linux => 'Linux',
  TargetPlatform.macOS => 'macOS',
  TargetPlatform.iOS => 'iOS',
  TargetPlatform.fuchsia => '',
};

String _reportBuildMode() {
  if (kDebugMode) return 'Debug';
  if (kReleaseMode) return 'Release';
  if (kProfileMode) return 'Profile';
  return '';
}

String _reportVersion(PackageInfo packageInfo) {
  final buildNumber = packageInfo.buildNumber.trim();
  return buildNumber.isEmpty
      ? packageInfo.version
      : '${packageInfo.version}+$buildNumber';
}

String _formatReportDate(DateTime value) {
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${twoDigits(value.day)}/${twoDigits(value.month)}/${value.year} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
}
