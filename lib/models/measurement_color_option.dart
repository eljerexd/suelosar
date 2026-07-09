import 'package:flutter/material.dart';

enum MeasurementColorOption {
  blue('blue', 'Azul', Colors.blue, Colors.white),
  orange('orange', 'Naranja', Colors.orange, Colors.black),
  red('red', 'Rojo', Colors.red, Colors.white);

  const MeasurementColorOption(this.id, this.label, this.color, this.onColor);

  final String id;
  final String label;
  final Color color;
  final Color onColor;

  static MeasurementColorOption fromStorageValue(String? value) {
    return values.firstWhere(
      (option) => option.id == value,
      orElse: () => blue,
    );
  }
}
