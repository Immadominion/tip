/// Sending from the pool, privately.
///
/// The screen this replaces was a preview that composed actions and showed
/// them. This one sends.
///
/// Two things it has to be straight about. The recipient must already have
/// registered with the pool, because a note is encrypted to their viewing key
/// and there is nobody to encrypt it to otherwise. And unlike the public send
/// screen, nothing here appears on chain: not the amount, not either party.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

import '../chain/address.dart';
import '../activity/activity_entry.dart';
import '../chain/amount.dart';
import '../chain/token.dart';
import '../privacy/operation_error.dart';
import '../privacy/pool_session.dart';
import '../privacy/private_operations.dart';
import '../privacy/privacy_controller.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet_controller.dart';
import 'scan_screen.dart';
import 'widgets/fee_headroom.dart';
import 'widgets/operation_progress.dart';
import 'widgets/operation_result.dart';
import 'widgets/prover_status.dart';

class PrivateSendScreen extends StatefulWidget {
  const PrivateSendScreen({
    super.key,
    required this.wallet,
    required this.privacy,
  });

  final WalletController wallet;
  final PrivacyController privacy;

  @override
  State<PrivateSendScreen> createState() => _PrivateSendScreenState();
}

class _PrivateSendScreenState extends State<PrivateSendScreen> {
  final _recipient = TextEditingController();
  final _amount = TextEditingController();

  OperationStage? _stage;
  String? _error;

  /// Kept so the result screen can show it. It was being dropped, while the
  /// failure copy told the user to go and check the transaction.
  String? _sentHash;
  Settlement? _outcome;

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

  bool get _running => _stage != null;

  TipToken get _token => widget.wallet.network.feeToken;
  TokenAmount get _shielded => widget.privacy.shieldedBalance(_token);

  String? get _recipientProblem => _recipient.text.isEmpty
      ? null
      : StarknetAddress.problemWith(_recipient.text);

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

  bool get _ready =>
      !_running &&
      _recipient.text.isNotEmpty &&
      _amount.text.isNotEmpty &&
      _recipientProblem == null &&
      _amountProblem == null;

  Future<void> _send() async {
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

      final sent = await operations.privateTransfer(
        recipient: StarknetAddress.parse(_recipient.text).toBigInt(),
        token: _token,
        amount: amount.raw,
        available: widget.privacy.notes,
      );

      if (!mounted) return;
      setState(() {
        _sentHash = sent.transactionHash.toHexString();
        _stage = OperationStage.waiting;
      });

      // Recorded before the wait, not after. Starknet's RPC cannot be asked
      // which transactions involved an address, and for a private operation
      // nothing on chain is legible anyway — so if the app is killed during the
      // minute this takes and no row was written, the operation is gone from
      // every record that exists.
      await widget.wallet.record(
        ActivityEntry.pool(
          txHash: sent.transactionHash.toHexString(),
          kind: ActivityKind.privateSend,
          submittedAt: DateTime.now(),
        amount: amount,
        ),
      );

      final outcome = await session.awaitSettled(sent.transactionHash);
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _stage = null;
      });
      unawaited(widget.privacy.refresh());
    } catch (error) {
      // One path for every failure, because the message a user needs depends
      // on how far the operation got rather than on which type was thrown.
      _fail(describeFailure(error, stage: _stage).message);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _stage = null;
    });
  }

  Future<void> _scan() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const ScanScreen(
          title: 'Scan an address',
          hint: 'Point the camera at the recipient address.',
        ),
      ),
    );
    if (scanned != null && mounted) _recipient.text = scanned.trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send privately')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: _outcome != null
              ? OperationResult(
                  settlement: _outcome!,
                  hash: _sentHash,
                  successIcon: Icons.check_circle_rounded,
                  successTitle: 'Sent privately',
                  successBody:
                      'They can see it when their wallet next reads the pool.',
                )
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
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                  tooltip: 'Scan',
                  onPressed: _scan,
                ),
                IconButton(
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  tooltip: 'Paste',
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null) {
                      _recipient.text = data!.text!.trim();
                    }
                  },
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: TipTheme.spaceLg),
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
        const _NothingOnChain(),

        const SizedBox(height: TipTheme.spaceMd),
        Text(
          'The person you are paying has to have set up private transfers '
          'themselves. Their note is encrypted to their viewing key, so there '
          'is nobody to encrypt it to otherwise.',
          style: text.labelSmall,
        ),

        if (widget.privacy.session case final session?) ...[
          FeeHeadroom(session: session, wallet: widget.wallet),
          ProverStatus(session: session),
        ],

        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(message: _error!),
        ],

        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: _ready ? _send : null,
          child: const Text('Send privately'),
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

/// The claim this screen is actually making.
class _NothingOnChain extends StatelessWidget {
  const _NothingOnChain();

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
          const Icon(Icons.shield_outlined,
              size: 18, color: TipPalette.accentDeep),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Nothing about this appears on chain',
                  style:
                      text.titleSmall?.copyWith(color: TipPalette.accentDeep),
                ),
                const SizedBox(height: 4),
                Text(
                  'Not the amount, not you, not them. An observer sees that '
                  'the pool was used and nothing else.',
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
