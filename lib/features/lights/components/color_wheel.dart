import 'dart:math' as math;

import 'package:flutter/material.dart';

class ColorWheel extends StatelessWidget {
  const ColorWheel({super.key, required this.color, required this.onChanged});

  final HSVColor color;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Light color wheel',
    value:
        '${color.hue.round()} degrees hue, '
        '${(color.saturation * 100).round()} percent saturation',
    hint: 'Drag to choose a color, or use the Hue and Saturation sliders.',
    child: SizedBox(
      width: 200,
      height: 200,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final center = size.center(Offset.zero);
          final radius = math.min(size.width, size.height) / 2 - 8;
          void select(Offset position) {
            final offset = position - center;
            final hue =
                (math.atan2(offset.dy, offset.dx) * 180 / math.pi + 360) % 360;
            onChanged(
              color
                  .withHue(offset.distance < .001 ? color.hue : hue)
                  .withSaturation((offset.distance / radius).clamp(0, 1)),
            );
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => select(details.localPosition),
            onPanStart: (details) => select(details.localPosition),
            onPanUpdate: (details) => select(details.localPosition),
            child: CustomPaint(painter: _ColorWheelPainter(color)),
          );
        },
      ),
    ),
  );
}

class _ColorWheelPainter extends CustomPainter {
  const _ColorWheelPainter(this.color);

  final HSVColor color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 8;
    final bounds = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const SweepGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(bounds),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: [Colors.white, Color(0x00FFFFFF)],
        ).createShader(bounds),
    );
    final angle = color.hue * math.pi / 180;
    final selected =
        center +
        Offset(math.cos(angle), math.sin(angle)) * radius * color.saturation;
    canvas.drawCircle(selected, 7, Paint()..color = Colors.white);
    canvas.drawCircle(
      selected,
      7,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      selected,
      4,
      Paint()..color = color.withValue(1).toColor(),
    );
  }

  @override
  bool shouldRepaint(_ColorWheelPainter oldDelegate) =>
      oldDelegate.color != color;
}
