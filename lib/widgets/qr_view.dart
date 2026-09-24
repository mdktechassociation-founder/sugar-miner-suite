/// Draws a [QrCode] on screen. Kept in its own file so that `lib/widgets/qr.dart`
/// stays pure Dart: the encoder is verified in CI by running it on the plain Dart
/// VM against a second implementation and a real scanner, and that only works if
/// the file has no Flutter imports.
library;

import 'package:flutter/material.dart';

import 'qr.dart';

/// Draws a [QrCode] at whatever size the layout gives it.
///
/// Three deliberate choices, all of them about scanning rather than looks:
///   * a four-module quiet zone is part of the widget, not the caller's padding,
///     because a QR that touches a card edge is a QR that some cameras miss,
///   * modules are drawn as crisp squares with no anti-aliased rounding — the
///     finder patterns are what a scanner locks onto first, and softening them is
///     the classic way to make a pretty code that will not read,
///   * the code is drawn on white regardless of the app's dark theme, because
///     inverted symbols are rejected by a good number of scanners.
class QrView extends StatelessWidget {
  final QrCode code;

  /// The light background *inside* the quiet zone. White by default: see above.
  final Color background;

  /// Size of the painted symbol including the quiet zone.
  final double size;

  const QrView({
    super.key,
    required this.code,
    required this.size,
    this.background = const Color(0xFFFFFFFF),
  });

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        color: background,
        child: CustomPaint(painter: _QrPainter(code)),
      );
}

class _QrPainter extends CustomPainter {
  static const _quietZone = 4;

  final QrCode code;
  const _QrPainter(this.code);

  @override
  void paint(Canvas canvas, Size size) {
    final total = code.size + _quietZone * 2;
    final module = size.width / total;
    final paint = Paint()..color = const Color(0xFF000000);
    for (var y = 0; y < code.size; y++) {
      for (var x = 0; x < code.size; x++) {
        if (!code.at(x, y)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (x + _quietZone) * module,
            (y + _quietZone) * module,
            // A hair over one module, so neighbouring squares never leave a
            // hairline gap that a scanner reads as a light module.
            module + 0.05,
            module + 0.05,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.code != code;
}
