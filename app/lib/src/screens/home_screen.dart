/// The wallet's home screen.
///
/// The organising idea is the balance toggle. One wallet, one screen, and a
/// switch between what is public and what is shielded. That framing is what
/// makes a privacy wallet feel like a wallet rather than a tool: the user is
/// not entering a special mode, they are just choosing which of their two
/// balances they are looking at.
///
/// Balances and activity here are placeholders until the pool's index
/// bookkeeping lands. Everything that is real (the address, the keys) comes
/// from the actual derivation.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:starknet/starknet.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet.dart';
import 'receive_screen.dart';
import 'send_screen.dart';

/// Placeholder until the account contract is chosen and deployed.
/// STRK fee token. The same address on mainnet, sepolia, and devnet, per the
/// pool's own constants.
final strkTokenAddress = BigInt.parse(
  '04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d',
  radix: 16,
);

final _accountClassHash = Felt.fromHexString(
  '0x061dac032f228abef9c6626f995015233097ae253a7f72d68552db02f2971b8f',
);

enum BalanceView { public, private }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.mnemonic});

  final String mnemonic;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  BalanceView _view = BalanceView.private;
  late final WalletKeys _keys;

  @override
  void initState() {
    super.initState();
    _keys = WalletFactory(
      accountClassHash: _accountClassHash,
    ).deriveFrom(widget.mnemonic);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: TipPalette.heroGradient),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(TipTheme.spaceLg),
            children: [
              _AccountRow(keys: _keys),
              const SizedBox(height: TipTheme.spaceXl),
              Center(
                child: _BalanceToggle(
                  value: _view,
                  onChanged: (v) => setState(() => _view = v),
                ),
              ),
              const SizedBox(height: TipTheme.spaceLg),
              Center(
                child: Column(
                  children: [
                    Text('\$0.00', style: text.displayLarge),
                    const SizedBox(height: TipTheme.spaceXs),
                    Text(
                      _view == BalanceView.private
                          ? 'Shielded. Visible only to you.'
                          : 'Public. Visible to anyone.',
                      style: text.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: TipTheme.spaceXl),
              _Actions(keys: _keys),
              const SizedBox(height: TipTheme.spaceXl),
              Text('Activity', style: text.titleLarge),
              const SizedBox(height: TipTheme.spaceMd),
              const _EmptyActivity(),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.keys});

  final WalletKeys keys;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: TipPalette.actionGradient,
            borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
          ),
          child: const Icon(
            Icons.shield_outlined,
            color: Colors.white,
            size: 20,
          ),
        ),
        const SizedBox(width: TipTheme.spaceSm + 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Account', style: text.labelSmall),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(
                    ClipboardData(text: keys.accountAddress.toHexString()),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Address copied')),
                  );
                },
                child: Row(
                  children: [
                    Text(keys.shortAddress, style: text.titleMedium),
                    const SizedBox(width: TipTheme.spaceXs),
                    const Icon(
                      Icons.copy_rounded,
                      size: 14,
                      color: TipPalette.inkFaint,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: null,
          icon: const Icon(Icons.settings_outlined),
          color: TipPalette.inkMuted,
        ),
      ],
    );
  }
}

/// The public / private switch.
class _BalanceToggle extends StatelessWidget {
  const _BalanceToggle({required this.value, required this.onChanged});

  final BalanceView value;
  final ValueChanged<BalanceView> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: TipPalette.surfaceSunken,
        borderRadius: BorderRadius.circular(TipTheme.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToggleOption(
            label: 'Private',
            selected: value == BalanceView.private,
            onTap: () => onChanged(BalanceView.private),
          ),
          _ToggleOption(
            label: 'Public',
            selected: value == BalanceView.public,
            onTap: () => onChanged(BalanceView.public),
          ),
        ],
      ),
    );
  }
}

class _ToggleOption extends StatelessWidget {
  const _ToggleOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(
          horizontal: TipTheme.spaceLg,
          vertical: TipTheme.spaceSm + 2,
        ),
        decoration: BoxDecoration(
          color: selected ? TipPalette.surfaceRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(TipTheme.radiusPill),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: TipPalette.ink.withValues(alpha: 0.06),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: text.titleMedium?.copyWith(
            color: selected ? TipPalette.accent : TipPalette.inkMuted,
          ),
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.keys});

  final WalletKeys keys;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            icon: Icons.arrow_upward,
            label: 'Send',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SendScreen(
                  keys: keys,
                  // Empty until discovery runs against real pool state. The
                  // screen handles this honestly: it reports that there is
                  // nothing to spend rather than pretending otherwise.
                  notes: const [],
                  token: strkTokenAddress,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: TipTheme.spaceSm + 4),
        Expanded(
          child: _ActionButton(
            icon: Icons.arrow_downward,
            label: 'Receive',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    ReceiveScreen(address: keys.accountAddress.toHexString()),
              ),
            ),
          ),
        ),
        const SizedBox(width: TipTheme.spaceSm + 4),
        Expanded(
          child: _ActionButton(
            icon: Icons.shield_moon,
            label: 'Shield',
            onTap: () => ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                const SnackBar(
                  content: Text('Shielding needs a funded account'),
                ),
              ),
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: TipTheme.spaceMd),
        decoration: BoxDecoration(
          color: TipPalette.surfaceRaised,
          borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
          border: Border.all(color: TipPalette.border),
        ),
        child: Column(
          children: [
            Icon(icon, color: TipPalette.accent, size: 22),
            const SizedBox(height: TipTheme.spaceXs + 2),
            Text(label, style: text.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _EmptyActivity extends StatelessWidget {
  const _EmptyActivity();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TipTheme.spaceLg),
        child: Column(
          children: [
            const Icon(
              Icons.inbox_outlined,
              size: 28,
              color: TipPalette.inkFaint,
            ),
            const SizedBox(height: TipTheme.spaceSm),
            Text('Nothing here yet', style: text.titleMedium),
            const SizedBox(height: TipTheme.spaceXs),
            Text(
              'Shield some funds to start sending privately.',
              style: text.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
