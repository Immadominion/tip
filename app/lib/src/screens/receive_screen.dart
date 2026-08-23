/// Where a user finds the address people pay them at.
///
/// Two things share this screen, and keeping them distinct matters. The public
/// address is an ordinary Starknet address: anyone paying it produces a normal,
/// visible transfer. Shielding is what moves those funds into the pool, and only
/// after that does privacy apply. Presenting one address and calling it
/// "private" would be a lie the protocol does not support.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chain/address.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../widgets/address_qr.dart';

class ReceiveScreen extends StatelessWidget {
  const ReceiveScreen({super.key, required this.address, this.networkLabel});

  final String address;

  /// Shown when the wallet is not on mainnet. Someone scanning this code has
  /// no other way to tell that the address only exists on a testnet.
  final String? networkLabel;

  /// The form that goes into the QR code.
  ///
  /// Padded to the full sixty-four digits. Both forms are the same address,
  /// but this is what explorers and other wallets canonicalise to, and a
  /// scanner that string-compares will match it.
  String get _encoded => StarknetAddress.canonical(
        StarknetAddress.parse(address),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(TipTheme.spaceLg),
                  child: Column(
                    children: [
                      Text('Your Starknet address', style: text.titleMedium),
                      const SizedBox(height: TipTheme.spaceLg),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: TipPalette.surfaceRaised,
                          borderRadius:
                              BorderRadius.circular(TipTheme.radiusLarge),
                          border: Border.all(color: TipPalette.border),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(TipTheme.spaceMd),
                          child: AddressQr(
                            data: _encoded,
                            foreground: TipPalette.ink,
                            background: TipPalette.surfaceRaised,
                          ),
                        ),
                      ),
                      if (networkLabel != null) ...[
                        const SizedBox(height: TipTheme.spaceMd),
                        Text(
                          '$networkLabel only. Do not send real funds here.',
                          style: text.labelSmall
                              ?.copyWith(color: TipPalette.warning),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: TipTheme.spaceLg),
                      SelectableText(
                        address,
                        textAlign: TextAlign.center,
                        style: text.bodyLarge?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: TipTheme.spaceLg),
                      FilledButton.icon(
                        onPressed: () => _copy(context),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Copy address'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: TipTheme.spaceLg),
              const _PrivacyNote(),
            ],
          ),
        ),
      ),
    );
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: address));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Address copied')));
  }
}

/// Says plainly what this address does and does not hide.
class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.accentWash,
        borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            size: 18,
            color: TipPalette.accentDeep,
          ),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Payments here are public',
                  style: text.titleSmall?.copyWith(
                    color: TipPalette.accentDeep,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Anyone can see transfers to this address on chain. '
                  'Shield the funds afterwards to move them into the pool, '
                  'where sends become private.',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
