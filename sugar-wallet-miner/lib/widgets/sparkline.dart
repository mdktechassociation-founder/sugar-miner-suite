/// Charts drawn by hand, because a chart is thirty lines and a dependency is not.
///
/// Two things need a line: the device's hashrate over the last few minutes, and
/// the pool's share history. Both are "a list of numbers, drawn small", so they
/// share one painter.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class Sparkline extends StatelessWidget {
  final List<double> values;
  final Color color;
  final double height;
  final bool fill;
  final String? emptyLabel;

  const Sparkline({
    super.key,
    required this.values,
    this.color = kAccent,
    this.height = 46,
    this.fill = true,
    this.emptyLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            emptyLabel ?? 'collecting…',
            style: const TextStyle(color: kMuted, fontSize: 11.5),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _SparkPainter(values, color, fill)),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final bool fill;
  _SparkPainter(this.values, this.color, this.fill);

  @override
  void paint(Canvas canvas, Size size) {
    var max = values.reduce((a, b) => a > b ? a : b);
    final min = values.reduce((a, b) => a < b ? a : b);
    if (max <= 0) max = 1;
    // A flat line should sit in the middle, not on the ceiling.
    final span = (max - min) < 1e-9 ? max : (max - min);
    final baseline = (max - min) < 1e-9 ? min * 0.5 : min;

    final dx = size.width / (values.length - 1);
    final points = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final v = (values[i] - baseline) / span;
      points.add(Offset(i * dx, size.height - (v.clamp(0.0, 1.0) * (size.height - 6) + 3)));
    }

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      // gentle smoothing: halfway points, so a noisy hashrate reads as a trend
      final prev = points[i - 1];
      final cur = points[i];
      final mid = Offset((prev.dx + cur.dx) / 2, (prev.dy + cur.dy) / 2);
      path.quadraticBezierTo(prev.dx, prev.dy, mid.dx, mid.dy);
      if (i == points.length - 1) path.lineTo(cur.dx, cur.dy);
    }

    if (fill) {
      final area = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.02)],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
      );
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // the last point, so "now" is visible
    canvas.drawCircle(points.last, 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values.length != values.length ||
      (values.isNotEmpty && old.values.isNotEmpty && old.values.last != values.last);
}

/// A ring for a percentage — used for today's mining budget.
class ProgressRing extends StatelessWidget {
  final double fraction;
  final String center;
  final String label;
  final Color color;

  const ProgressRing({
    super.key,
    required this.fraction,
    required this.center,
    required this.label,
    this.color = kAccent,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SizedBox(
            width: 88,
            height: 88,
            child: CustomPaint(
              painter: _RingPainter(fraction.clamp(0.0, 1.0), color),
              child: Center(
                child: Text(center,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: kMuted, fontSize: 11.5)),
        ],
      );
}

class _RingPainter extends CustomPainter {
  final double fraction;
  final Color color;
  _RingPainter(this.fraction, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(4, 4, size.width - 8, size.height - 8);
    canvas.drawArc(
      rect, 0, 6.28318530718,
      false,
      Paint()
        ..color = kLine
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7,
    );
    canvas.drawArc(
      rect, -1.57079632679, 6.28318530718 * fraction,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 7,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.color != color;
}
