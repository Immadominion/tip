/// Registering this wallet's viewing key with the pool.
///
/// The one step that has to happen before any of the shielded side works, and
/// it happens exactly once per wallet. Until it does, the pool has no public
/// key to encrypt notes to, so nobody can pay this wallet privately and this
/// wallet cannot shield anything of its own.
///
/// Two things make this worth its own screen rather than a silent step folded
/// into the first shield.
///
/// It costs a real fee and takes about a minute, so doing it invisibly inside
/// something else would make that operation mysteriously slow and mysteriously
/// expensive. And it is irreversible in a way the other operations are not:
/// `SetViewingKey` is write-once, so the key registered here is the key this
/// wallet has forever. That deserves a button someone pressed on purpose.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

import '../activity/activity_entry.dart';
import '../privacy/operation_error.dart';
import '../privacy/privacy_controller.dart';
import '../privacy/pool_session.dart';
import '../privacy/private_operations.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet_controller.dart';
import 'widgets/fee_headroom.dart';
import 'widgets/operation_progress.dart';
import 'widgets/operation_result.dart';
import 'widgets/prover_status.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({
    super.key,
    required this.wallet,
    required this.privacy,
  });

  final WalletController wallet;
  final PrivacyController privacy;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  OperationStage? _stage;
  String? _error;
  String? _sentHash;
  Settlement? _outcome;

  bool get _running => _stage != null;

  Future<void> _register() async {
    final session = widget.privacy.session;
    if (session == null) return;

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

      final sent = await operations.register();
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
          kind: ActivityKind.register,
          submittedAt: DateTime.now(),
        ),
      );

      final outcome = await session.awaitSettled(sent.transactionHash);
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _stage = null;
      });
      // The whole point of the screen: the shielded side should light up behind
      // it without the user having to go looking for a refresh.
      unawaited(widget.privacy.refresh());
      unawaited(widget.wallet.refresh());
    } catch (error) {
      // One path for every failure, because the message a user needs depends on
      // how far the operation got rather than on which type was thrown.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up private balance')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: _outcome != null
              ? OperationResult(
                  settlement: _outcome!,
                  hash: _sentHash,
                  successIcon: Icons.check_circle_rounded,
                  successTitle: 'Private balance is ready',
                  successBody: 'You can shield funds now, and anyone can pay '
                      'you privately.',
                )
              : _running
                  ? OperationProgress(stage: _stage!, hash: _sentHash)
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
        Text(
          'Your private balance needs a viewing key registered with the pool '
          'before it can hold anything. It is a one time step.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: TipTheme.spaceXl),

        const _WhatThisDoes(),

        const SizedBox(height: TipTheme.spaceLg),
        const _OnceOnly(),

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
          onPressed: _running ? null : _register,
          child: const Text('Set up'),
        ),
        const SizedBox(height: TipTheme.spaceSm),
        Text(
          'This takes about a minute and costs a pool fee. The proof is '
          'generated remotely, which is why it is not instant.',
          style: text.labelSmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// What the key actually is, in terms of what it lets happen.
class _WhatThisDoes extends StatelessWidget {
  const _WhatThisDoes();

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
          const Icon(Icons.key_outlined,
              size: 18, color: TipPalette.accentDeep),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Who can see your private balance',
                  style:
                      text.titleSmall?.copyWith(color: TipPalette.accentDeep),
                ),
                const SizedBox(height: 4),
                Text(
                  'The key comes from your recovery phrase, so the same phrase '
                  'gets it back on a new device, and only the public half goes '
                  'on chain.\n\n'
                  'But finding the notes paid to you means asking a discovery '
                  'service, and today that service does the decrypting — so it '
                  'receives your viewing key and can read your shielded '
                  'balance and history. It is StarkWare\u2019s service, not '
                  'ours, and the request is encrypted in transit. Nobody else '
                  'can see it. That is the honest limit of the privacy you get '
                  'today.',
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

/// The part that cannot be undone, said before the button rather than after.
class _OnceOnly extends StatelessWidget {
  const _OnceOnly();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.lock_clock_outlined, size: 16),
        const SizedBox(width: TipTheme.spaceSm),
        Expanded(
          child: Text(
            'The pool accepts a viewing key once and will not replace it. Keep '
            'your recovery phrase and this stays yours; lose it and the '
            'private balance is not recoverable from anywhere else.',
            style: text.bodySmall,
          ),
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
