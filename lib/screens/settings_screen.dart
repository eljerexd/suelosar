import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/instant_pop_material_page_route.dart';
import '../constants/app_icons.dart';
import '../services/settings_service.dart';
import '../widgets/app_notification.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/measurement_color_selector.dart';

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
                    _DisabledSwitchSetting(
                      title: 'Centrar automáticamente al iniciar',
                      value: true,
                    ),
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
                    _DisabledSwitchSetting(
                      title: 'Mostrar siempre las etiquetas',
                      value: true,
                    ),
                    _ConfirmBeforeDeletingSetting(),
                  ],
                ),
                SizedBox(height: 18),
                _SettingsSection(
                  icon: AppIcons.performance,
                  title: 'Rendimiento',
                  showComingSoon: false,
                  children: [
                    _ReduceAnimationsSetting(),
                    _DisabledActionSetting(
                      title: 'Limpiar caché temporal',
                      icon: AppIcons.delete,
                    ),
                  ],
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

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => _SettingsRow(
        title: 'Seguir mi ubicación automáticamente',
        trailing: Switch(
          value: settings.followLocationAutomatically,
          onChanged: settings.setFollowLocationAutomatically,
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

class _DisabledSwitchSetting extends StatelessWidget {
  const _DisabledSwitchSetting({required this.title, required this.value});

  final String title;
  final bool value;

  @override
  Widget build(BuildContext context) {
    return _SettingsRow(
      title: title,
      trailing: Switch(value: value, onChanged: null),
    );
  }
}

class _DisabledActionSetting extends StatelessWidget {
  const _DisabledActionSetting({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return _SettingsRow(
      title: title,
      trailing: IconButton(
        tooltip: title,
        onPressed: null,
        icon: Icon(icon, size: 20),
      ),
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
    if (launched) return;
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
