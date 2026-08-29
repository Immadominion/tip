/// A warning that the public balance cannot pay for a private operation.
///
/// Every pool operation costs a fee that the pool collects with `transfer_from`
/// against the wallet's **public** balance, plus ordinary Starknet gas. That is
/// true for unshielding and for a private transfer, both of which otherwise
/// only ever talk about the shielded balance.
///
/// So there is a trap with no warning in it: shield everything, and now the
/// money is in the pool and there is nothing left to pay the fee that would
/// take it out again. The screens validated the amount against the shielded
/// balance and nothing looked at whether the fee could be covered at all. On
/// Sepolia the pool fee alone is 2 STRK and on mainnet it is 6.
///
/// Like [ProverStatus] this warns and does not block. The balance read can be
/// stale or an endpoint can be lying, and refusing to let someone move their
/// own money on the strength of one RPC answer is a worse failure than letting
/// them try. What it must not do is stay silent.
library;

import 'package:flutter/material.dart';

import '../../chain/amount.dart';
import '../../chain/token.dart';
import '../../privacy/pool_session.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';
import '../../wallet/wallet_controller.dart';

class FeeHeadroom extends StatefulWidget {
  const FeeHeadroom({
    super.key,
    required this.session,
    required this.wallet,
  });

  final PoolSession session;
  final WalletController wallet;

  @override
  State<FeeHeadroom> createState() => _FeeHeadroomState();
}

class _FeeHeadroomState extends State<FeeHeadroom> {
  /// Null until the pool answers, so a slow read shows nothing rather than
  /// flashing a warning it is about to withdraw.
  BigInt? _fee;

  TipToken get _token => widget.wallet.network.feeToken;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final fee = await widget.session.feeAmount();
      if (!mounted) return;
      setState(() => _fee = fee);
    } catch (_) {
      // A pool we cannot read is not evidence of anything. Say nothing rather
      // than guessing at a number and warning about it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final fee = _fee;
    if (fee == null) return const SizedBox.shrink();

    final public = widget.wallet.balanceOf(_token);
    if (public.raw >= fee) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    final needed = TokenAmount(fee, _token);

    return Container(
      margin: const EdgeInsets.only(top: TipTheme.spaceMd),
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.account_balance_wallet_outlined,
              size: 18, color: TipPalette.warning),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Not enough to pay the pool fee',
                  style: text.labelMedium?.copyWith(color: TipPalette.warning),
                ),
                const SizedBox(height: 2),
                Text(
                  'The pool charges ${needed.formatWithSymbol()} from your '
                  'public balance, which holds ${public.formatWithSymbol()}. '
                  'Gas is on top of that. Add some to the public side first, '
                  'or this will fail without moving anything.',
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
