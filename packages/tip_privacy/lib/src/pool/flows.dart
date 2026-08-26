/// Composing the pool's primitive actions into the operations a wallet offers.
///
/// A user thinks in terms of shield, send, and unshield. The pool thinks in
/// terms of deposits, notes, nullifiers, and withdrawals. This module is the
/// translation, including the part that is easy to get wrong: notes are
/// indivisible, so spending one almost always means creating a change note back
/// to yourself.
library;

import '../errors.dart';
import 'actions.dart';

/// A note owned by the wallet, as far as spending is concerned.
class SpendableNote {
  const SpendableNote({
    required this.channelKey,
    required this.token,
    required this.index,
    required this.amount,
  });

  final BigInt channelKey;
  final BigInt token;
  final int index;
  final BigInt amount;
}

/// Which notes to spend, and how much comes back as change.
class NoteSelection {
  const NoteSelection({required this.notes, required this.change});

  final List<SpendableNote> notes;

  /// Total selected minus the amount being spent. Zero when the notes cover the
  /// amount exactly.
  final BigInt change;

  BigInt get total => notes.fold(BigInt.zero, (sum, note) => sum + note.amount);
}

/// Chooses notes to cover [amount] of [token].
///
/// Largest first, which keeps the number of spent notes down. That matters for
/// more than proving cost: every spent note publishes a nullifier, so a
/// transaction that spends eight notes is a more distinctive on-chain event
/// than one that spends two.
///
/// Throws [InsufficientNotesException] when the balance cannot cover [amount],
/// which is a different situation from any protocol error and is worth a
/// different type.
NoteSelection selectNotes({
  required List<SpendableNote> available,
  required BigInt token,
  required BigInt amount,
}) {
  if (amount <= BigInt.zero) {
    throw const ProtocolException('Amount to spend must be positive');
  }

  final candidates = available.where((n) => n.token == token).toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));

  final selected = <SpendableNote>[];
  var total = BigInt.zero;

  for (final note in candidates) {
    if (total >= amount) break;
    selected.add(note);
    total += note.amount;
  }

  if (total < amount) {
    throw InsufficientNotesException(
      requested: amount,
      available: total,
      token: token,
    );
  }

  return NoteSelection(notes: selected, change: total - amount);
}

/// Supplies the random values the protocol requires.
///
/// Every salt and blinding factor must be unpredictable: reusing one links two
/// transactions that should be unrelated. This is an interface purely so tests
/// can pin the values and assert on exact output; production passes the secure
/// default.
abstract class RandomSource {
  BigInt nextFelt();

  /// A note salt: 120 bits, and greater than 1 since 0 and 1 are reserved.
  BigInt nextNoteSalt();
}

/// Registers a viewing key, the one-time setup before anything else works.
List<ClientAction> buildRegister({required RandomSource random}) => [
      SetViewingKey(random: random.nextFelt()),
    ];

/// Moves [amount] of [token] into the pool as a private note.
///
/// Two actions: the public deposit that anyone can see, and the encrypted note
/// that records who it belongs to. Only the deposit is visible on chain.
List<ClientAction> buildShield({
  required BigInt token,
  required BigInt amount,
  required BigInt recipientAddr,
  required BigInt recipientPublicKey,
  required int noteIndex,
  required RandomSource random,
}) =>
    [
      Deposit(token: token, amount: amount),
      CreateEncNote(
        recipientAddr: recipientAddr,
        recipientPublicKey: recipientPublicKey,
        token: token,
        amount: amount,
        index: noteIndex,
        salt: random.nextNoteSalt(),
      ),
    ];

/// Moves [amount] of [token] out of the pool to a public address.
///
/// Spends enough notes to cover the amount, withdraws, and returns any change
/// to a fresh note. The withdrawal itself is public: the recipient, token, and
/// amount are all visible. What stays hidden is which notes paid for it.
List<ClientAction> buildUnshield({
  required List<SpendableNote> available,
  required BigInt token,
  required BigInt amount,
  required BigInt toAddr,
  required BigInt selfAddr,
  required BigInt selfPublicKey,
  required int changeNoteIndex,
  required RandomSource random,
}) {
  final selection =
      selectNotes(available: available, token: token, amount: amount);

  // Change before the withdrawal, not after. The pool applies actions in phase
  // order and creating a note is an earlier phase than withdrawing, so the
  // reverse reverts with ACTIONS_OUT_OF_ORDER.
  return [
    for (final note in selection.notes)
      UseNote(
        channelKey: note.channelKey,
        token: note.token,
        index: note.index,
      ),
    if (selection.change > BigInt.zero)
      CreateEncNote(
        recipientAddr: selfAddr,
        recipientPublicKey: selfPublicKey,
        token: token,
        amount: selection.change,
        index: changeNoteIndex,
        salt: random.nextNoteSalt(),
      ),
    Withdraw(
      toAddr: toAddr,
      token: token,
      amount: amount,
      random: random.nextFelt(),
    ),
  ];
}

/// Sends [amount] of [token] privately to another user.
///
/// Nothing about this is visible on chain beyond the fact that the pool was
/// used: not the sender, not the recipient, not the amount. Spends notes,
/// creates one for the recipient, and returns change to a note of our own.
List<ClientAction> buildPrivateTransfer({
  required List<SpendableNote> available,
  required BigInt token,
  required BigInt amount,
  required BigInt recipientAddr,
  required BigInt recipientPublicKey,
  required int recipientNoteIndex,
  required BigInt selfAddr,
  required BigInt selfPublicKey,
  required int changeNoteIndex,
  required RandomSource random,
}) {
  final selection =
      selectNotes(available: available, token: token, amount: amount);

  return [
    for (final note in selection.notes)
      UseNote(
        channelKey: note.channelKey,
        token: note.token,
        index: note.index,
      ),
    CreateEncNote(
      recipientAddr: recipientAddr,
      recipientPublicKey: recipientPublicKey,
      token: token,
      amount: amount,
      index: recipientNoteIndex,
      salt: random.nextNoteSalt(),
    ),
    if (selection.change > BigInt.zero)
      CreateEncNote(
        recipientAddr: selfAddr,
        recipientPublicKey: selfPublicKey,
        token: token,
        amount: selection.change,
        index: changeNoteIndex,
        salt: random.nextNoteSalt(),
      ),
  ];
}

/// Opens the channel and subchannel a note needs before it can exist.
///
/// A note cannot be created into nothing. `create_enc_note` asserts the
/// subchannel exists, a subchannel needs a channel, and a channel needs both
/// parties registered. For a first shield, where the wallet is paying itself,
/// all three have to be arranged in the same batch as the deposit.
///
/// Returns only what is actually missing, so this is safe to call every time
/// and costs nothing once the setup is done. Opening a channel that already
/// exists reverts the whole transaction.
List<ClientAction> buildChannelSetup({
  required BigInt recipientAddr,
  required BigInt recipientPublicKey,
  required BigInt channelKey,
  required BigInt token,
  required int channelIndex,
  required int subchannelIndex,
  required RandomSource random,
  bool channelExists = false,
  bool subchannelExists = false,
}) =>
    [
      if (!channelExists)
        OpenChannel(
          recipientAddr: recipientAddr,
          index: channelIndex,
          random: random.nextFelt(),
          salt: random.nextFelt(),
        ),
      if (!subchannelExists)
        OpenSubchannel(
          recipientAddr: recipientAddr,
          recipientPublicKey: recipientPublicKey,
          channelKey: channelKey,
          index: subchannelIndex,
          token: token,
          salt: random.nextFelt(),
        ),
    ];
