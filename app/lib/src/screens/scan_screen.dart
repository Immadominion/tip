/// Reading a QR code.
///
/// Two things use this: the send screen, where a scanned address is one that
/// cannot be mistyped, and the claim screen, where scanning is what makes a
/// tip work between two phones in the same room with no chat app in between.
///
/// It pops with the raw string it read. Deciding whether that string is an
/// address, a tip link, or nonsense belongs to whoever asked, because each
/// caller can say something more useful about a wrong answer than this can.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.title, required this.hint});

  final String title;

  /// What the user is meant to point the camera at.
  final String hint;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(
    // One format, because reading a barcode off a cereal box and calling it an
    // address helps nobody.
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// The camera keeps firing after the first hit, and popping twice tears down
  /// a route that is already gone.
  bool _handled = false;

  String? _cameraProblem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: TipPalette.surfaceDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: TipPalette.inkInverse,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_cameraProblem == null)
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) {
                // A simulator has no camera, and a user can refuse one. Both
                // land here, and both need a way out that is not a black
                // rectangle.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _cameraProblem == null) {
                    setState(() => _cameraProblem = _describe(error));
                  }
                });
                return const SizedBox.shrink();
              },
            ),

          if (_cameraProblem != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(TipTheme.spaceXl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.no_photography_outlined,
                      size: 40,
                      color: TipPalette.inkInverseMuted,
                    ),
                    const SizedBox(height: TipTheme.spaceLg),
                    Text(
                      _cameraProblem!,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium
                          ?.copyWith(color: TipPalette.inkInverse),
                    ),
                    const SizedBox(height: TipTheme.spaceXl),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Type it instead'),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            const _Cutout(),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(TipTheme.spaceXl),
                child: Text(
                  widget.hint,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium
                      ?.copyWith(color: TipPalette.inkInverse),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _describe(MobileScannerException error) =>
      switch (error.errorCode) {
        MobileScannerErrorCode.permissionDenied =>
          'tip needs camera access to scan a code. You can turn it on in '
              'Settings, or type the value in by hand.',
        MobileScannerErrorCode.unsupported =>
          'This device has no camera the app can use.',
        _ => 'The camera could not be started.',
      };
}

/// Dims everything but the middle, so it is obvious where to aim.
///
/// The dimming is a single enormous shadow spreading outward from the frame,
/// which cuts a genuine hole rather than laying a translucent panel over the
/// camera. A panel would wash out the very part the user is trying to line up.
class _Cutout extends StatelessWidget {
  const _Cutout();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide * 0.68;
        return IgnorePointer(
          child: Center(
            child: Container(
              width: side,
              height: side,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
                border: Border.all(color: TipPalette.accentBright, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    spreadRadius: 2000,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
