import 'package:flutter/material.dart';

import '../services/windows_update_models.dart';

Future<void> showWindowsUpdateSuccessDialog(
  BuildContext context, {
  required String installedVersion,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      WindowsUpdateSuccessDialog(installedVersion: installedVersion),
  animationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: Duration(milliseconds: 240),
          reverseDuration: Duration(milliseconds: 180),
        ),
);

class WindowsUpdateSuccessDialog extends StatelessWidget {
  const WindowsUpdateSuccessDialog({required this.installedVersion, super.key});

  final String installedVersion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Dialog(
      key: const ValueKey('windows-update-success-dialog'),
      backgroundColor: const Color(0xFFFAF8F0),
      surfaceTintColor: Colors.transparent,
      elevation: 9,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFDEDFD4)),
      ),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 30, 28, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE8EFE2),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.check_rounded,
                    key: const ValueKey('windows-update-success-icon'),
                    size: 32,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '¡SuelosAR se actualizó!',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: const Color(0xFF34372F),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'La actualización se instaló correctamente',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF65685E),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8EFE2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'VERSIÓN ${formatWindowsUpdateVersion(installedVersion)}',
                    key: const ValueKey('windows-update-success-version'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF526B3F),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Ya tenés instalada la última versión de SuelosAR',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF55584F),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('windows-update-success-continue'),
                    onPressed: () => Navigator.of(context).pop(),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: colors.onPrimary,
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Continuar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
