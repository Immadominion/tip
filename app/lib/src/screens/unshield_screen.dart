/// Taking money back out of the pool.
///
/// The mirror of shielding, and public in the same way: the recipient, the
/// token and the amount are all on chain. What stays hidden is which notes
/// paid for it, and therefore who the sender was.
///
/// Withdrawing to your own public address is the common case and the default,
/// but it is worth knowing that doing so links the two: an observer sees the
/// pool pay an address, and that address is you.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

import '../chain/address.dart';
import '../chain/amount.dart';
import '../chain/token.dart';
import '../privacy/pool_session.dart';
import '../privacy/private_operations.dart';
import '../privacy/privacy_controller.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet_controller.dart';
import 'widgets/operation_progress.dart';

class UnshieldScreen extends StatefulWidget {
  const UnshieldScreen({
    super.key,
    required this.wallet,
    required this.privacy,
  });

  final WalletController wallet;
  final PrivacyController privacy;

  @override
  State<UnshieldScreen> createState() => _UnshieldScreenState();
}

class _UnshieldScreenState extends State<UnshieldScreen> {
  final _amount = TextEditingController();
  final _destination = TextEditingController();

  /// Off by default: most people are moving their own money back.
  bool _elsewhere = false;

  OperationStage? _stage;
  String? _error;
  String? _outcome;

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
    _destination.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amount.dispose();
    _destination.dispose();
    super.dispose();
  }

  bool get _running => _stage != null;

  TipToken get _token => widget.wallet.network.feeToken;
  TokenAmount get _shielded => widget.privacy.shieldedBalance(_token);

  String? get _amountProblem {
    if (_amount.text.isEmpty) return null;
    final amount = TokenAmount.tryParse(_amount.text, _token);
    if (amount == null) return 'That is not an amount';
    if (amount.isZero) return 'Enter an amount above zero';
    if (amount > _shielded) {
      return 'You have ${_shielded.formatWithSymbol()} shielded';
    }
    return null;
  }

  String? get _destinationProblem {
    if (!_elsewhere || _destination.text.isEmpty) return null;
    return StarknetAddress.problemWith(_destination.text);
  }

  bool get _ready =>
      !_running &&
      _amount.text.isNotEmpty &&
      _amountProblem == null &&
      _destinationProblem == null &&
      (!_elsewhere || _destination.text.isNotEmpty);

  Future<void> _unshield() async {
    final session = widget.privacy.session;
    final amount = TokenAmount.tryParse(_amount.text, _token);
    if (session == null || amount == null) return;

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

      final to = _elsewhere
          ? StarknetAddress.parse(_destination.text).toBigInt()
          : widget.wallet.keys.accountAddress.toBigInt();

      final sent = await operations.unshield(
        to: to,
        token: _token,
        amount: amount.raw,
        available: widget.privacy.notes,
      );

      if (!mounted) return;
      setState(() => _stage = OperationStage.waiting);

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
      appBar: AppBar(title: const Text('Unshield')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: _outcome != null
              ? _Result(outcome: _outcome!)
              : _running
                  ? OperationProgress(stage: _stage!)
                  : _form(),
        ),
      ),
    );
  }

  Widget _form() {
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Amount', style: text.labelSmall),
            const Spacer(),
            Text('Shielded ${_shielded.formatWithSymbol()}',
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
            errorText: _amountProblem,
            suffixText: _token.symbol,
          ),
        ),

        const SizedBox(height: TipTheme.spaceLg),
        SwitchListTile(
          value: _elsewhere,
          onChanged: (value) => setState(() => _elsewhere = value),
          contentPadding: EdgeInsets.zero,
          title: Text('Send it somewhere else', style: text.titleMedium),
          subtitle: Text(
            'By default it comes back to this wallet.',
            style: text.labelSmall,
          ),
        ),
        if (_elsewhere) ...[
          const SizedBox(height: TipTheme.spaceXs),
          TextField(
            controller: _destination,
            autocorrect: false,
            enableSuggestions: false,
            style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: '0x...',
              errorText: _destinationProblem,
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                tooltip: 'Paste',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    _destination.text = data!.text!.trim();
                  }
                },
              ),
            ),
          ),
        ],

        const SizedBox(height: TipTheme.spaceLg),
        _Linkage(toSelf: !_elsewhere),

        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(message: _error!),
        ],

        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: _ready ? _unshield : null,
          child: const Text('Unshield'),
        ),
        const SizedBox(height: TipTheme.spaceSm),
        Text(
          'About a minute. The proof is built remotely.',
          style: text.labelSmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// What a withdrawal gives away, which depends on where it goes.
class _Linkage extends StatelessWidget {
  const _Linkage({required this.toSelf});

  final bool toSelf;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.visibility_outlined,
              size: 18, color: TipPalette.warning),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The withdrawal is public',
                  style: text.titleSmall?.copyWith(color: TipPalette.warning),
                ),
                const SizedBox(height: 4),
                Text(
                  toSelf
                      ? 'Anyone can see the pool paying this wallet, and how '
                          'much. What stays hidden is which notes paid, and so '
                          'where the money came from.'
                      : 'Anyone can see the pool paying that address, and how '
                          'much. Sending it somewhere that is not obviously '
                          'yours is what keeps the two apart.',
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
  const _Result({required this.outcome});

  final String outcome;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ok = outcome == 'SUCCEEDED';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: TipTheme.spaceXl),
        Icon(
          ok ? Icons.check_circle_rounded : Icons.error_rounded,
          size: 56,
          color: ok ? TipPalette.positive : TipPalette.negative,
        ),
        const SizedBox(height: TipTheme.spaceLg),
        Text(
          ok ? 'Unshielded' : 'It did not go through',
          style: text.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: TipTheme.spaceXs),
        Text(
          ok
              ? 'It is out of the pool and spendable normally.'
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
