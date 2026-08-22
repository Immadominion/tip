/// The pool's `ClientAction` enum, encoded for Cairo.
///
/// A private transaction is a batch of these actions compiled and proved
/// together. Ported from `packages/privacy/src/actions.cairo` in
/// starkware-libs/starknet-privacy.
///
/// Each action validates itself on construction against the same conditions the
/// contract asserts. That is deliberate: proving takes on the order of half a
/// minute, so a zero token address caught here saves the user a long wait
/// followed by an opaque on-chain failure.
library;

import '../errors.dart';
import 'serde.dart';

/// Variant indices of the Cairo `ClientAction` enum.
///
/// The order is the declaration order in `actions.cairo` and is part of the
/// wire format. Reordering these silently changes what the contract executes.
enum ClientActionKind {
  setViewingKey,
  openChannel,
  openSubchannel,
  createEncNote,
  createOpenNote,
  deposit,
  useNote,
  withdraw,
  invokeExternal,
  computeAndInvoke;

  int get variantIndex => index;
}

/// One action in a private transaction.
sealed class ClientAction {
  const ClientAction();

  ClientActionKind get kind;

  /// The variant payload, without the leading variant index.
  List<BigInt> encodePayload();

  /// The full Cairo enum encoding: variant index followed by the payload.
  List<BigInt> encode() => [
        BigInt.from(kind.variantIndex),
        ...encodePayload(),
      ];
}

/// Registers the caller's viewing key. Immutable once set.
class SetViewingKey extends ClientAction {
  SetViewingKey({required this.random}) {
    nonZero(felt(random, 'random'), 'random');
  }

  /// Randomness used to encrypt the private key for the auditor.
  final BigInt random;

  @override
  ClientActionKind get kind => ClientActionKind.setViewingKey;

  @override
  List<BigInt> encodePayload() => [random];
}

/// Opens a channel from the caller to a recipient.
class OpenChannel extends ClientAction {
  OpenChannel({
    required this.recipientAddr,
    required this.index,
    required this.random,
    required this.salt,
  }) {
    nonZero(felt(recipientAddr, 'recipientAddr'), 'recipientAddr');
    usize(index, 'index');
    nonZero(felt(random, 'random'), 'random');
    nonZero(felt(salt, 'salt'), 'salt');
  }

  final BigInt recipientAddr;
  final int index;
  final BigInt random;
  final BigInt salt;

  @override
  ClientActionKind get kind => ClientActionKind.openChannel;

  @override
  List<BigInt> encodePayload() => [
        recipientAddr,
        usize(index, 'index'),
        random,
        salt,
      ];
}

/// Opens a per-token subchannel inside an existing channel.
class OpenSubchannel extends ClientAction {
  OpenSubchannel({
    required this.recipientAddr,
    required this.recipientPublicKey,
    required this.channelKey,
    required this.index,
    required this.token,
    required this.salt,
  }) {
    nonZero(felt(recipientAddr, 'recipientAddr'), 'recipientAddr');
    nonZero(
      felt(recipientPublicKey, 'recipientPublicKey'),
      'recipientPublicKey',
    );
    felt(channelKey, 'channelKey');
    usize(index, 'index');
    nonZero(felt(token, 'token'), 'token');
    nonZero(felt(salt, 'salt'), 'salt');
  }

  final BigInt recipientAddr;
  final BigInt recipientPublicKey;
  final BigInt channelKey;
  final int index;
  final BigInt token;
  final BigInt salt;

  @override
  ClientActionKind get kind => ClientActionKind.openSubchannel;

  @override
  List<BigInt> encodePayload() => [
        recipientAddr,
        recipientPublicKey,
        channelKey,
        usize(index, 'index'),
        token,
        salt,
      ];
}

/// Creates an encrypted note payable to a recipient.
class CreateEncNote extends ClientAction {
  CreateEncNote({
    required this.recipientAddr,
    required this.recipientPublicKey,
    required this.token,
    required this.amount,
    required this.index,
    required this.salt,
  }) {
    nonZero(felt(recipientAddr, 'recipientAddr'), 'recipientAddr');
    nonZero(
      felt(recipientPublicKey, 'recipientPublicKey'),
      'recipientPublicKey',
    );
    nonZero(felt(token, 'token'), 'token');
    // A zero amount is allowed on purpose: it lets a client re-create a note at
    // an index burned by a reverted transaction, so index reuse does not leak.
    u128(amount, 'amount');
    usize(index, 'index');
    u128(salt, 'salt');
    if (salt <= BigInt.one) {
      // Salt 0 means the note does not exist and salt 1 is reserved for open
      // notes, so an encrypted note must use something larger.
      throw const ProtocolException(
        'salt must be greater than 1: 0 means absent and 1 is reserved for '
        'open notes',
      );
    }
    if (salt >= twoPow120) {
      throw const ProtocolException('salt must be less than 2^120');
    }
  }

  final BigInt recipientAddr;
  final BigInt recipientPublicKey;
  final BigInt token;
  final BigInt amount;
  final int index;
  final BigInt salt;

  @override
  ClientActionKind get kind => ClientActionKind.createEncNote;

  @override
  List<BigInt> encodePayload() => [
        recipientAddr,
        recipientPublicKey,
        token,
        amount,
        usize(index, 'index'),
        salt,
      ];
}

/// Creates an open, unencrypted zero-value note for a server action to fill.
///
/// Used where the amount is only known at execution time, such as the output of
/// a swap or an inbound bridge transfer.
class CreateOpenNote extends ClientAction {
  CreateOpenNote({
    required this.recipientAddr,
    required this.recipientPublicKey,
    required this.token,
    required this.index,
    required this.random,
  }) {
    nonZero(felt(recipientAddr, 'recipientAddr'), 'recipientAddr');
    nonZero(
      felt(recipientPublicKey, 'recipientPublicKey'),
      'recipientPublicKey',
    );
    nonZero(felt(token, 'token'), 'token');
    usize(index, 'index');
    nonZero(felt(random, 'random'), 'random');
  }

  final BigInt recipientAddr;
  final BigInt recipientPublicKey;
  final BigInt token;
  final int index;
  final BigInt random;

  @override
  ClientActionKind get kind => ClientActionKind.createOpenNote;

  @override
  List<BigInt> encodePayload() => [
        recipientAddr,
        recipientPublicKey,
        token,
        usize(index, 'index'),
        random,
      ];
}

/// Moves tokens into the pool. The public half of shielding.
class Deposit extends ClientAction {
  Deposit({required this.token, required this.amount}) {
    nonZero(felt(token, 'token'), 'token');
    nonZero(u128(amount, 'amount'), 'amount');
  }

  final BigInt token;
  final BigInt amount;

  @override
  ClientActionKind get kind => ClientActionKind.deposit;

  @override
  List<BigInt> encodePayload() => [token, amount];
}

/// Spends a note, publishing its nullifier.
class UseNote extends ClientAction {
  UseNote({
    required this.channelKey,
    required this.token,
    required this.index,
  }) {
    felt(channelKey, 'channelKey');
    nonZero(felt(token, 'token'), 'token');
    usize(index, 'index');
  }

  final BigInt channelKey;
  final BigInt token;
  final int index;

  @override
  ClientActionKind get kind => ClientActionKind.useNote;

  @override
  List<BigInt> encodePayload() => [
        channelKey,
        token,
        usize(index, 'index'),
      ];
}

/// Moves tokens out of the pool to a public address. The public half of
/// unshielding.
class Withdraw extends ClientAction {
  Withdraw({
    required this.toAddr,
    required this.token,
    required this.amount,
    required this.random,
  }) {
    nonZero(felt(toAddr, 'toAddr'), 'toAddr');
    nonZero(felt(token, 'token'), 'token');
    nonZero(u128(amount, 'amount'), 'amount');
    nonZero(felt(random, 'random'), 'random');
  }

  final BigInt toAddr;
  final BigInt token;
  final BigInt amount;
  final BigInt random;

  @override
  ClientActionKind get kind => ClientActionKind.withdraw;

  @override
  List<BigInt> encodePayload() => [toAddr, token, amount, random];
}

/// Calls an external helper contract from inside the pool.
class InvokeExternal extends ClientAction {
  InvokeExternal({required this.contractAddress, required this.calldata}) {
    nonZero(felt(contractAddress, 'contractAddress'), 'contractAddress');
  }

  final BigInt contractAddress;
  final List<BigInt> calldata;

  @override
  ClientActionKind get kind => ClientActionKind.invokeExternal;

  @override
  List<BigInt> encodePayload() => [
        contractAddress,
        ...spanOfFelts(calldata, 'calldata'),
      ];
}

/// Runs a helper's `privacy_compute` and feeds the result into its invoke.
class ComputeAndInvoke extends ClientAction {
  ComputeAndInvoke({
    required this.contractAddress,
    required this.computeAdditionalData,
    required this.invokeAdditionalData,
  }) {
    nonZero(felt(contractAddress, 'contractAddress'), 'contractAddress');
  }

  final BigInt contractAddress;
  final List<BigInt> computeAdditionalData;
  final List<BigInt> invokeAdditionalData;

  @override
  ClientActionKind get kind => ClientActionKind.computeAndInvoke;

  @override
  List<BigInt> encodePayload() => [
        contractAddress,
        ...spanOfFelts(computeAdditionalData, 'computeAdditionalData'),
        ...spanOfFelts(invokeAdditionalData, 'invokeAdditionalData'),
      ];
}

/// Encodes a batch of actions as the `Span<ClientAction>` argument to
/// `compile_actions`: a length felt, then each action's enum encoding.
List<BigInt> encodeActions(List<ClientAction> actions) => [
      BigInt.from(actions.length),
      for (final action in actions) ...action.encode(),
    ];
