/// Sending tokens.
///
/// Three stages, deliberately separate: compose, review, and the result. The
/// review stage exists because a quote is the only place the wallet knows the
/// real fee and whether the transfer can happen at all, and a user should see
/// that before a signature rather than after a revert.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:starknet/starknet.dart';

import '../activity/activity_entry.dart';
import '../chain/address.dart';
import '../chain/amount.dart';
import '../chain/chain_client.dart';
import '../chain/token.dart';
import '../chain/transfer_service.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet_controller.dart';

enum _Stage { compose, review, sending, done }

class SendScreen extends StatefulWidget {
  const SendScreen({super.key, required this.wallet, this.initialToken});

  final WalletController wallet;
  final TipToken? initialToken;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _recipient = TextEditingController();
  final _amount = TextEditingController();

  late TipToken _token = widget.initialToken ?? widget.wallet.network.feeToken;
  late final TransferService _service =
      TransferService(client: widget.wallet.client);

  _Stage _stage = _Stage.compose;
  bool _busy = false;
  TransferQuote? _quote;
  Felt? _hash;
  TransactionResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _recipient.addListener(() => setState(() {}));
    _amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _recipient.dispose();
    _amount.dispose();
    super.dispose();
  }

  String? get _recipientProblem =>
      _recipient.text.isEmpty ? null : StarknetAddress.problemWith(_recipient.text);

  String? get _amountProblem {
    if (_amount.text.isEmpty) return null;
    try {
      TokenAmount.parse(_amount.text, _token);
      return null;
    } on AmountFormatException catch (error) {
      return error.message;
    }
  }

  bool get _composeReady =>
      _recipient.text.isNotEmpty &&
      _amount.text.isNotEmpty &&
      _recipientProblem == null &&
      _amountProblem == null;

  Future<void> _fillMax() async {
    setState(() => _busy = true);
    try {
      final max = await _service.maxSendable(
        from: widget.wallet.keys.signing,
        token: _token,
      );
      _amount.text = max.formatExact();
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _review() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final quote = await _service.quote(
        from: widget.wallet.keys.signing,
        token: _token,
        recipient: StarknetAddress.parse(_recipient.text),
        amount: TokenAmount.parse(_amount.text, _token),
      );
      setState(() {
        _quote = quote;
        _stage = _Stage.review;
      });
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final quote = _quote;
    if (quote == null) return;

    setState(() {
      _stage = _Stage.sending;
      _error = null;
    });
    try {
      final hash = await _service.send(from: widget.wallet.keys.signing, quote: quote);
      setState(() => _hash = hash);

      // Recorded on submission, not on success. A transaction that is in
      // flight when the app is killed still happened, and a wallet that only
      // logs confirmed sends loses exactly the ones a user most wants to look
      // up later.
      await widget.wallet.record(
        ActivityEntry.send(
          txHash: hash.toHexString(),
          amount: quote.amount,
          counterparty: quote.recipient.toHexString(),
          submittedAt: DateTime.now(),
        ),
      );

      final result = await widget.wallet.client.awaitTransaction(hash);
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _Stage.done;
      });
      unawaited(widget.wallet.refresh());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _stage = _Stage.review;
      });
    }
  }

  Future<void> _deploy() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hash = await _service.deployAccount(widget.wallet.keys.signing);
      await widget.wallet.record(
        ActivityEntry.deploy(
          txHash: hash.toHexString(),
          submittedAt: DateTime.now(),
        ),
      );
      final result = await widget.wallet.client.awaitTransaction(hash);
      if (!mounted) return;
      if (result.outcome == TransactionOutcome.succeeded) {
        await widget.wallet.refresh();
        await _review();
      } else {
        setState(() => _error = 'Deployment did not go through: '
            '${result.failureReason ?? result.outcome.name}');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_stage) {
          _Stage.compose => 'Send',
          _Stage.review => 'Review',
          _Stage.sending => 'Sending',
          _Stage.done => 'Sent',
        }),
        leading: _stage == _Stage.review
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _stage = _Stage.compose),
              )
            : null,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: switch (_stage) {
            _Stage.compose => _compose(),
            _Stage.review => _review_(),
            _Stage.sending => _sending(),
            _Stage.done => _done(),
          },
        ),
      ),
    );
  }

  Widget _compose() {
    final text = Theme.of(context).textTheme;
    final balance = widget.wallet.balanceOf(_token);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('To', style: text.labelSmall),
        const SizedBox(height: TipTheme.spaceXs),
        TextField(
          controller: _recipient,
          autocorrect: false,
          enableSuggestions: false,
          style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: '0x...',
            errorText: _recipientProblem,
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              tooltip: 'Paste',
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) _recipient.text = data!.text!.trim();
              },
            ),
          ),
        ),
        const SizedBox(height: TipTheme.spaceLg),

        Row(
          children: [
            Text('Amount', style: text.labelSmall),
            const Spacer(),
            Text('Balance ${balance.formatWithSymbol()}', style: text.labelSmall),
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
            suffixIcon: TextButton(
              onPressed: _busy ? null : _fillMax,
              child: const Text('Max'),
            ),
          ),
        ),
        const SizedBox(height: TipTheme.spaceMd),

        _TokenPicker(
          tokens: widget.wallet.network.tokens,
          selected: _token,
          onChanged: (token) => setState(() => _token = token),
        ),

        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(message: _error!),
        ],

        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: _composeReady && !_busy ? _review : null,
          child: _busy ? const _Spinner() : const Text('Review'),
        ),
        const SizedBox(height: TipTheme.spaceMd),
        Text(
          'This is a public transfer. It appears on chain with your address, '
          'the recipient, and the amount.',
          style: text.labelSmall,
        ),
      ],
    );
  }

  // Trailing underscore only because the stage enum already owns the good name.
  Widget _review_() {
    final quote = _quote!;
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Column(
            children: [
              Text(quote.amount.format(), style: text.displayLarge),
              Text(quote.token.symbol, style: text.bodyMedium),
            ],
          ),
        ),
        const SizedBox(height: TipTheme.spaceXl),
        Card(
          child: Column(
            children: [
              _Line(
                label: 'To',
                value: StarknetAddress.short(quote.recipient),
                mono: true,
              ),
              _Line(
                label: 'Network fee',
                value: quote.fee?.formatWithSymbol() ?? 'unknown',
              ),
              _Line(
                label: 'Most it can cost',
                value: quote.maxFee?.formatWithSymbol() ?? 'unknown',
                hint: 'You pay the fee above. This is the ceiling your account '
                    'has to cover for the transaction to be accepted.',
              ),
              _Line(label: 'Network', value: widget.wallet.network.label),
            ],
          ),
        ),

        if (quote.needsDeployment) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(
            message: 'Your account has not been deployed yet. That happens '
                'once, costs a small fee in STRK, and then sending works '
                'normally.',
            tone: TipPalette.warning,
          ),
          const SizedBox(height: TipTheme.spaceMd),
          FilledButton(
            onPressed: _busy ? null : _deploy,
            child: _busy ? const _Spinner() : const Text('Deploy account'),
          ),
        ] else ...[
          for (final blocker in quote.blockers) ...[
            const SizedBox(height: TipTheme.spaceMd),
            _Problem(message: blocker),
          ],
          if (_error != null) ...[
            const SizedBox(height: TipTheme.spaceMd),
            _Problem(message: _error!),
          ],
          const SizedBox(height: TipTheme.spaceXl),
          FilledButton(
            onPressed: quote.canSend ? _confirm : null,
            child: Text('Send ${quote.amount.formatWithSymbol()}'),
          ),
        ],
      ],
    );
  }

  Widget _sending() {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TipTheme.space2xl),
      child: Column(
        children: [
          const CircularProgressIndicator(color: TipPalette.accent),
          const SizedBox(height: TipTheme.spaceLg),
          Text(
            _hash == null ? 'Signing' : 'Waiting for the network',
            style: text.titleMedium,
          ),
          const SizedBox(height: TipTheme.spaceXs),
          Text(
            'Starknet usually takes under a minute.',
            style: text.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _done() {
    final text = Theme.of(context).textTheme;
    final result = _result!;
    final ok = result.outcome == TransactionOutcome.succeeded;

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
          switch (result.outcome) {
            TransactionOutcome.succeeded => 'Sent',
            TransactionOutcome.reverted => 'It did not go through',
            _ => 'Still pending',
          },
          style: text.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: TipTheme.spaceXs),
        Text(
          switch (result.outcome) {
            TransactionOutcome.succeeded =>
              '${_quote!.amount.formatWithSymbol()} is on its way to '
                  '${StarknetAddress.short(_quote!.recipient)}.',
            TransactionOutcome.reverted =>
              // Reverted still costs the fee. Saying so is the difference
              // between a user who is annoyed and one who thinks the wallet
              // stole from them.
              'The transaction reverted and the fee was still charged. '
                  '${result.failureReason ?? ''}',
            _ => 'The network has not confirmed it yet. It may still land.',
          },
          style: text.bodyMedium,
          textAlign: TextAlign.center,
        ),
        if (_hash != null) ...[
          const SizedBox(height: TipTheme.spaceLg),
          Card(
            child: ListTile(
              title: Text('Transaction', style: text.labelSmall),
              subtitle: Text(
                StarknetAddress.short(_hash!, lead: 10, tail: 8),
                style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
              ),
              trailing: const Icon(Icons.copy_rounded, size: 16),
              onTap: () {
                Clipboard.setData(
                  ClipboardData(text: _hash!.toHexString()),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Transaction hash copied')),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _TokenPicker extends StatelessWidget {
  const _TokenPicker({
    required this.tokens,
    required this.selected,
    required this.onChanged,
  });

  final List<TipToken> tokens;
  final TipToken selected;
  final ValueChanged<TipToken> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: TipTheme.spaceSm,
      children: [
        for (final token in tokens)
          ChoiceChip(
            label: Text(token.symbol),
            selected: token == selected,
            onSelected: (_) => onChanged(token),
          ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    this.mono = false,
    this.hint,
  });

  final String label;
  final String value;
  final bool mono;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TipTheme.spaceMd,
        vertical: TipTheme.spaceSm + 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: text.labelSmall),
              Text(
                value,
                style: mono
                    ? text.bodyMedium?.copyWith(fontFamily: 'monospace')
                    : text.titleMedium,
              ),
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: TipTheme.spaceXs),
            Text(hint!, style: text.labelSmall),
          ],
        ],
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.message, this.tone = TipPalette.negative});

  final String message;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: tone),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: tone),
            ),
          ),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
}
