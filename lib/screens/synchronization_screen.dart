import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_icons.dart';
import '../pairing/device_pairing_models.dart';
import '../services/connectivity_service.dart';
import '../services/device_pairing_service.dart';
import '../services/synchronization_service.dart';
import '../sync/sync_status.dart';
import '../sync/initial_history_sync.dart';
import '../utils/app_motion.dart';
import '../widgets/app_notification.dart';
import '../widgets/device_pairing_flow.dart';
import '../widgets/floating_app_bar_card.dart';

class SynchronizationScreen extends StatefulWidget {
  const SynchronizationScreen({
    this.service,
    this.pairingService,
    this.openPairingOnStart = false,
    super.key,
  });

  final SynchronizationService? service;
  final DevicePairingService? pairingService;
  final bool openPairingOnStart;

  @override
  State<SynchronizationScreen> createState() => _SynchronizationScreenState();
}

class _SynchronizationScreenState extends State<SynchronizationScreen> {
  late final SynchronizationService _service;
  late final bool _ownsService;
  late final DevicePairingService _pairingService;
  late final bool _ownsPairingService;
  _SyncButtonFeedback _syncButtonFeedback = _SyncButtonFeedback.idle;
  Timer? _syncSuccessTimer;

  @override
  void initState() {
    super.initState();
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
    unawaited(_startServices());
  }

  @override
  void dispose() {
    _syncSuccessTimer?.cancel();
    if (_ownsPairingService) _pairingService.dispose();
    if (_ownsService) _service.dispose();
    super.dispose();
  }

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
          const FloatingAppBarTitle('Sincronización'),
          const SizedBox(width: 10),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([_service, _pairingService]),
        builder: (context, _) => SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 720;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StatusCard(service: _service),
                      if (_service.initialHistoryProgress.status !=
                          InitialHistorySyncStatus.idle) ...[
                        const SizedBox(height: 18),
                        _InitialHistoryCard(
                          progress: _service.initialHistoryProgress,
                        ),
                      ],
                      const SizedBox(height: 18),
                      if (wide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _DeviceCard(
                                service: _service,
                                onCopyUuid: _copyDeviceUuid,
                              ),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: _DevicesCard(
                                service: _pairingService,
                                onAdd: _openPairing,
                                onInspect: _showDeviceInformation,
                                onRename: _renameDevice,
                                onRemove: _confirmAndRemoveDevice,
                              ),
                            ),
                          ],
                        )
                      else ...[
                        _DeviceCard(
                          service: _service,
                          onCopyUuid: _copyDeviceUuid,
                        ),
                        const SizedBox(height: 18),
                        _DevicesCard(
                          service: _pairingService,
                          onAdd: _openPairing,
                          onInspect: _showDeviceInformation,
                          onRename: _renameDevice,
                          onRemove: _confirmAndRemoveDevice,
                        ),
                      ],
                      const SizedBox(height: 18),
                      if (wide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _OperationsCard(service: _service)),
                            const SizedBox(width: 18),
                            Expanded(child: _ConnectionCard(service: _service)),
                          ],
                        )
                      else ...[
                        _OperationsCard(service: _service),
                        const SizedBox(height: 18),
                        _ConnectionCard(service: _service),
                      ],
                      const SizedBox(height: 18),
                      _LastSyncCard(service: _service),
                      const SizedBox(height: 18),
                      _ActionsCard(
                        service: _service,
                        feedback: _syncButtonFeedback,
                        onClear: _confirmAndClearQueue,
                        onSynchronize: _synchronizeNow,
                        onRetry: _retryFailedOperations,
                      ),
                      const SizedBox(height: 18),
                      _AdvancedCard(
                        service: _service,
                        onCopyUuid: _copyDeviceUuid,
                        onReuploadLocalData: _confirmAndReuploadLocalData,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startServices() async {
    await _service.start();
    try {
      await _pairingService.start();
      if (widget.openPairingOnStart) {
        if (mounted) await _openPairing();
      } else if (!_service.isSynchronizing) {
        await _service.synchronizeNow();
      }
    } catch (_) {
      // The card exposes a retryable service state without blocking sync UI.
    }
  }

  Future<void> _openPairing() async {
    if (!_pairingService.isConfigured) {
      AppNotification.show(
        context,
        message: 'El servicio de sincronización no está configurado.',
        type: AppNotificationType.warning,
      );
      return;
    }
    final paired = await showDevicePairingFlow(context, _pairingService);
    if (!mounted || !paired) return;
    unawaited(_service.synchronizeNow());
    AppNotification.show(
      context,
      message: 'Dispositivo vinculado correctamente.',
      type: AppNotificationType.success,
    );
  }

  Future<void> _renameDevice(PairedDevice device) async {
    final controller = TextEditingController(text: device.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Renombrar dispositivo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
          decoration: const InputDecoration(labelText: 'Nombre'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    try {
      await _pairingService.renameDevice(device, name);
    } catch (error) {
      if (!mounted) return;
      _showPairingError(error);
    }
  }

  Future<void> _confirmAndRemoveDevice(PairedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('¿Quitar dispositivo?'),
        content: Text(
          '${device.deviceName} dejará de acceder a los datos sincronizados.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _pairingService.removeDevice(device);
      if (!mounted) return;
      AppNotification.show(
        context,
        message: 'Dispositivo desvinculado.',
        type: AppNotificationType.success,
      );
    } catch (error) {
      if (!mounted) return;
      _showPairingError(error);
    }
  }

  Future<void> _showDeviceInformation(PairedDevice device) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(device.deviceName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InfoRow(label: 'Plataforma', value: device.platform),
            _InfoRow(
              label: 'Vinculado',
              value: _exactDateTime(device.pairedAt),
            ),
            _InfoRow(
              label: 'Última sincronización',
              value: device.lastSynchronizationAt == null
                  ? 'Nunca'
                  : _exactDateTime(device.lastSynchronizationAt!),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  void _showPairingError(Object error) {
    AppNotification.show(
      context,
      message: error is DevicePairingException
          ? error.message
          : 'No se pudo completar la operación.',
      type: AppNotificationType.error,
    );
  }

  Future<void> _synchronizeNow() async {
    if (_syncButtonFeedback == _SyncButtonFeedback.running) return;
    _syncSuccessTimer?.cancel();
    setState(() => _syncButtonFeedback = _SyncButtonFeedback.running);
    final started = await _service.synchronizeNow();
    if (!mounted) return;
    final failed = _service.engineStatus == SyncStatus.error;
    final waiting = _service.engineStatus == SyncStatus.waitingConnection;
    if (started && !failed && !waiting) {
      setState(() => _syncButtonFeedback = _SyncButtonFeedback.success);
      _syncSuccessTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() => _syncButtonFeedback = _SyncButtonFeedback.idle);
        }
      });
      return;
    }
    setState(() => _syncButtonFeedback = _SyncButtonFeedback.idle);
    AppNotification.show(
      context,
      message: !started
          ? 'Supabase no está configurado.'
          : failed
          ? 'No se pudo completar la sincronización.'
          : 'La sincronización espera una conexión.',
      type: failed ? AppNotificationType.error : AppNotificationType.warning,
    );
  }

  Future<void> _retryFailedOperations() async {
    final started = await _service.retryFailedOperations();
    if (!mounted) return;
    final failed = _service.engineStatus == SyncStatus.error;
    AppNotification.show(
      context,
      message: !started
          ? 'Supabase no está configurado.'
          : failed
          ? 'El reintento no pudo completarse.'
          : 'Reintento completado.',
      type: !started
          ? AppNotificationType.warning
          : failed
          ? AppNotificationType.error
          : AppNotificationType.information,
    );
  }

  Future<void> _confirmAndClearQueue() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('¿Limpiar cambios pendientes?'),
        content: const Text(
          'Las operaciones locales dejarán de sincronizarse. '
          'Los datos guardados en este dispositivo no se eliminarán.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Limpiar cola'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.clearPendingQueue();
    if (!mounted) return;
    AppNotification.show(
      context,
      message: 'Cola local limpiada.',
      type: AppNotificationType.success,
    );
  }

  Future<void> _copyDeviceUuid() async {
    final uuid = _service.device.uuid;
    if (uuid.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: uuid));
    if (!mounted) return;
    AppNotification.show(
      context,
      message: 'UUID copiado.',
      type: AppNotificationType.information,
    );
  }

  Future<void> _confirmAndReuploadLocalData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Volver a subir datos locales'),
        content: const Text(
          'Se comparar\u00e1n todos los datos locales con la nube y se '
          'subir\u00e1 cualquier elemento faltante. No se eliminar\u00e1 '
          'informaci\u00f3n local.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Comparar y subir'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final started = await _service.reuploadLocalData();
    if (!mounted) return;
    AppNotification.show(
      context,
      message: started
          ? 'Comparando datos locales con la nube.'
          : 'El servicio de sincronizaci\u00f3n no est\u00e1 disponible.',
      type: started
          ? AppNotificationType.information
          : AppNotificationType.warning,
    );
  }
}

enum _SyncButtonFeedback { idle, running, success }

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.service});

  final SynchronizationService service;

  @override
  Widget build(BuildContext context) {
    final presentation = _statusPresentation(context, service);
    return _SyncCard(
      child: AnimatedSwitcher(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 220),
        ),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SizeTransition(sizeFactor: animation, child: child),
        ),
        child: Row(
          key: ValueKey(presentation.label),
          children: [
            _IconSurface(icon: presentation.icon, color: presentation.color),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StatusChip(
                    label: presentation.label,
                    icon: presentation.icon,
                    color: presentation.color,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    presentation.description,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InitialHistoryCard extends StatelessWidget {
  const _InitialHistoryCard({required this.progress});

  final InitialHistorySyncProgress progress;

  @override
  Widget build(BuildContext context) {
    final completed = progress.status == InitialHistorySyncStatus.completed;
    final failed = progress.status == InitialHistorySyncStatus.error;
    final colors = Theme.of(context).colorScheme;
    return _SyncCard(
      title: completed
          ? 'Datos existentes sincronizados'
          : failed
          ? 'No se pudo sincronizar el historial'
          : 'Subiendo datos existentes...',
      icon: completed
          ? AppIcons.check
          : failed
          ? Icons.error_outline
          : Icons.cloud_upload_outlined,
      child: AnimatedSwitcher(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 200),
        ),
        child: completed
            ? Row(
                key: const ValueKey('bootstrap-completed'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(AppIcons.check, color: colors.primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Tu informaci\u00f3n local anterior ya est\u00e1 '
                      'disponible en los dispositivos vinculados.',
                    ),
                  ),
                ],
              )
            : failed
            ? Text(
                progress.error ?? 'Error desconocido.',
                key: const ValueKey('bootstrap-error'),
                style: TextStyle(color: colors.error),
              )
            : Column(
                key: const ValueKey('bootstrap-progress'),
                children: [
                  _InitialHistoryProgressRow(
                    label: 'Marcadores',
                    value: progress.markers,
                  ),
                  _InitialHistoryProgressRow(
                    label: 'Mediciones',
                    value: progress.measurements,
                  ),
                  _InitialHistoryProgressRow(
                    label: 'Favoritos',
                    value: progress.favorites,
                  ),
                ],
              ),
      ),
    );
  }
}

class _InitialHistoryProgressRow extends StatelessWidget {
  const _InitialHistoryProgressRow({required this.label, required this.value});

  final String label;
  final InitialHistoryEntityProgress value;

  @override
  Widget build(BuildContext context) {
    final ratio = value.total == 0 ? 1.0 : value.completed / value.total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          SizedBox(
            width: 92,
            child: LinearProgressIndicator(value: ratio.clamp(0.0, 1.0)),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 62,
            child: Text(
              '${value.completed} / ${value.total}',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.service, required this.onCopyUuid});

  final SynchronizationService service;
  final VoidCallback onCopyUuid;

  @override
  Widget build(BuildContext context) {
    final device = service.device;
    return _SyncCard(
      title: 'Dispositivo',
      icon: AppIcons.device,
      child: Column(
        children: [
          _InfoRow(label: 'Nombre', value: _fallback(device.name)),
          _UuidRow(uuid: device.uuid, onCopy: onCopyUuid),
          _InfoRow(label: 'Versión', value: _fallback(device.appVersion)),
          _InfoRow(label: 'Plataforma', value: _fallback(device.platform)),
        ],
      ),
    );
  }
}

class _DevicesCard extends StatelessWidget {
  const _DevicesCard({
    required this.service,
    required this.onAdd,
    required this.onInspect,
    required this.onRename,
    required this.onRemove,
  });

  final DevicePairingService service;
  final VoidCallback onAdd;
  final ValueChanged<PairedDevice> onInspect;
  final ValueChanged<PairedDevice> onRename;
  final ValueChanged<PairedDevice> onRemove;

  @override
  Widget build(BuildContext context) {
    final devices = service.devices;
    return _SyncCard(
      title: 'Dispositivos',
      icon: AppIcons.device,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSwitcher(
            duration: AppMotion.duration(
              context,
              const Duration(milliseconds: 200),
            ),
            child: devices.isEmpty
                ? _EmptyDevices(
                    key: const ValueKey('empty-devices'),
                    loading: service.status == DevicePairingStatus.loading,
                    configured: service.isConfigured,
                  )
                : Column(
                    key: ValueKey(
                      devices.map((item) => item.deviceUuid).join(),
                    ),
                    children: [
                      for (var index = 0; index < devices.length; index++) ...[
                        _DeviceListTile(
                          device: devices[index],
                          onInspect: () => onInspect(devices[index]),
                          onRename: () => onRename(devices[index]),
                          onRemove: devices[index].isCurrentDevice
                              ? null
                              : () => onRemove(devices[index]),
                        ),
                        if (index < devices.length - 1)
                          const Divider(height: 16),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const ValueKey('add-device-button'),
            onPressed: service.isBusy ? null : onAdd,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Agregar dispositivo'),
          ),
        ],
      ),
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({
    required this.loading,
    required this.configured,
    super.key,
  });

  final bool loading;
  final bool configured;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        height: 72,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Row(
      children: [
        Icon(
          configured ? Icons.devices_other_outlined : Icons.cloud_off_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            configured
                ? 'No hay dispositivos vinculados.'
                : 'Configurá Supabase para vincular dispositivos.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _DeviceListTile extends StatelessWidget {
  const _DeviceListTile({
    required this.device,
    required this.onInspect,
    required this.onRename,
    required this.onRemove,
  });

  final PairedDevice device;
  final VoidCallback onInspect;
  final VoidCallback onRename;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(13),
          ),
          alignment: Alignment.center,
          child: Icon(_platformIcon(device.platform), color: colors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      device.deviceName.trim().isEmpty
                          ? 'Dispositivo'
                          : device.deviceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (device.isCurrentDevice) ...[
                    const SizedBox(width: 8),
                    _SmallBadge(label: 'Actual', color: colors.primary),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              Text(
                '${_fallback(device.platform)} · '
                '${device.lastSynchronizationAt == null ? 'Nunca sincronizado' : _relativeTime(device.lastSynchronizationAt)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        PopupMenuButton<_DeviceAction>(
          tooltip: 'Acciones del dispositivo',
          onSelected: (action) {
            switch (action) {
              case _DeviceAction.inspect:
                return onInspect();
              case _DeviceAction.rename:
                return onRename();
              case _DeviceAction.remove:
                return onRemove?.call();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: _DeviceAction.inspect,
              child: ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('Ver información'),
              ),
            ),
            const PopupMenuItem(
              value: _DeviceAction.rename,
              child: ListTile(
                leading: Icon(Icons.edit_outlined),
                title: Text('Renombrar'),
              ),
            ),
            if (onRemove != null)
              const PopupMenuItem(
                value: _DeviceAction.remove,
                child: ListTile(
                  leading: Icon(Icons.link_off_rounded),
                  title: Text('Quitar dispositivo'),
                ),
              ),
          ],
          icon: const Icon(Icons.more_vert_rounded),
        ),
      ],
    );
  }
}

enum _DeviceAction { inspect, rename, remove }

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _OperationsCard extends StatelessWidget {
  const _OperationsCard({required this.service});

  final SynchronizationService service;

  @override
  Widget build(BuildContext context) {
    return _SyncCard(
      title: 'Cambios pendientes',
      icon: AppIcons.queue,
      child: Column(
        children: [
          _MetricRow(
            icon: AppIcons.upload,
            label: 'Subidas pendientes',
            value: service.pendingUploads,
          ),
          _MetricRow(
            icon: AppIcons.download,
            label: 'Descargas pendientes',
            value: service.pendingDownloads,
          ),
          _MetricRow(
            icon: AppIcons.refresh,
            label: 'Reintentos',
            value: service.retryCount,
          ),
          _MetricRow(
            icon: AppIcons.queue,
            label: 'Tamaño de cola',
            value: service.queueSize,
          ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.service});

  final SynchronizationService service;

  @override
  Widget build(BuildContext context) {
    final waiting = service.engineStatus == SyncStatus.waitingConnection;
    final connection = waiting
        ? 'Esperando'
        : service.connectivityStatus == ConnectivityStatus.online
        ? 'En línea'
        : 'Sin conexión';
    final serviceStatus =
        service.isBackendConfigured &&
            !service.isBackendConnected &&
            service.lastError?.trim().isNotEmpty == true
        ? 'Error de inicializaci\u00f3n'
        : !service.isBackendConfigured
        ? 'No configurado'
        : service.isBackendConnected
        ? 'Conectado'
        : 'Esperando conexión';
    return _SyncCard(
      title: 'Conexión y servicio',
      icon: AppIcons.connection,
      child: Column(
        children: [
          _InfoRow(label: 'Conexión', value: connection),
          _InfoRow(label: 'Servicio', value: serviceStatus),
        ],
      ),
    );
  }
}

class _LastSyncCard extends StatelessWidget {
  const _LastSyncCard({required this.service});

  final SynchronizationService service;

  @override
  Widget build(BuildContext context) {
    final lastSync = service.lastSuccessfulAt;
    return _SyncCard(
      title: 'Última sincronización',
      icon: AppIcons.synchronization,
      child: AnimatedSwitcher(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 200),
        ),
        child: Column(
          key: ValueKey(lastSync?.minute),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _relativeTime(lastSync),
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              lastSync == null
                  ? 'Sin sincronizaciones registradas.'
                  : _exactDateTime(lastSync),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({
    required this.service,
    required this.feedback,
    required this.onSynchronize,
    required this.onRetry,
    required this.onClear,
  });

  final SynchronizationService service;
  final _SyncButtonFeedback feedback;
  final VoidCallback onSynchronize;
  final VoidCallback onRetry;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final busy =
        const {
          SyncStatus.scanning,
          SyncStatus.preparing,
          SyncStatus.uploading,
          SyncStatus.downloading,
        }.contains(service.engineStatus) ||
        feedback == _SyncButtonFeedback.running;
    final success = feedback == _SyncButtonFeedback.success;
    return _SyncCard(
      title: 'Acciones manuales',
      icon: AppIcons.refresh,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton(
            onPressed: busy ? null : onSynchronize,
            child: AnimatedSwitcher(
              duration: AppMotion.duration(
                context,
                const Duration(milliseconds: 180),
              ),
              child: Row(
                key: ValueKey((busy, success)),
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    const SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      success ? AppIcons.check : AppIcons.synchronization,
                      size: 18,
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      busy
                          ? 'Sincronizando...'
                          : success
                          ? 'Sincronizado'
                          : 'Sincronizar ahora',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: busy || !service.hasFailedOperations ? null : onRetry,
            icon: const Icon(AppIcons.refresh),
            label: const Text('Reintentar fallos'),
          ),
          TextButton.icon(
            onPressed: busy || service.queueSize == 0 ? null : onClear,
            icon: const Icon(AppIcons.delete),
            label: const Text('Limpiar cola local'),
          ),
        ],
      ),
    );
  }
}

class _AdvancedCard extends StatelessWidget {
  const _AdvancedCard({
    required this.service,
    required this.onCopyUuid,
    required this.onReuploadLocalData,
  });

  final SynchronizationService service;
  final VoidCallback onCopyUuid;
  final VoidCallback onReuploadLocalData;

  @override
  Widget build(BuildContext context) {
    return _SyncCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        leading: const Icon(AppIcons.information),
        title: const Text('Avanzado'),
        subtitle: const Text('Información de diagnóstico'),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        children: [
          _InfoRow(label: 'SyncEngine', value: service.engineStatus.name),
          _InfoRow(label: 'Backend adapter', value: service.backendAdapter),
          _InfoRow(
            label: 'Intervalo de polling',
            value: _formatDuration(service.currentPollingInterval),
          ),
          _UuidRow(
            label: 'UUID completo',
            uuid: service.device.uuid,
            obscureValue: true,
            onCopy: onCopyUuid,
          ),
          _DiagnosticBlock(
            label: 'Internos de cola',
            value:
                '${service.queueSize} total · '
                '${service.pendingCreates} create · '
                '${service.pendingUpdates} update · '
                '${service.pendingDeletes} delete · '
                '${service.retryCount} reintentos',
          ),
          _DiagnosticBlock(
            label: 'Cursor de última sincronización',
            value: service.lastDownloadCursor?.trim().isNotEmpty == true
                ? service.lastDownloadCursor!
                : 'No disponible',
          ),
          _DiagnosticBlock(
            label: 'Último error',
            value: service.lastError?.trim().isNotEmpty == true
                ? service.lastError!
                : 'Ninguno',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: service.initialHistoryProgress.isRunning
                  ? null
                  : onReuploadLocalData,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Volver a subir datos locales'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncCard extends StatelessWidget {
  const _SyncCard({
    required this.child,
    this.title,
    this.icon,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final String? title;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

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
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 21, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      title!,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: SelectableText(
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

class _UuidRow extends StatelessWidget {
  const _UuidRow({
    required this.uuid,
    required this.onCopy,
    this.label = 'UUID',
    this.obscureValue = false,
  });

  final String label;
  final String uuid;
  final bool obscureValue;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              obscureValue ? 'Oculto' : _shortUuid(uuid),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: 'Copiar UUID completo',
            onPressed: uuid.isEmpty ? null : onCopy,
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticBlock extends StatelessWidget {
  const _DiagnosticBlock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
          Text(
            '$value',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _IconSurface extends StatelessWidget {
  const _IconSurface({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: color),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

_StatusPresentation _statusPresentation(
  BuildContext context,
  SynchronizationService service,
) {
  final colors = Theme.of(context).colorScheme;
  if (service.engineStatus == SyncStatus.error) {
    return _StatusPresentation(
      label: 'Error',
      description: 'No se pudo completar la última sincronización.',
      icon: AppIcons.error,
      color: colors.error,
    );
  }
  if (const {
    SyncStatus.scanning,
    SyncStatus.preparing,
    SyncStatus.uploading,
    SyncStatus.downloading,
  }.contains(service.engineStatus)) {
    return const _StatusPresentation(
      label: 'Sincronizando',
      description: 'Enviando y recibiendo cambios.',
      icon: AppIcons.synchronization,
      color: Color(0xFF3978A8),
    );
  }
  if (service.connectivityStatus == ConnectivityStatus.offline ||
      service.engineStatus == SyncStatus.waitingConnection) {
    return _StatusPresentation(
      label: 'Sin conexión',
      description: 'Los cambios se sincronizarán cuando vuelva la conexión.',
      icon: Icons.cloud_off_outlined,
      color: colors.onSurfaceVariant,
    );
  }
  return switch (service.engineStatus) {
    SyncStatus.scanning ||
    SyncStatus.preparing ||
    SyncStatus.uploading ||
    SyncStatus.downloading ||
    SyncStatus.waitingConnection ||
    SyncStatus.error => throw StateError('Handled above'),
    SyncStatus.queued => _StatusPresentation(
      label: 'Cambios pendientes',
      description: 'Hay cambios locales esperando sincronización.',
      icon: AppIcons.upload,
      color: const Color(0xFFA66A13),
    ),
    SyncStatus.idle || SyncStatus.completed =>
      service.queueSize > 0
          ? _StatusPresentation(
              label: 'Cambios pendientes',
              description: 'Hay cambios locales esperando sincronización.',
              icon: AppIcons.upload,
              color: const Color(0xFFA66A13),
            )
          : _StatusPresentation(
              label: 'Sincronizado',
              description: 'Todos los cambios están actualizados.',
              icon: AppIcons.success,
              color: const Color(0xFF547A3A),
            ),
  };
}

class _StatusPresentation {
  const _StatusPresentation({
    required this.label,
    required this.description,
    required this.icon,
    required this.color,
  });

  final String label;
  final String description;
  final IconData icon;
  final Color color;
}

String _fallback(String value) =>
    value.trim().isEmpty ? 'No disponible' : value;

String _shortUuid(String uuid) {
  if (uuid.length <= 16) return _fallback(uuid);
  return '${uuid.substring(0, 8)}…${uuid.substring(uuid.length - 4)}';
}

String _relativeTime(DateTime? value) {
  if (value == null) return 'Nunca';
  final difference = DateTime.now().difference(value);
  if (difference.inSeconds < 10) return 'Ahora mismo';
  if (difference.inMinutes < 1) return 'Hace ${difference.inSeconds} segundos';
  if (difference.inHours < 1) return 'Hace ${difference.inMinutes} minutos';
  if (difference.inDays < 1) return 'Hace ${difference.inHours} horas';
  return 'Hace ${difference.inDays} días';
}

String _exactDateTime(DateTime value) {
  const months = [
    'ene',
    'feb',
    'mar',
    'abr',
    'may',
    'jun',
    'jul',
    'ago',
    'sep',
    'oct',
    'nov',
    'dic',
  ];
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${value.day} ${months[value.month - 1]} ${value.year} · '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
}

String _formatDuration(Duration? value) {
  if (value == null) return 'No configurado';
  if (value.inSeconds < 60) return '${value.inSeconds} s';
  return '${value.inMinutes} min';
}

IconData _platformIcon(String platform) {
  final normalized = platform.toLowerCase();
  if (normalized.contains('android') || normalized.contains('ios')) {
    return Icons.phone_android_rounded;
  }
  return Icons.computer_rounded;
}
