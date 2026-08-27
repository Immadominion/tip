/// The four things a wallet does with the pool.
///
/// Register, shield, send privately, unshield. Each one is the same shape:
/// read what the pool already holds, build the actions, check they are in an
/// order the pool will accept, prove them, and submit the result.
///
/// This exists because that shape was written three times in throwaway tools
/// before it was written once here, and the parts that are easy to get wrong
/// are not the parts that look hard. The index a note goes at, the order the
/// actions have to be in, and how much the pool is allowed to pull from the
/// caller are all invisible in the happy path and all revert the transaction
/// after a proof has been paid for.
library;

import 'package:tip_privacy/tip_privacy.dart' as tp;

import '../chain/token.dart';
import 'pool_session.dart';

/// A private operation that could not be started.
///
/// Distinct from a submission failing: these are all conditions the wallet can
/// see before spending a proof on them.
class OperationRefused implements Exception {
  const OperationRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a run is doing, for a screen that has to wait through it.
enum OperationStage {
  reading,
  proving,
  submitting,
  waiting,
}

class PrivateOperations {
  PrivateOperations({required this.session, required this.random});

  final PoolSession session;
  final tp.RandomSource random;

  /// Called as the run moves on, so a screen can say which minute it is in.
  ///
  /// Proving alone takes the better part of a minute, and a spinner that says
  /// nothing for that long reads as a hang.
  void Function(OperationStage stage)? onStage;

  void _stage(OperationStage stage) => onStage?.call(stage);

  /// Registers this wallet's viewing key. Once per wallet, before anything.
  Future<PoolSubmission> register() async {
    _stage(OperationStage.reading);
    final self = session.keys.accountAddress.toBigInt();
    if (await session.isRegistered(self)) {
      throw const OperationRefused('This wallet is already registered');
    }

    final actions = tp.buildRegister(random: random);
    return _run(actions, approve: await session.feeAmount());
  }

  /// Moves [amount] of [token] into the pool.
  ///
  /// The first shield also opens the channel and subchannel the note needs,
  /// because a note cannot be created into nothing.
  Future<PoolSubmission> shield({
    required TipToken token,
    required BigInt amount,
  }) async {
    _stage(OperationStage.reading);
    if (amount <= BigInt.zero) {
      throw const OperationRefused('Enter an amount above zero');
    }

    final self = session.keys.accountAddress.toBigInt();
    final publicKey = await _requireRegistered(self);
    final tokenAddress = token.address.toBigInt();
    final channel = session.channelTo(
      recipient: self,
      recipientPublicKey: publicKey,
      token: tokenAddress,
    );

    final setup = await _setupFor(channel);
    final simulator = await _simulatorFor(channel, tokenAddress, setup);
    final batch = simulator.beginBatch();

    final actions = <tp.ClientAction>[
      ...tp.buildChannelSetup(
        recipientAddr: self,
        recipientPublicKey: publicKey,
        channelKey: channel.key,
        token: tokenAddress,
        channelIndex: setup.channelOpen
            ? setup.channelCount
            : batch.takeOutgoingChannelIndex(),
        subchannelIndex: setup.subchannelOpen
            ? setup.subchannelCount
            : batch.takeSubchannelIndex(channel.key),
        random: random,
        channelExists: setup.channelOpen,
        subchannelExists: setup.subchannelOpen,
      ),
      ...tp.buildShield(
        token: tokenAddress,
        amount: amount,
        recipientAddr: self,
        recipientPublicKey: publicKey,
        noteIndex:
            batch.takeNoteIndex(channelKey: channel.key, token: tokenAddress),
        random: random,
      ),
    ];

    // The pool pulls both the deposit and its own fee with transfer_from, so
    // the approval has to cover the pair.
    return _run(
      actions,
      approve: amount + await session.feeAmount(),
      batch: batch,
    );
  }

  /// Sends [amount] of [token] to [recipient], privately.
  ///
  /// The recipient has to be registered: a note is encrypted to their viewing
  /// key, so there is nobody to encrypt it to otherwise.
  Future<PoolSubmission> privateTransfer({
    required BigInt recipient,
    required TipToken token,
    required BigInt amount,
    required List<tp.SpendableNote> available,
  }) async {
    _stage(OperationStage.reading);
    final self = session.keys.accountAddress.toBigInt();
    final selfKey = await _requireRegistered(self);

    final recipientKey = await session.registeredPublicKey(recipient);
    if (recipientKey == BigInt.zero) {
      throw const OperationRefused(
        'That address has not set up private transfers, so there is no key to '
        'encrypt a note to.',
      );
    }

    final tokenAddress = token.address.toBigInt();
    final ours = session.channelTo(
      recipient: self,
      recipientPublicKey: selfKey,
      token: tokenAddress,
    );
    final theirs = session.channelTo(
      recipient: recipient,
      recipientPublicKey: recipientKey,
      token: tokenAddress,
    );

    final setup = await _setupFor(theirs);
    final ourNotes = await session.noteCount(
      channelKey: ours.key,
      token: tokenAddress,
    );

    final simulator = await _simulatorFor(theirs, tokenAddress, setup)
      ..observeNoteCount(
        channelKey: ours.key,
        token: tokenAddress,
        count: ourNotes,
      );
    final batch = simulator.beginBatch();

    final actions = <tp.ClientAction>[
      ...tp.buildChannelSetup(
        recipientAddr: recipient,
        recipientPublicKey: recipientKey,
        channelKey: theirs.key,
        token: tokenAddress,
        channelIndex: setup.channelOpen
            ? setup.channelCount
            : batch.takeOutgoingChannelIndex(),
        subchannelIndex: setup.subchannelOpen
            ? setup.subchannelCount
            : batch.takeSubchannelIndex(theirs.key),
        random: random,
        channelExists: setup.channelOpen,
        subchannelExists: setup.subchannelOpen,
      ),
      ...tp.buildPrivateTransfer(
        available: available,
        token: tokenAddress,
        amount: amount,
        recipientAddr: recipient,
        recipientPublicKey: recipientKey,
        recipientNoteIndex:
            batch.takeNoteIndex(channelKey: theirs.key, token: tokenAddress),
        selfAddr: self,
        selfPublicKey: selfKey,
        changeNoteIndex:
            batch.takeNoteIndex(channelKey: ours.key, token: tokenAddress),
        random: random,
      ),
    ];

    // Nothing enters the pool, so only its own fee is pulled.
    return _run(actions, approve: await session.feeAmount(), batch: batch);
  }

  /// Moves [amount] of [token] out of the pool to a public address.
  Future<PoolSubmission> unshield({
    required BigInt to,
    required TipToken token,
    required BigInt amount,
    required List<tp.SpendableNote> available,
  }) async {
    _stage(OperationStage.reading);
    final self = session.keys.accountAddress.toBigInt();
    final selfKey = await _requireRegistered(self);
    final tokenAddress = token.address.toBigInt();

    final ours = session.channelTo(
      recipient: self,
      recipientPublicKey: selfKey,
      token: tokenAddress,
    );
    final count =
        await session.noteCount(channelKey: ours.key, token: tokenAddress);

    final simulator = tp.PoolSimulator()
      ..observeNoteCount(
        channelKey: ours.key,
        token: tokenAddress,
        count: count,
      );
    final batch = simulator.beginBatch();

    final actions = tp.buildUnshield(
      available: available,
      token: tokenAddress,
      amount: amount,
      toAddr: to,
      selfAddr: self,
      selfPublicKey: selfKey,
      changeNoteIndex:
          batch.takeNoteIndex(channelKey: ours.key, token: tokenAddress),
      random: random,
    );

    return _run(actions, approve: await session.feeAmount(), batch: batch);
  }

  // ---- shared ----------------------------------------------------------

  Future<BigInt> _requireRegistered(BigInt address) async {
    final key = await session.registeredPublicKey(address);
    if (key == BigInt.zero) {
      throw const OperationRefused(
        'This wallet has not registered a viewing key with the pool yet',
      );
    }
    return key;
  }

  Future<_Setup> _setupFor(ChannelRef channel) async {
    final channelOpen = await session.channelExists(channel.channelMarker);
    return _Setup(
      channelOpen: channelOpen,
      subchannelOpen: await session.subchannelExists(channel.subchannelMarker),
      channelCount: await session.outgoingChannelCount(),
      subchannelCount:
          channelOpen ? await session.subchannelCount(channel.key) : 0,
    );
  }

  Future<tp.PoolSimulator> _simulatorFor(
    ChannelRef channel,
    BigInt token,
    _Setup setup,
  ) async =>
      tp.PoolSimulator()
        ..observeNoteCount(
          channelKey: channel.key,
          token: token,
          count: setup.channelOpen
              ? await session.noteCount(channelKey: channel.key, token: token)
              : 0,
        )
        ..observeSubchannelCount(
          channelKey: channel.key,
          count: setup.subchannelCount,
        )
        ..observeOutgoingChannelCount(setup.channelCount);

  /// Checks, proves, submits, and waits.
  ///
  /// [batch] is settled either way: committed when the transaction lands and
  /// abandoned when it does not, because an abandoned batch frees the indices
  /// the pool never took.
  Future<PoolSubmission> _run(
    List<tp.ClientAction> actions, {
    required BigInt approve,
    tp.PoolBatch? batch,
  }) async {
    // Cheap here, expensive from the prover: an out-of-order batch costs a
    // proof and comes back naming neither the action nor the rule.
    tp.assertPhaseOrder(actions);

    try {
      _stage(OperationStage.proving);
      final proof = await session.prove(actions);

      _stage(OperationStage.submitting);
      final submission = await session.submit(proof: proof, approve: approve);

      batch?.commit();
      return submission;
    } catch (_) {
      batch?.abandon();
      rethrow;
    }
  }
}

class _Setup {
  const _Setup({
    required this.channelOpen,
    required this.subchannelOpen,
    required this.channelCount,
    required this.subchannelCount,
  });

  final bool channelOpen;
  final bool subchannelOpen;
  final int channelCount;
  final int subchannelCount;
}
