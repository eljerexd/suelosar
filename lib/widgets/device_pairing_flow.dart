import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../pairing/device_pairing_models.dart';
import '../services/device_pairing_service.dart';
import '../utils/app_motion.dart';

Future<bool> showDevicePairingFlow(
  BuildContext context,
  DevicePairingService service,
) async {
  final screenSize = MediaQuery.sizeOf(context);
  final desktop = screenSize.width >= 700;
  final androidPhone =
      !kIsWeb &&
      Theme.of(context).platform == TargetPlatform.android &&
      screenSize.shortestSide < 600;
  final content = _DevicePairingFlow(
    service: service,
    desktop: desktop,
    androidPhone: androidPhone,
  );
  if (desktop) {
    return await showDialog<bool>(
          context: context,
          builder: (context) => Dialog(
            insetPadding: const EdgeInsets.all(32),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
              child: content,
            ),
          ),
        ) ??
        false;
  }
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (context) {
          final sheet = Material(
            key: androidPhone
                ? const ValueKey('android-phone-pairing-sheet')
                : null,
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            clipBehavior: Clip.antiAlias,
            child: content,
          );
          final screenHeight = MediaQuery.sizeOf(context).height;
          final sheetHeight = screenHeight * (androidPhone ? 0.74 : 0.88);
          return SizedBox(height: sheetHeight, child: sheet);
        },
      ) ??
      false;
}

class _DevicePairingFlow extends StatefulWidget {
  const _DevicePairingFlow({
    required this.service,
    required this.desktop,
    required this.androidPhone,
  });

  final DevicePairingService service;
  final bool desktop;
  final bool androidPhone;

  @override
  State<_DevicePairingFlow> createState() => _DevicePairingFlowState();
}

class _DevicePairingFlowState extends State<_DevicePairingFlow> {
  final _codeController = TextEditingController();
  final _codeFocusNode = FocusNode();
  PairingSession? _session;
  Timer? _countdown;
  _PairingSessionPhase _sessionPhase = _PairingSessionPhase.loading;
  String? _sessionError;
  String? _joinError;
  int _sessionGeneration = 0;
  bool _working = false;
  bool _joining = false;
  bool _scanning = false;
  bool _scanHandled = false;

  bool get _canScan =>
      !kIsWeb &&
      const {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_generateSession());
    });
  }

  @override
  void dispose() {
    _sessionGeneration++;
    _countdown?.cancel();
    _countdown = null;
    _session = null;
    _codeFocusNode.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final panel = AnimatedSwitcher(
      duration: AppMotion.duration(context, const Duration(milliseconds: 200)),
      child: _joining
          ? widget.androidPhone
                ? Align(
                    key: const ValueKey('join'),
                    alignment: Alignment.topCenter,
                    child: _buildJoin(key: const ValueKey('join-content')),
                  )
                : _buildJoin(key: const ValueKey('join'))
          : _buildShare(key: const ValueKey('share')),
    );
    final responsivePanel = widget.androidPhone
        ? _AndroidKeyboardInsetViewport(child: panel)
        : panel;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
          child: Row(
            children: [
              Icon(Icons.devices_other_outlined, color: colors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Agregar dispositivo',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Cerrar',
                onPressed: () => Navigator.pop(context, false),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.qr_code_2_rounded),
                label: Text('Mostrar código'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.link_rounded),
                label: Text('Vincular este equipo'),
              ),
            ],
            selected: {_joining},
            onSelectionChanged: _working
                ? null
                : (value) => _selectJoining(value.first),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: responsivePanel),
      ],
    );
  }

  Widget _buildShare({required Key key}) {
    final session = _session;
    return SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        children: [
          Text(
            'Escaneá este QR desde el dispositivo que querés vincular.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 18),
          if (_sessionPhase == _PairingSessionPhase.loading)
            widget.androidPhone
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: CircularProgressIndicator(),
                  )
                : const SizedBox(
                    height: 220,
                    child: Center(child: CircularProgressIndicator()),
                  )
          else if (_sessionPhase == _PairingSessionPhase.active &&
              session != null) ...[
            Semantics(
              label: 'Código QR de vinculación',
              image: true,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: QrImageView(
                  data: session.qrPayload,
                  size: widget.desktop ? 210 : 190,
                  eyeStyle: QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'O ingresá este código',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            SelectableText(
              session.pairingCode,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Vence en ${_remainingText(session.expiresAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ] else if (_sessionPhase == _PairingSessionPhase.expired) ...[
            const Icon(Icons.timer_off_outlined, size: 44),
            const SizedBox(height: 12),
            const Text('El código venció.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _working ? null : _generateSession,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Generar otro código'),
            ),
          ] else ...[
            const Icon(Icons.cloud_off_outlined, size: 44),
            const SizedBox(height: 12),
            if (widget.androidPhone && _sessionError != null) ...[
              _InlineError(_sessionError!),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: _working ? null : _generateSession,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Reintentar'),
            ),
          ],
          if (!widget.androidPhone &&
              _sessionPhase == _PairingSessionPhase.error &&
              _sessionError != null) ...[
            const SizedBox(height: 14),
            _InlineError(_sessionError!),
          ],
        ],
      ),
    );
  }

  Widget _buildJoin({required Key key}) {
    if (_scanning && _canScan) {
      return _buildScanner(key: key);
    }
    return SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ingresá el código que aparece en el otro dispositivo.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _codeController,
            focusNode: _codeFocusNode,
            enabled: !_working,
            autofocus: widget.desktop,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            onSubmitted: (_) => _submitCode(),
            decoration: const InputDecoration(
              labelText: 'Código de 6 dígitos',
              prefixIcon: Icon(Icons.password_rounded),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _working ? null : _submitCode,
            icon: _working
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link_rounded),
            label: Text(_working ? 'Vinculando...' : 'Vincular dispositivo'),
          ),
          if (_canScan) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _working
                  ? null
                  : () => setState(() {
                      _scanning = true;
                      _scanHandled = false;
                      _joinError = null;
                    }),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Escanear QR'),
            ),
          ],
          if (_joinError != null) ...[
            const SizedBox(height: 14),
            _InlineError(_joinError!),
          ],
        ],
      ),
    );
  }

  Widget _buildScanner({required Key key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Volver al código manual',
                onPressed: _working
                    ? null
                    : () => setState(() => _scanning = false),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              const Expanded(child: Text('Enfocá el código QR')),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: MobileScanner(
                onDetect: (capture) {
                  if (_scanHandled || capture.barcodes.isEmpty) return;
                  final value = capture.barcodes.first.rawValue;
                  if (value == null || value.isEmpty) return;
                  _scanHandled = true;
                  unawaited(_submitToken(value));
                },
                errorBuilder: (context, error) => ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  child: const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No se pudo iniciar la cámara. Usá el código manual.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generateSession() async {
    final generation = ++_sessionGeneration;
    _countdown?.cancel();
    _countdown = null;
    setState(() {
      _working = true;
      _session = null;
      _sessionPhase = _PairingSessionPhase.loading;
      _sessionError = null;
    });
    try {
      final session = await widget.service.createPairingSession();
      if (!mounted || generation != _sessionGeneration) return;
      if (session.isExpired) {
        _expireSession(generation);
        return;
      }
      setState(() {
        _session = session;
        _sessionPhase = _PairingSessionPhase.active;
      });
      _countdown = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _updateCountdown(generation),
      );
    } catch (error) {
      if (!mounted || generation != _sessionGeneration) return;
      setState(() {
        _session = null;
        _sessionPhase = _PairingSessionPhase.error;
        _sessionError = _message(error);
      });
    } finally {
      if (mounted && generation == _sessionGeneration) {
        setState(() => _working = false);
      }
    }
  }

  void _updateCountdown(int generation) {
    if (!mounted || generation != _sessionGeneration) return;
    if (_session?.isExpired == true) {
      _expireSession(generation);
      return;
    }
    setState(() {});
  }

  void _expireSession(int generation) {
    if (!mounted || generation != _sessionGeneration) return;
    _countdown?.cancel();
    _countdown = null;
    setState(() {
      _session = null;
      _sessionPhase = _PairingSessionPhase.expired;
      _sessionError = null;
    });
  }

  void _selectJoining(bool joining) {
    setState(() {
      _joining = joining;
      _scanning = false;
      _joinError = null;
    });
    if (!widget.androidPhone) return;
    if (joining) {
      _codeFocusNode.requestFocus();
    } else {
      _codeFocusNode.unfocus();
    }
  }

  Future<void> _submitCode() {
    final completion = _complete(
      () => widget.service.pairWithCode(_codeController.text),
    );
    if (widget.androidPhone) {
      scheduleMicrotask(_codeFocusNode.unfocus);
    }
    return completion;
  }

  Future<void> _submitToken(String token) async {
    await _complete(() => widget.service.pairWithToken(token));
    if (mounted && _joinError != null) {
      setState(() {
        _scanHandled = false;
        _scanning = false;
      });
    }
  }

  Future<void> _complete(Future<void> Function() operation) async {
    if (_working) return;
    setState(() {
      _working = true;
      _joinError = null;
    });
    try {
      await operation();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _joinError = _message(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _message(Object error) => error is DevicePairingException
      ? error.message
      : 'No se pudo completar la vinculación.';

  String _remainingText(DateTime expiresAt) {
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return '00:00';
    final minutes = remaining.inMinutes.toString().padLeft(2, '0');
    final seconds = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

enum _PairingSessionPhase { loading, active, expired, error }

class _AndroidKeyboardInsetViewport extends StatelessWidget {
  const _AndroidKeyboardInsetViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: child,
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
