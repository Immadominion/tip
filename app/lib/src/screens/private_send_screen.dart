/// Composing a private transfer, and showing the user what it becomes.
///
/// The interesting part of this screen is the breakdown. A private send is not
/// one movement of money; it is a set of pool actions, and which actions appear
/// is what determines what an observer learns. Spending two notes instead of one
/// is visible on chain as two nullifiers. Change going back to yourself is an
/// extra note. Surfacing that is not a debug view, it is the product: a privacy
/// wallet that hides its own mechanics asks the user to take privacy on faith.
library;

import 'package:flutter/material.dart';
import 'package:tip_privacy/tip_privacy.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet.dart';

class PrivateSendScreen extends StatefulWidget {
  const PrivateSendScreen({
    super.key,
    required this.keys,
    required this.notes,
    required this.token,
  });

  final WalletKeys keys;

  /// What the wallet currently holds in the pool.
  final List<SpendableNote> notes;

  final BigInt token;

  @override
  State<PrivateSendScreen> createState() => _PrivateSendScreenState();
}

class _PrivateSendScreenState extends State<PrivateSendScreen> {
  final _recipient = TextEditingController();
  final _amount = TextEditingController();

  List<ClientAction>? _actions;
  String? _error;

  @override
  void dispose() {
    _recipient.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Send privately')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _recipient,
                decoration: const InputDecoration(
                  labelText: 'Recipient address',
                  hintText: '0x...',
                ),
                autocorrect: false,
              ),
              const SizedBox(height: TipTheme.spaceMd),
              TextField(
                controller: _amount,
                decoration: const InputDecoration(labelText: 'Amount'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: TipTheme.spaceLg),
              FilledButton(
                onPressed: _preview,
                child: const Text('Preview transfer'),
              ),
              if (_error != null) ...[
                const SizedBox(height: TipTheme.spaceMd),
                _ErrorNote(message: _error!),
              ],
              if (_actions != null) ...[
                const SizedBox(height: TipTheme.spaceLg),
                Text('What this transaction does', style: text.titleMedium),
                const SizedBox(height: TipTheme.spaceSm),
                _ActionBreakdown(actions: _actions!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _preview() {
    setState(() {
      _actions = null;
      _error = null;
    });

    final recipient = _parseFelt(_recipient.text);
    if (recipient == null) {
      setState(() => _error = 'That is not a valid address.');
      return;
    }

    final amount = BigInt.tryParse(_amount.text.trim());
    if (amount == null || amount <= BigInt.zero) {
      setState(() => _error = 'Enter an amount greater than zero.');
      return;
    }

    try {
      // Indices are placeholders until the pool simulator can assign them from
      // real on-chain state. Everything else here is the genuine composition.
      final actions = buildPrivateTransfer(
        available: widget.notes,
        token: widget.token,
        amount: amount,
        recipientAddr: recipient,
        recipientPublicKey: recipient,
        recipientNoteIndex: 0,
        selfAddr: widget.keys.accountAddress.toBigInt(),
        selfPublicKey: widget.keys.accountPublicKey.toBigInt(),
        changeNoteIndex: 1,
        random: _SessionRandom(),
      );
      setState(() => _actions = actions);
    } on InsufficientNotesException catch (e) {
      setState(
        () => _error =
            'You have ${e.available} available but tried to send ${e.requested}.',
      );
    } on PrivacyException catch (e) {
      setState(() => _error = e.message);
    }
  }

  BigInt? _parseFelt(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final hex = trimmed.startsWith('0x') ? trimmed.substring(2) : trimmed;
    final value = BigInt.tryParse(hex, radix: 16);
    if (value == null || value == BigInt.zero) return null;
    return value;
  }
}

/// Turns the action list into something a person can read.
class _ActionBreakdown extends StatelessWidget {
  const _ActionBreakdown({required this.actions});

  final List<ClientAction> actions;

  @override
  Widget build(BuildContext context) {
    final spent = actions.whereType<UseNote>().length;
    final created = actions.whereType<CreateEncNote>().length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final action in actions) ...[
          _ActionRow(action: action),
          const SizedBox(height: TipTheme.spaceSm),
        ],
        const SizedBox(height: TipTheme.spaceXs),
        Container(
          padding: const EdgeInsets.all(TipTheme.spaceMd),
          decoration: BoxDecoration(
            color: TipPalette.surfaceSunken,
            borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
          ),
          child: Text(
            'On chain this appears as $spent '
            '${spent == 1 ? 'nullifier' : 'nullifiers'} and $created new '
            '${created == 1 ? 'note' : 'notes'}. The sender, recipient, and '
            'amount are not visible.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action});

  final ClientAction action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (label, detail) = _describe(action);

    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.surfaceRaised,
        borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
        border: Border.all(color: TipPalette.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: TipPalette.accentWash,
              shape: BoxShape.circle,
            ),
            child: Text(
              '${action.kind.variantIndex}',
              style: text.labelSmall?.copyWith(color: TipPalette.accentDeep),
            ),
          ),
          const SizedBox(width: TipTheme.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: text.titleSmall),
                const SizedBox(height: 2),
                Text(detail, style: text.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  (String, String) _describe(ClientAction action) => switch (action) {
    UseNote() => (
      'Spend a note',
      'Publishes a nullifier so the note cannot be spent twice. Which '
          'note it was stays hidden.',
    ),
    CreateEncNote() => (
      'Create a note',
      'An encrypted note only its owner can read.',
    ),
    Deposit() => (
      'Deposit',
      'Moves tokens into the pool. This part is public.',
    ),
    Withdraw() => (
      'Withdraw',
      'Moves tokens out to a public address. Recipient and amount are '
          'visible.',
    ),
    SetViewingKey() => (
      'Register viewing key',
      'One-time setup so incoming notes can be found.',
    ),
    _ => (action.runtimeType.toString(), 'Pool action.'),
  };
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.negative.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: TipPalette.negative),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// Randomness for previewing a transfer.
///
/// Real sends must draw from a secure source: a repeated salt links two notes
/// that should look unrelated. This is adequate for building a preview, and is
/// replaced before anything is signed.
class _SessionRandom implements RandomSource {
  int _counter = 0;

  @override
  BigInt nextFelt() =>
      BigInt.from(DateTime.now().microsecondsSinceEpoch) +
      BigInt.from(++_counter);

  @override
  BigInt nextNoteSalt() =>
      BigInt.from(DateTime.now().microsecondsSinceEpoch) +
      BigInt.from(++_counter);
}
