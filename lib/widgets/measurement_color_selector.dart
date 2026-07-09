import 'package:flutter/material.dart';

import '../constants/app_icons.dart';
import '../models/measurement_color_option.dart';

class MeasurementColorSelector extends StatelessWidget {
  const MeasurementColorSelector({
    required this.selectedColor,
    required this.onChanged,
    super.key,
  });

  final MeasurementColorOption selectedColor;
  final ValueChanged<MeasurementColorOption> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        for (final color in MeasurementColorOption.values)
          _MeasurementColorButton(
            color: color,
            selected: color == selectedColor,
            onPressed: () => onChanged(color),
          ),
      ],
    );
  }
}

class _MeasurementColorButton extends StatelessWidget {
  const _MeasurementColorButton({
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final MeasurementColorOption color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: color.label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkResponse(
          radius: 18,
          onTap: onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? colorScheme.onSurface : colorScheme.surface,
                width: selected ? 3 : 2,
              ),
            ),
            child: SizedBox.square(
              dimension: 24,
              child: selected
                  ? Icon(AppIcons.check, size: 16, color: color.onColor)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
