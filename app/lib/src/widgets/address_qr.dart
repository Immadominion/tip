/// A QR code, painted rather than imported.
///
/// The `qr` package does the encoding and nothing else, which is the reason it
/// was chosen: it is pure Dart with one dependency, so the only thing this app
/// takes from it is the module grid. Drawing is ours, so the code matches the
/// rest of the product instead of a package's defaults.
library;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

class AddressQr extends StatelessWidget {
  const AddressQr({
    super.key,
    required this.data,
    this.size = 220,
    this.foreground,
    this.background,
  });

  final String data;
  final double size;
  final Color? foreground;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _QrPainter(
          image: QrImage(
            QrCode(
              payload: QrPayload.fromString(data),
              // Medium recovers from about fifteen percent damage. Enough for
              // a phone screen with a fingerprint on it, without inflating the
              // grid to the point where the modules get too small to scan.
              errorCorrectLevel: QrErrorCorrectLevel.medium,
            ),
          ),
          foreground: foreground ?? scheme.onSurface,
          background: background ?? scheme.surface,
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter({
    required this.image,
    required this.foreground,
    required this.background,
  });

  final QrImage image;
  final Color foreground;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    final modules = image.moduleCount;
    final module = size.width / modules;

    // Each module is drawn a hair wider than its cell. Without the overlap,
    // rounding leaves hairline gaps between neighbours that some scanners read
    // as light modules.
    final overlap = module * 0.02;
    final paint = Paint()..color = foreground;

    for (var row = 0; row < modules; row++) {
      for (var col = 0; col < modules; col++) {
        if (!image.isDark(row, col)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            col * module,
            row * module,
            module + overlap,
            module + overlap,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) =>
      old.image != image ||
      old.foreground != foreground ||
      old.background != background;
}
