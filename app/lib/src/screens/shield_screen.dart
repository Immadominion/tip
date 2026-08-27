/// Moving money into the pool.
///
/// The screen has two jobs beyond taking an amount. It has to be honest that
/// the deposit itself is public, because shielding hides what happens *after*
/// it and not the act of doing it. And it has to survive a wait: proving takes
/// the better part of a minute, and a spinner that says nothing for that long
/// reads as a hang.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

import '../chain/amount.dart';
import '../chain/token.dart';
import '../privacy/pool_session.dart';
import '../privacy/private_operations.dart';
import '../privacy/privacy_controller.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet_controller.dart';
import 'widgets/operation_progress.dart';

class ShieldScreen extends StatefulWidget {
  const ShieldScreen({
    super.key,
    required this.wallet,
    required this.privacy,
  });

  final WalletController wallet;
  final PrivacyController privacy;

  @override
  State<ShieldScreen> createState() => _ShieldScreenState();
}

class _ShieldScreenState extends State<ShieldScreen> {
  final _amount = TextEditingController();

  // Only the fee token for now. The pool holds any ERC-20, but a second token
  // needs its own subchannel and there is nothing yet to pick one with.
  late final TipToken _token = widget.wallet.network.feeToken;

  OperationStage? _stage;
  String? _error;
  String? _sentHash;
  String? _outcome;

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  bool get _running => _stage != null;

  TokenAmount? get _parsed => TokenAmount.tryParse(_amount.text, _token);

  String? get _problem {
    if (_amount.text.isEmpty) return null;
    final amount = _parsed;
    if (amount == null) return 'That is not an amount';
    if (amount.isZero) return 'Enter an amount above zero';
    if (amount > widget.wallet.balanceOf(_token)) {
      return 'You have ${widget.wallet.balanceOf(_token).formatWithSymbol()}';
    }
    return null;
  }

  bool get _ready =>
      !_running && _amount.text.isNotEmpty && _problem == null;

  Future<void> _shield() async {
    final amount = _parsed;
    final session = widget.privacy.session;
    if (amount == null || session == null) return;

    setState(() {
      _error = null;
      _stage = OperationStage.reading;
    });

    try {
      final operations = PrivateOperations(
        session: session,
        random: tp.SecureRandomSource(),
      )..onStage = (stage) {
          if (mounted) setState(() => _stage = stage);
        };

      final sent = await operations.shield(token: _token, amount: amount.raw);
      if (!mounted) return;
      setState(() {
        _sentHash = sent.transactionHash.toHexString();
        _stage = OperationStage.waiting;
      });

      final outcome = await session.awaitSettled(sent.transactionHash);
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _stage = null;
      });
      unawaited(widget.privacy.refresh());
      unawaited(widget.wallet.refresh());
    } on OperationRefused catch (refusal) {
      _fail(refusal.message);
    } on PoolException catch (failure) {
      _fail(failure.message);
    } catch (error) {
      _fail('$error');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _stage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shield')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: _outcome != null
              ? _Result(outcome: _outcome!, hash: _sentHash)
              : _running
                  ? OperationProgress(stage: _stage!, hash: _sentHash)
                  : _form(),
        ),
      ),
    );
  }

  Widget _form() {
    final text = Theme.of(context).textTheme;
    final balance = widget.wallet.balanceOf(_token);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Shielded funds can be sent without publishing who you paid or how '
          'much. Getting them in is the part everyone can see.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: TipTheme.spaceXl),

        Row(
          children: [
            Text('Amount', style: text.labelSmall),
            const Spacer(),
            Text('Public balance ${balance.formatWithSymbol()}',
                style: text.labelSmall),
          ],
        ),
        const SizedBox(height: TipTheme.spaceXs),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: text.headlineMedium,
          decoration: InputDecoration(
            hintText: '0',
            errorText: _problem,
            suffixText: _token.symbol,
          ),
        ),

        const SizedBox(height: TipTheme.spaceLg),
        const _PublicDeposit(),

        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(message: _error!),
        ],

        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: _ready ? _shield : null,
          child: const Text('Shield'),
        ),
        const SizedBox(height: TipTheme.spaceSm),
        Text(
          'This takes about a minute. The proof is generated remotely, which '
          'is why it is not instant.',
          style: text.labelSmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// The thing a shield screen must not let anyone misunderstand.
class _PublicDeposit extends StatelessWidget {
  const _PublicDeposit();

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
          const Icon(Icons.visibility_outlined,
              size: 18, color: TipPalette.accentDeep),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The deposit itself is public',
                  style:
                      text.titleSmall?.copyWith(color: TipPalette.accentDeep),
                ),
                const SizedBox(height: 4),
                Text(
                  'Anyone can see that this wallet put this amount into the '
                  'pool. What stays hidden is everything you do with it '
                  'afterwards.',
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

class _Result extends StatelessWidget {
  const _Result({required this.outcome, this.hash});

  final String outcome;
  final String? hash;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ok = outcome == 'SUCCEEDED';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: TipTheme.spaceXl),
        Icon(
          ok ? Icons.shield_rounded : Icons.error_rounded,
          size: 56,
          color: ok ? TipPalette.positive : TipPalette.negative,
        ),
        const SizedBox(height: TipTheme.spaceLg),
        Text(
          ok ? 'Shielded' : 'It did not go through',
          style: text.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: TipTheme.spaceXs),
        Text(
          ok
              ? 'It is in the pool. Sending from here is private.'
              : 'The transaction reverted and the fee was still charged.',
          style: text.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.negative.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: TipPalette.negative),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: TipPalette.negative),
            ),
          ),
        ],
      ),
    );
  }
}
