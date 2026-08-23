/// The wallet's home screen.
///
/// The organising idea is the balance toggle. One wallet, one screen, and a
/// switch between what is public and what is shielded. That framing is what
/// makes a privacy wallet feel like a wallet rather than a tool: the user is
/// not entering a special mode, they are just choosing which of their two
/// balances they are looking at.
///
/// The public side reads real balances from the chain. The shielded side says
/// it is not available yet rather than showing a confident zero, because a
/// wallet that reports nothing when it means it cannot see is a wallet that
/// will one day report nothing when the money is gone.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:starknet/starknet.dart';

import '../activity/activity_entry.dart';
import '../chain/address.dart';
import '../chain/amount.dart';
import '../chain/network.dart';
import '../auth/auth_service.dart';
import '../security/app_lock.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet.dart';
import '../wallet/wallet_controller.dart';
import 'claim_screen.dart';
import 'receive_screen.dart';
import 'settings_screen.dart';
import 'tip_screen.dart';
import 'send_screen.dart';

enum BalanceView { public, private }

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.onWalletErased,
    this.lock,
    this.auth,
  });

  final WalletController controller;

  /// Called when the user removes the wallet from this device.
  final VoidCallback onWalletErased;

  /// Passed through to settings, where the lock is turned on and off.
  final AppLock? lock;

  /// Passed through to settings. Null when sign-in is not configured.
  final AuthService? auth;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  BalanceView _view = BalanceView.public;

  WalletController get _wallet => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wallet.startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wallet.stopPolling();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Polling a public endpoint from a backgrounded app is rate limit spent on
    // nobody. Coming back to a stale balance is worse, so it refreshes on the
    // way in rather than continuing to poll on the way out.
    if (state == AppLifecycleState.resumed) {
      _wallet.startPolling();
    } else if (state == AppLifecycleState.paused) {
      _wallet.stopPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: TipPalette.heroGradient),
        child: SafeArea(
          child: ListenableBuilder(
            listenable: _wallet,
            builder: (context, _) => RefreshIndicator(
              color: TipPalette.accent,
              onRefresh: _wallet.refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(TipTheme.spaceLg),
                children: [
                  if (!_wallet.network.isMainnet)
                    _NetworkBanner(label: _wallet.network.label),
                  _AccountRow(
                    keys: _wallet.keys,
                    onSettings: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsScreen(
                          wallet: _wallet,
                          onErased: widget.onWalletErased,
                          lock: widget.lock,
                          auth: widget.auth,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: TipTheme.spaceXl),
                  Center(
                    child: _BalanceToggle(
                      value: _view,
                      onChanged: (v) => setState(() => _view = v),
                    ),
                  ),
                  const SizedBox(height: TipTheme.spaceLg),
                  _Hero(view: _view, wallet: _wallet),
                  const SizedBox(height: TipTheme.spaceXl),
                  _Actions(wallet: _wallet),
                  const SizedBox(height: TipTheme.spaceSm),
                  Center(
                    child: TextButton.icon(
                      icon: const Icon(Icons.link_rounded, size: 16),
                      label: const Text('Someone sent you a tip link?'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ClaimScreen(wallet: _wallet),
                        ),
                      ),
                    ),
                  ),
                  if (_wallet.hasLoaded && !_wallet.isDeployed) ...[
                    const SizedBox(height: TipTheme.spaceMd),
                    const _NotDeployedNote(),
                  ],
                  if (_view == BalanceView.public) ...[
                    const SizedBox(height: TipTheme.spaceXl),
                    _Assets(wallet: _wallet),
                  ],
                  const SizedBox(height: TipTheme.spaceXl),
                  Text('Activity', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: TipTheme.spaceMd),
                  if (_wallet.activity.isEmpty)
                    const _EmptyActivity()
                  else
                    Card(
                      child: Column(
                        children: [
                          for (final entry in _wallet.activity)
                            _ActivityRow(entry: entry, network: _wallet.network),
                        ],
                      ),
                    ),
                  const SizedBox(height: TipTheme.spaceMd),
                  Text(
                    'This list is what this wallet did on this device. It is '
                    'not a chain-wide history.',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Says loudly which chain this is, whenever it is not the real one.
class _NetworkBanner extends StatelessWidget {
  const _NetworkBanner({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: TipTheme.spaceMd),
      padding: const EdgeInsets.symmetric(
        horizontal: TipTheme.spaceMd,
        vertical: TipTheme.spaceSm,
      ),
      decoration: BoxDecoration(
        color: TipPalette.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(TipTheme.radiusPill),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.science_outlined, size: 14, color: TipPalette.warning),
          const SizedBox(width: TipTheme.spaceXs + 2),
          Text(
            '$label. These are not real funds.',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: TipPalette.warning),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.view, required this.wallet});

  final BalanceView view;
  final WalletController wallet;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    if (view == BalanceView.private) {
      return Column(
        children: [
          Text('Not available yet', style: text.titleLarge),
          const SizedBox(height: TipTheme.spaceXs),
          Text(
            'Reading a shielded balance needs the pool. Until then this says '
            'nothing rather than showing you a zero it cannot vouch for.',
            style: text.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    if (!wallet.hasLoaded) {
      return Column(
        children: [
          Text('...', style: text.displayLarge),
          const SizedBox(height: TipTheme.spaceXs),
          Text('Reading the chain', style: text.bodyMedium),
        ],
      );
    }

    final fee = wallet.feeBalance;
    final failed = wallet.error != null ||
        (wallet.balances?.failures.containsKey(fee.token) ?? false);

    return Column(
      children: [
        Text(fee.format(), style: text.displayLarge),
        const SizedBox(height: TipTheme.spaceXs),
        Text(
          failed
              ? 'Could not reach the chain. Pull to retry.'
              : '${fee.token.symbol}. Public, and visible to anyone.',
          style: text.bodyMedium?.copyWith(
            color: failed ? TipPalette.negative : null,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// The account contract does not exist until the first transaction deploys it.
class _NotDeployedNote extends StatelessWidget {
  const _NotDeployedNote();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TipTheme.spaceMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 18, color: TipPalette.inkMuted),
            const SizedBox(width: TipTheme.spaceSm + 2),
            Expanded(
              child: Text(
                'This address can receive right away. Sending needs the account '
                'deployed first, which happens on your first transaction and '
                'costs a small fee in STRK.',
                style: text.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Assets extends StatelessWidget {
  const _Assets({required this.wallet});

  final WalletController wallet;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Assets', style: text.titleLarge),
        const SizedBox(height: TipTheme.spaceMd),
        Card(
          child: Column(
            children: [
              for (final amount in wallet.visibleBalances)
                _AssetRow(
                  amount: amount,
                  unreadable:
                      wallet.balances?.failures.containsKey(amount.token) ??
                          false,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({required this.amount, required this.unreadable});

  final TokenAmount amount;
  final bool unreadable;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TipTheme.spaceMd,
        vertical: TipTheme.spaceSm + 4,
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: TipPalette.accentWash,
            child: Text(
              amount.token.symbol.characters.first,
              style: text.labelSmall?.copyWith(color: TipPalette.accentDeep),
            ),
          ),
          const SizedBox(width: TipTheme.spaceSm + 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(amount.token.symbol, style: text.titleMedium),
                Text(amount.token.name, style: text.labelSmall),
              ],
            ),
          ),
          Text(
            unreadable ? 'unreadable' : amount.format(),
            style: text.titleMedium?.copyWith(
              color: unreadable ? TipPalette.negative : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.keys, required this.onSettings});

  final WalletKeys keys;
  final VoidCallback onSettings;

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
          onPressed: onSettings,
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
  const _Actions({required this.wallet});

  final WalletController wallet;

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
                builder: (_) => SendScreen(wallet: wallet),
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
                builder: (_) => ReceiveScreen(
                  address: wallet.keys.accountAddress.toHexString(),
                  networkLabel: wallet.network.isMainnet
                      ? null
                      : wallet.network.label,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: TipTheme.spaceSm + 4),
        Expanded(
          child: _ActionButton(
            icon: Icons.auto_awesome_rounded,
            label: 'Tip',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TipScreen(wallet: wallet),
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

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.entry, required this.network});

  final ActivityEntry entry;
  final TipNetwork network;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    final (icon, tint) = switch (entry.status) {
      ActivityStatus.succeeded => (
          switch (entry.kind) {
            ActivityKind.claim => Icons.arrow_downward_rounded,
            ActivityKind.tip => Icons.link_rounded,
            _ => Icons.arrow_upward_rounded,
          },
          entry.kind == ActivityKind.claim
              ? TipPalette.positive
              : TipPalette.ink,
        ),
      ActivityStatus.reverted => (Icons.close_rounded, TipPalette.negative),
      _ => (Icons.schedule_rounded, TipPalette.inkMuted),
    };

    final title = switch (entry.kind) {
      ActivityKind.send => 'Sent',
      ActivityKind.deploy => 'Account deployed',
      ActivityKind.tip => 'Tip link created',
      ActivityKind.claim => 'Tip claimed',
    };

    final subtitle = switch (entry.status) {
      ActivityStatus.reverted =>
        'Reverted. The fee was still charged.',
      ActivityStatus.pending => 'Waiting for the network',
      ActivityStatus.unknown => 'Not seen by the network yet',
      ActivityStatus.succeeded => switch (entry.kind) {
          ActivityKind.tip => 'Waiting to be claimed  ·  ${_when(entry.submittedAt)}',
          ActivityKind.claim => _when(entry.submittedAt),
          _ => entry.counterparty == null
              ? _when(entry.submittedAt)
              : 'To ${StarknetAddress.short(Felt.fromHexString(entry.counterparty!))}',
        },
    };

    return ListTile(
      leading: Icon(icon, size: 20, color: tint),
      title: Text(title, style: text.titleMedium),
      subtitle: Text(subtitle, style: text.labelSmall),
      trailing: entry.amountLabel == null
          ? null
          : Text(entry.amountLabel!, style: text.titleMedium),
      onTap: () {
        Clipboard.setData(ClipboardData(text: entry.txHash));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transaction hash copied')),
        );
      },
    );
  }
}

/// Rough age, which is what a person actually wants from a timestamp here.
String _when(DateTime at) {
  final elapsed = DateTime.now().difference(at);
  if (elapsed.inMinutes < 1) return 'Just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
  return '${elapsed.inDays}d ago';
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
              'Transfers you make from this wallet will show up here.',
              style: text.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
