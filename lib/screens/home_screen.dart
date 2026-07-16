import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_routes.dart';
import '../app/instant_pop_material_page_route.dart';
import '../constants/app_icons.dart';
import '../pairing/device_pairing_models.dart';
import '../services/connectivity_service.dart';
import '../services/device_pairing_service.dart';
import '../services/synchronization_service.dart';
import '../sync/sync_status.dart';
import '../utils/app_motion.dart';
import '../widgets/responsive_desktop_shell.dart';
import 'synchronization_screen.dart';

typedef DeviceLinkedStatusLoader = Future<bool> Function();

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    this.deviceLinkedStatusLoader,
    this.synchronizationService,
    this.devicePairingService,
    super.key,
  });

  final DeviceLinkedStatusLoader? deviceLinkedStatusLoader;
  final SynchronizationService? synchronizationService;
  final DevicePairingService? devicePairingService;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Color.alphaBlend(
        colorScheme.primary.withValues(alpha: 0.025),
        Theme.of(context).scaffoldBackgroundColor,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 48,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Center(child: _OfficialSuelosArLogo()),
                            const SizedBox(height: 8),
                            Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 420,
                                ),
                                child: Text(
                                  'Cartografía de Suelos de la '
                                  'Provincia de Buenos Aires',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                        height: 1.35,
                                      ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 50),
                            _ModuleCard(
                              key: const ValueKey('module-gis-map'),
                              icon: AppIcons.map,
                              title: 'Mapa de Suelos',
                              subtitle: 'Explorar el visor GIS interactivo.',
                              primary: true,
                              onTap: () => Navigator.of(
                                context,
                              ).pushNamed(AppRoutes.gisMap),
                            ),
                            const SizedBox(height: 18),
                            LayoutBuilder(
                              builder: (context, gridConstraints) {
                                final useSingleColumn =
                                    gridConstraints.maxWidth < 620;
                                final cardWidth = useSingleColumn
                                    ? gridConstraints.maxWidth
                                    : (gridConstraints.maxWidth - 18) / 2;
                                return Wrap(
                                  spacing: 18,
                                  runSpacing: 18,
                                  children: [
                                    SizedBox(
                                      width: cardWidth,
                                      child: _ModuleCard(
                                        key: const ValueKey('module-soil-maps'),
                                        icon: AppIcons.pdf,
                                        title: 'Cartas de Suelo',
                                        subtitle:
                                            'Buscar y consultar cartas descriptivas en PDF.',
                                        onTap: () => Navigator.of(
                                          context,
                                        ).pushNamed(AppRoutes.soilMaps),
                                      ),
                                    ),
                                    SizedBox(
                                      width: cardWidth,
                                      child: _ModuleCard(
                                        key: const ValueKey(
                                          'module-personal-markers',
                                        ),
                                        icon: AppIcons.location,
                                        title: 'Marcadores',
                                        subtitle:
                                            'Registrar y administrar observaciones de campo.',
                                        onTap: () => Navigator.of(
                                          context,
                                        ).pushNamed(AppRoutes.personalMarkers),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: SizedBox(
                                        width: cardWidth,
                                        child: _ModuleCard(
                                          key: const ValueKey(
                                            'module-settings',
                                          ),
                                          icon: AppIcons.settings,
                                          title: 'Configuración',
                                          subtitle:
                                              'Preferencias de la aplicación.',
                                          subdued: true,
                                          onTap: () => Navigator.of(
                                            context,
                                          ).pushNamed(AppRoutes.settings),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              top: 8,
              right: 20,
              child: RepaintBoundary(
                child: _HomeSynchronizationStatus(
                  key: const ValueKey('home-synchronization-status'),
                  deviceLinkedStatusLoader: deviceLinkedStatusLoader,
                  service: synchronizationService,
                  pairingService: devicePairingService,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeSynchronizationStatus extends StatefulWidget {
  const _HomeSynchronizationStatus({
    required this.deviceLinkedStatusLoader,
    required this.service,
    required this.pairingService,
    super.key,
  });

  final DeviceLinkedStatusLoader? deviceLinkedStatusLoader;
  final SynchronizationService? service;
  final DevicePairingService? pairingService;

  @override
  State<_HomeSynchronizationStatus> createState() =>
      _HomeSynchronizationStatusState();
}

class _HomeSynchronizationStatusState extends State<_HomeSynchronizationStatus>
    with WidgetsBindingObserver {
  late final SynchronizationService _service;
  late final bool _ownsService;
  late final DevicePairingService _pairingService;
  late final bool _ownsPairingService;
  final MenuController _menuController = MenuController();
  bool _statusLoaded = false;
  bool? _linkedOverride;
  bool _opening = false;
  bool _refreshingPairingDevices = false;
  SyncStatus? _lastObservedSyncStatus;

  bool get _isLinked =>
      _statusLoaded && (_linkedOverride ?? _pairingService.hasPeers);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsService = widget.service == null;
    _service = widget.service ?? SynchronizationService();
    _ownsPairingService = widget.pairingService == null;
    _pairingService =
        widget.pairingService ??
        DevicePairingService(
          registrationLoader: () async {
            await _service.start();
            final device = _service.device;
            return PairingDeviceRegistration(
              deviceUuid: device.uuid,
              deviceName: device.name,
              platform: device.platform,
            );
          },
        );
    _lastObservedSyncStatus = _service.engineStatus;
    _service.addListener(_handleServiceChanged);
    _pairingService.addListener(_handleServiceChanged);
    _loadStatus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.removeListener(_handleServiceChanged);
    _pairingService.removeListener(_handleServiceChanged);
    if (_ownsPairingService) _pairingService.dispose();
    if (_ownsService) _service.dispose();
    super.dispose();
  }

  void _handleServiceChanged() {
    final status = _service.engineStatus;
    if (status == SyncStatus.completed &&
        _lastObservedSyncStatus != SyncStatus.completed) {
      unawaited(_refreshPairingDevices());
    }
    _lastObservedSyncStatus = status;
    if (mounted) setState(() {});
  }

  Future<void> _refreshPairingDevices() async {
    if (_refreshingPairingDevices || !_pairingService.isConfigured) return;
    _refreshingPairingDevices = true;
    try {
      await _pairingService.refreshDevices();
    } catch (_) {
      // The existing synchronization status remains available on failure.
    } finally {
      _refreshingPairingDevices = false;
    }
  }

  Future<void> _loadStatus() async {
    final serviceStart = _service.start();
    final loader = widget.deviceLinkedStatusLoader;
    if (loader != null) {
      final linkedOverride = await loader();
      if (!mounted) return;
      setState(() {
        _linkedOverride = linkedOverride;
        _statusLoaded = true;
      });
      await serviceStart;
      return;
    }
    await serviceStart;
    try {
      await _pairingService.start();
      if (_pairingService.isConfigured) {
        await _pairingService.refreshDevices();
      }
    } catch (_) {
      // Synchronization status remains available if device listing fails.
    }
    if (!mounted) return;
    setState(() {
      _linkedOverride = null;
      _statusLoaded = true;
    });
  }

  Future<void> _openPairing() async {
    if (_opening) return;
    _opening = true;
    try {
      await Navigator.of(context).push(
        InstantPopMaterialPageRoute<void>(
          builder: (_) => const SynchronizationScreen(openPairingOnStart: true),
        ),
      );
      if (mounted) await _loadStatus();
    } finally {
      _opening = false;
    }
  }

  Future<void> _openDetails() async {
    if (_opening) return;
    _opening = true;
    try {
      await Navigator.of(context).pushNamed(AppRoutes.synchronization);
      if (mounted) await _loadStatus();
    } finally {
      _opening = false;
    }
  }

  Future<void> _synchronizeNow() async {
    if (_service.isSynchronizing) return;
    await _service.synchronizeNow();
  }

  bool get _needsManualSync =>
      _service.queueSize > 0 ||
      _service.engineStatus == SyncStatus.queued ||
      _service.engineStatus == SyncStatus.error;

  Future<void> _showMobileSummary() async {
    final presentation = _presentation(context);
    final action = await showModalBottomSheet<_HomeSyncAction>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (sheetContext) => _SynchronizationStatusContent(
        isLinked: _isLinked,
        presentation: presentation,
        linkedDevices: _pairingService.peerCount,
        lastSuccessfulAt: _service.lastSuccessfulAt,
        pendingChanges: _service.queueSize,
        showSynchronize: _needsManualSync,
        onDetails: () => Navigator.pop(sheetContext, _HomeSyncAction.details),
        onSynchronize: () =>
            Navigator.pop(sheetContext, _HomeSyncAction.synchronize),
        onPairing: () => Navigator.pop(sheetContext, _HomeSyncAction.pair),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _HomeSyncAction.details:
        await _openDetails();
      case _HomeSyncAction.synchronize:
        await _synchronizeNow();
      case _HomeSyncAction.pair:
        await _openPairing();
      case null:
        break;
    }
  }

  void _runDesktopAction(_HomeSyncAction action) {
    _menuController.close();
    switch (action) {
      case _HomeSyncAction.details:
        _openDetails();
      case _HomeSyncAction.synchronize:
        _synchronizeNow();
      case _HomeSyncAction.pair:
        _openPairing();
    }
  }

  @override
  Widget build(BuildContext context) {
    final presentation = _presentation(context);
    final layout = SuelosArResponsiveLayout.fromContext(context);
    final statusChip = _SyncStatusChip(
      presentation: presentation,
      compact: layout.isPhone,
      pendingChanges: _service.queueSize,
      onTap: isSuelosArDesktopPlatform(context)
          ? _menuController.open
          : _showMobileSummary,
    );
    if (!isSuelosArDesktopPlatform(context)) return statusChip;
    return MenuAnchor(
      controller: _menuController,
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: 340,
          child: _SynchronizationStatusContent(
            isLinked: _isLinked,
            presentation: presentation,
            linkedDevices: _pairingService.peerCount,
            lastSuccessfulAt: _service.lastSuccessfulAt,
            pendingChanges: _service.queueSize,
            showSynchronize: _needsManualSync,
            onDetails: () => _runDesktopAction(_HomeSyncAction.details),
            onSynchronize: () => _runDesktopAction(_HomeSyncAction.synchronize),
            onPairing: () => _runDesktopAction(_HomeSyncAction.pair),
          ),
        ),
      ],
      builder: (context, controller, child) => statusChip,
    );
  }

  _HomeSyncPresentation _presentation(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (!_statusLoaded) {
      return const _HomeSyncPresentation(
        icon: AppIcons.synchronization,
        color: Color(0xFF3978A8),
        statusLabel: 'Consultando',
        primaryText: 'Consultando estado',
        secondaryText: 'Un momento…',
        semanticLabel: 'Sincronización. Consultando estado.',
        showProgress: true,
      );
    }
    if (!_isLinked) {
      return _HomeSyncPresentation(
        icon: Icons.link_off_outlined,
        color: colors.onSurfaceVariant,
        statusLabel: 'Sin configurar',
        primaryText: 'Vinculá tus dispositivos',
        secondaryText:
            'Accedé a tus marcadores, mediciones, favoritos y configuración '
            'desde cualquier dispositivo.',
        semanticLabel:
            'Sincronización. Dispositivo no vinculado. Abrir vinculación.',
      );
    }
    if (_service.engineStatus == SyncStatus.error ||
        _service.lastError?.trim().isNotEmpty == true) {
      return _HomeSyncPresentation(
        icon: AppIcons.error,
        color: colors.error,
        statusLabel: 'Error de sincronización',
        primaryText: 'No fue posible sincronizar.',
        secondaryText: 'Ver detalles para inspeccionar el diagnóstico.',
        semanticLabel: 'Sincronización con error. Abrir estado.',
      );
    }
    if (_service.isSynchronizing) {
      return const _HomeSyncPresentation(
        icon: AppIcons.synchronization,
        color: Color(0xFF3978A8),
        statusLabel: 'Sincronizando…',
        primaryText: 'Sincronizando datos…',
        secondaryText: 'Tus cambios se están actualizando.',
        semanticLabel: 'Sincronización en curso. Abrir estado.',
        showProgress: true,
      );
    }
    if (_service.connectivityStatus == ConnectivityStatus.offline ||
        _service.engineStatus == SyncStatus.waitingConnection) {
      return _HomeSyncPresentation(
        icon: Icons.cloud_off_outlined,
        color: colors.error,
        statusLabel: 'Sin conexión',
        primaryText: 'Sin conexión',
        secondaryText: 'Los cambios se sincronizarán al recuperar Internet.',
        semanticLabel: 'Sincronización sin conexión. Abrir resumen.',
      );
    }
    if (_service.queueSize > 0 || _service.engineStatus == SyncStatus.queued) {
      return _HomeSyncPresentation(
        icon: AppIcons.upload,
        color: Color(0xFFA66A13),
        statusLabel: _service.queueSize == 0
            ? 'Pendiente'
            : '${_service.queueSize} pendientes',
        primaryText: _service.queueSize == 0
            ? 'Cambios pendientes'
            : '${_service.queueSize} ${_service.queueSize == 1 ? 'cambio pendiente' : 'cambios pendientes'}',
        secondaryText: 'Se sincronizarán automáticamente.',
        semanticLabel: 'Sincronización. Hay cambios pendientes. Abrir estado.',
      );
    }
    final lastSync = _service.lastSuccessfulAt;
    final deviceCount = _pairingService.peerCount;
    final deviceLabel = deviceCount > 0
        ? '$deviceCount ${deviceCount == 1 ? 'dispositivo' : 'dispositivos'}'
        : 'Dispositivo vinculado';
    final lastSyncLabel = lastSync == null
        ? 'Aún sin sincronizaciones'
        : _relativeSyncTime(lastSync);
    return _HomeSyncPresentation(
      icon: AppIcons.success,
      color: const Color(0xFF547A3A),
      statusLabel: 'Sincronizado',
      primaryText: 'Todo actualizado',
      secondaryText: '$deviceLabel • $lastSyncLabel',
      semanticLabel: 'Sincronización al día. Abrir estado.',
    );
  }
}

class _HomeSyncPresentation {
  const _HomeSyncPresentation({
    required this.icon,
    required this.color,
    required this.statusLabel,
    required this.primaryText,
    required this.secondaryText,
    required this.semanticLabel,
    this.showProgress = false,
  });

  final IconData icon;
  final Color color;
  final String statusLabel;
  final String primaryText;
  final String secondaryText;
  final String semanticLabel;
  final bool showProgress;
}

class _SyncStatusChip extends StatelessWidget {
  const _SyncStatusChip({
    required this.presentation,
    required this.compact,
    required this.pendingChanges,
    required this.onTap,
  });

  final _HomeSyncPresentation presentation;
  final bool compact;
  final int pendingChanges;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final compactLabel =
        compact &&
            pendingChanges > 0 &&
            presentation.statusLabel.contains('pendiente')
        ? '$pendingChanges'
        : null;
    return Semantics(
      button: true,
      label: presentation.semanticLabel,
      child: Material(
        color: presentation.color.withValues(alpha: 0.1),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: compact ? 40 : 0,
              minHeight: 40,
              maxWidth: compact ? 58 : 210,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (presentation.showProgress)
                    SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: presentation.color,
                      ),
                    )
                  else
                    Icon(
                      presentation.icon,
                      size: compact ? 19 : 17,
                      color: presentation.color,
                    ),
                  if (compactLabel != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      compactLabel,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: presentation.color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ] else if (!compact) ...[
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        presentation.statusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: presentation.color,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _HomeSyncAction { details, synchronize, pair }

class _SynchronizationStatusContent extends StatelessWidget {
  const _SynchronizationStatusContent({
    required this.isLinked,
    required this.presentation,
    required this.linkedDevices,
    required this.lastSuccessfulAt,
    required this.pendingChanges,
    required this.showSynchronize,
    required this.onDetails,
    required this.onSynchronize,
    required this.onPairing,
  });

  final bool isLinked;
  final _HomeSyncPresentation presentation;
  final int linkedDevices;
  final DateTime? lastSuccessfulAt;
  final int pendingChanges;
  final bool showSynchronize;
  final VoidCallback onDetails;
  final VoidCallback onSynchronize;
  final VoidCallback onPairing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sincronización',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            if (!isLinked) ...[
              Text(
                'Protegé tus datos sincronizando tus dispositivos.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onPairing,
                icon: const Icon(Icons.add_link_rounded, size: 18),
                label: const Text('Agregar dispositivo'),
              ),
            ] else ...[
              _SyncSummaryRow(
                icon: presentation.icon,
                label: 'Estado',
                value: presentation.primaryText,
                color: presentation.color,
              ),
              _SyncSummaryRow(
                icon: AppIcons.device,
                label: 'Dispositivos vinculados',
                value: linkedDevices > 0 ? '$linkedDevices' : 'No disponible',
              ),
              _SyncSummaryRow(
                icon: AppIcons.synchronization,
                label: 'Última sincronización',
                value: lastSuccessfulAt == null
                    ? 'Nunca'
                    : _relativeSyncTime(lastSuccessfulAt!),
              ),
              _SyncSummaryRow(
                icon: AppIcons.queue,
                label: 'Cambios pendientes',
                value: '$pendingChanges',
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (showSynchronize)
                    OutlinedButton.icon(
                      onPressed: onSynchronize,
                      icon: const Icon(AppIcons.synchronization, size: 18),
                      label: const Text('Sincronizar ahora'),
                    ),
                  FilledButton(
                    onPressed: onDetails,
                    child: const Text('Ver detalles'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SyncSummaryRow extends StatelessWidget {
  const _SyncSummaryRow({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color ?? colors.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 12),
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
      ),
    );
  }
}

String _relativeSyncTime(DateTime value) {
  final difference = DateTime.now().difference(value);
  if (difference.isNegative || difference.inSeconds < 10) return 'ahora';
  if (difference.inMinutes < 1) return 'hace ${difference.inSeconds} s';
  if (difference.inHours < 1) return 'hace ${difference.inMinutes} min';
  if (difference.inDays < 1) return 'hace ${difference.inHours} h';
  return 'hace ${difference.inDays} d';
}

class _OfficialSuelosArLogo extends StatelessWidget {
  const _OfficialSuelosArLogo();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(240.0, 560.0);

        return Semantics(
          image: true,
          label: 'SuelosAR',
          child: Image.asset(
            'assets/images/logoapp.png',
            width: width,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            excludeFromSemantics: true,
          ),
        );
      },
    );
  }
}

class _ModuleCard extends StatefulWidget {
  const _ModuleCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
    this.subdued = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;
  final bool subdued;

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  static const double _restingElevation = 1;
  static const double _hoverElevation = 4;

  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final cardHeight = widget.primary ? 134.0 : 120.0;
    final motionDuration = AppMotion.duration(
      context,
      const Duration(milliseconds: 180),
    );
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedSlide(
          offset: Offset(0, _hovered ? -0.015 : 0),
          duration: motionDuration,
          curve: Curves.easeOutCubic,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: _hovered ? _hoverElevation : _restingElevation),
            duration: motionDuration,
            curve: Curves.easeOutCubic,
            builder: (context, elevation, child) {
              return Card(
                margin: EdgeInsets.zero,
                elevation: elevation,
                shadowColor: colorScheme.shadow.withValues(alpha: 0.16),
                color: widget.primary
                    ? colorScheme.primaryContainer.withValues(alpha: 0.24)
                    : widget.subdued
                    ? colorScheme.surfaceContainerLowest
                    : colorScheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: widget.primary
                      ? BorderSide(
                          color: colorScheme.primary.withValues(alpha: 0.16),
                        )
                      : BorderSide.none,
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.onTap,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: cardHeight),
                    child: Padding(
                      padding: widget.primary
                          ? const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 16,
                            )
                          : const EdgeInsets.fromLTRB(20, 12, 16, 12),
                      child: _buildCardContent(context, colorScheme),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCardContent(BuildContext context, ColorScheme colorScheme) {
    if (widget.primary) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return Center(
            child: Row(
              key: const ValueKey('primary-card-content'),
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildIcon(colorScheme, size: 54),
                const SizedBox(width: 16),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth - 70,
                  ),
                  child: _buildText(
                    context,
                    colorScheme,
                    alignment: CrossAxisAlignment.start,
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    return Row(
      children: [
        _buildIcon(colorScheme, size: 50),
        const SizedBox(width: 16),
        Expanded(
          child: _buildText(
            context,
            colorScheme,
            alignment: CrossAxisAlignment.start,
          ),
        ),
        const SizedBox(width: 12),
        const Padding(
          padding: EdgeInsets.only(right: 4),
          child: Icon(AppIcons.chevronRight, size: 20),
        ),
      ],
    );
  }

  Widget _buildIcon(ColorScheme colorScheme, {required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: widget.primary
            ? colorScheme.primaryContainer
            : widget.subdued
            ? colorScheme.surfaceContainerHigh
            : colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Icon(
          widget.icon,
          size: widget.primary ? 32 : 28,
          color: widget.primary
              ? colorScheme.onPrimaryContainer
              : widget.subdued
              ? colorScheme.onSurfaceVariant
              : colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  Widget _buildText(
    BuildContext context,
    ColorScheme colorScheme, {
    required CrossAxisAlignment alignment,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: [
        Text(
          widget.title,
          textAlign: TextAlign.start,
          style:
              (widget.primary
                      ? Theme.of(context).textTheme.titleLarge
                      : Theme.of(context).textTheme.titleMedium)
                  ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          widget.subtitle,
          textAlign: TextAlign.start,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
