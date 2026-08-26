/// A local mirror of the pool's index bookkeeping.
///
/// Every note, subchannel and outgoing channel lives at a numbered slot, and
/// the contract will only accept a new one at index zero or directly after an
/// index that already exists. From `privacy.cairo`:
///
///     // Assert index is sequential, i.e. the previous note exists.
///     assert(index.is_zero() || self.notes.entry(
///         compute_note_id(:channel_key, :token, index: index - 1)
///     ).packed_value.read().is_non_zero(), errors::INDEX_NOT_SEQUENTIAL);
///
/// with the same shape guarding channels and subchannels. So a client cannot
/// pick an index freely: it has to know exactly how many slots are already
/// filled, and there is no counter on chain to ask for. This is where that is
/// tracked.
///
/// Three facts from the contract shape everything here.
///
/// Spending a note does not remove it. `use_note` writes a nullifier and
/// leaves `packed_value` untouched, so the sequence only ever grows and a spent
/// note still satisfies the sequential check for the note after it.
///
/// Slots are write-once. A committed index can never be written again, so
/// allocation must not hand the same index out twice.
///
/// A reverted transaction rolls the whole batch back, freeing its indices.
/// They can be used again, but not with the same salts: the encryption keys are
/// derived from the index, so reusing an index and a salt together reuses a
/// one-time key. Hence the split below between allocating and committing.
library;

import '../errors.dart';
import 'actions.dart';

/// Which note sequence an index belongs to.
///
/// Notes are numbered per channel and token, not per channel, because the
/// contract's `compute_note_id` mixes both into the id.
typedef NoteSequence = ({BigInt channelKey, BigInt token});

/// What the pool has already accepted.
///
/// Counts rather than contents: the simulator's job is to know where the next
/// slot is, and what a note holds is discovery's problem.
class PoolState {
  PoolState({
    this.outgoingChannelCount = 0,
    Map<BigInt, int>? subchannelCounts,
    Map<NoteSequence, int>? noteCounts,
    Set<BigInt>? nullifiers,
  })  : subchannelCounts = {...?subchannelCounts},
        noteCounts = {...?noteCounts},
        nullifiers = {...?nullifiers};

  /// How many outgoing channels this wallet has opened.
  ///
  /// One counter, not a map, because the contract derives an outgoing channel
  /// id from the sender's own address and private key. A wallet has one.
  int outgoingChannelCount;

  /// Subchannels opened, per channel key.
  final Map<BigInt, int> subchannelCounts;

  /// Notes created, per channel and token.
  final Map<NoteSequence, int> noteCounts;

  /// Nullifiers seen on chain. A note whose nullifier is here is spent.
  final Set<BigInt> nullifiers;

  PoolState copy() => PoolState(
        outgoingChannelCount: outgoingChannelCount,
        subchannelCounts: subchannelCounts,
        noteCounts: noteCounts,
        nullifiers: nullifiers,
      );
}

/// Indices handed out for one transaction, not yet accepted by the pool.
///
/// Allocations are held here until the transaction is known to have landed.
/// Committing folds them into the confirmed state; abandoning drops them, which
/// is what a reverted transaction needs.
class PoolBatch {
  PoolBatch._(this._simulator, this.baseline);

  final PoolSimulator _simulator;

  /// The state as the pool has it, before this batch allocated anything.
  ///
  /// Kept so an abandoned batch can be rolled back, and so a check of the
  /// actions this batch produced has something to compare them against: the
  /// live counters have already moved past them.
  final PoolState baseline;

  bool _settled = false;

  /// Takes the next free note index in [channelKey] for [token].
  int takeNoteIndex({required BigInt channelKey, required BigInt token}) {
    _assertOpen();
    final sequence = (channelKey: channelKey, token: token);
    final next = _simulator.state.noteCounts[sequence] ?? 0;
    _simulator.state.noteCounts[sequence] = next + 1;
    return next;
  }

  int takeSubchannelIndex(BigInt channelKey) {
    _assertOpen();
    final next = _simulator.state.subchannelCounts[channelKey] ?? 0;
    _simulator.state.subchannelCounts[channelKey] = next + 1;
    return next;
  }

  int takeOutgoingChannelIndex() {
    _assertOpen();
    return _simulator.state.outgoingChannelCount++;
  }

  /// The transaction landed. The indices are now the pool's.
  void commit() {
    _assertOpen();
    _settled = true;
    _simulator._batch = null;
  }

  /// The transaction never landed, so the pool never saw these indices.
  ///
  /// The state goes back exactly as it was. Anything built against this batch
  /// must be rebuilt rather than resubmitted: the indices will be the same, and
  /// reusing their salts with them would reuse a one-time encryption key.
  void abandon() {
    _assertOpen();
    _settled = true;
    _simulator._state = baseline;
    _simulator._batch = null;
  }

  void _assertOpen() {
    if (_settled) {
      throw const ProtocolException(
        'This batch has already been committed or abandoned',
      );
    }
  }
}

class PoolSimulator {
  PoolSimulator({PoolState? state}) : _state = state ?? PoolState();

  PoolState _state;
  PoolBatch? _batch;

  PoolState get state => _state;

  /// True while a transaction's indices are allocated but not settled.
  bool get hasOpenBatch => _batch != null;

  /// Starts allocating indices for one transaction.
  ///
  /// Only one at a time. Two batches open together would both allocate from
  /// the same counters and hand out the same index twice, and the second
  /// transaction to land would be rejected as a write to an occupied slot.
  PoolBatch beginBatch() {
    if (_batch != null) {
      throw const ProtocolException(
        'A batch is already open. Commit or abandon it first.',
      );
    }
    return _batch = PoolBatch._(this, _state.copy());
  }

  /// The index a note would take next, without taking it.
  int peekNoteIndex({required BigInt channelKey, required BigInt token}) =>
      _state.noteCounts[(channelKey: channelKey, token: token)] ?? 0;

  int peekSubchannelIndex(BigInt channelKey) =>
      _state.subchannelCounts[channelKey] ?? 0;

  int get peekOutgoingChannelIndex => _state.outgoingChannelCount;

  /// Records what the chain says, replacing anything held locally.
  ///
  /// The chain is the authority. Local counts are a cache that exists because
  /// the pool has no counter to read, and anywhere the two disagree the chain
  /// is right.
  void observeNoteCount({
    required BigInt channelKey,
    required BigInt token,
    required int count,
  }) {
    if (count < 0) {
      throw const ProtocolException('A note count cannot be negative');
    }
    _state.noteCounts[(channelKey: channelKey, token: token)] = count;
  }

  void observeSubchannelCount({
    required BigInt channelKey,
    required int count,
  }) {
    if (count < 0) {
      throw const ProtocolException('A subchannel count cannot be negative');
    }
    _state.subchannelCounts[channelKey] = count;
  }

  void observeOutgoingChannelCount(int count) {
    if (count < 0) {
      throw const ProtocolException('A channel count cannot be negative');
    }
    _state.outgoingChannelCount = count;
  }

  /// Marks a nullifier as seen on chain.
  void observeNullifier(BigInt nullifier) => _state.nullifiers.add(nullifier);

  bool isSpent(BigInt nullifier) => _state.nullifiers.contains(nullifier);

  /// Checks a batch of actions against the sequential rule before it is sent.
  ///
  /// The contract enforces this anyway, but only after a proof has been
  /// generated, and generating one takes the better part of a minute. A bad
  /// index caught here costs nothing.
  ///
  /// [channelKeyFor] resolves the channel a note will land in. A note action
  /// does not carry its channel key: the contract derives it from the sender's
  /// address and private key together with the recipient's. Without that
  /// resolver this check would be guessing, and a check that guesses is worse
  /// than no check, so it is required rather than defaulted.
  ///
  /// Returns the problems found, empty when the batch is well formed.
  List<String> checkSequential(
    List<ClientAction> actions, {
    required BigInt Function(BigInt recipientAddr, BigInt recipientPublicKey)
        channelKeyFor,
  }) {
    // Checked against the pool's own counters, not the live ones. Allocating
    // an index moves the live counter past it, so a batch checked after it was
    // built would always look one ahead of itself.
    final baseline = _batch?.baseline ?? _state;

    final problems = <String>[];
    final expectedNotes = <NoteSequence, int>{};
    final expectedSubchannels = <BigInt, int>{};
    var expectedChannels = baseline.outgoingChannelCount;

    void checkNote({
      required BigInt recipientAddr,
      required BigInt recipientPublicKey,
      required BigInt token,
      required int index,
    }) {
      final sequence = (
        channelKey: channelKeyFor(recipientAddr, recipientPublicKey),
        token: token,
      );
      final expected =
          expectedNotes[sequence] ?? (baseline.noteCounts[sequence] ?? 0);
      if (index != expected) {
        problems.add(
          'A note for token ${_short(token)} is at index $index but the next '
          'free index is $expected',
        );
      }
      expectedNotes[sequence] = index + 1;
    }

    for (final action in actions) {
      switch (action) {
        case CreateEncNote():
          checkNote(
            recipientAddr: action.recipientAddr,
            recipientPublicKey: action.recipientPublicKey,
            token: action.token,
            index: action.index,
          );

        case CreateOpenNote():
          checkNote(
            recipientAddr: action.recipientAddr,
            recipientPublicKey: action.recipientPublicKey,
            token: action.token,
            index: action.index,
          );

        case OpenSubchannel(:final index, :final channelKey):
          final expected = expectedSubchannels[channelKey] ??
              (baseline.subchannelCounts[channelKey] ?? 0);
          if (index != expected) {
            problems.add(
              'A subchannel is at index $index but the next free index is '
              '$expected',
            );
          }
          expectedSubchannels[channelKey] = index + 1;

        case OpenChannel(:final index):
          if (index != expectedChannels) {
            problems.add(
              'A channel is at index $index but the next free index is '
              '$expectedChannels',
            );
          }
          expectedChannels = index + 1;

        default:
          break;
      }
    }

    return problems;
  }
}

String _short(BigInt value) {
  final hex = value.toRadixString(16);
  return hex.length <= 10 ? '0x$hex' : '0x${hex.substring(0, 6)}...';
}

/// Whether the slot with this id is already occupied.
///
/// Implemented by whatever can read the pool: a note is present when
/// `get_note` returns a non-zero packed value, a subchannel when its info has
/// a non-zero salt, and so on.
typedef SlotProbe = Future<bool> Function(BigInt id);

/// How many slots a sequence already holds.
///
/// Slots are dense and append-only, so the count is the first index that is
/// empty. This walks forward from zero rather than binary searching: the
/// sequences a wallet cares about are short, a linear walk is obviously
/// correct, and a binary search over a predicate that is only monotonic
/// because of an invariant elsewhere is a subtle thing to get wrong for the
/// sake of a few calls.
///
/// [limit] bounds the walk so a probe that answers "occupied" forever cannot
/// hang the wallet.
Future<int> countOccupiedSlots({
  required SlotProbe exists,
  required BigInt Function(int index) idFor,
  int limit = 512,
}) async {
  for (var index = 0; index < limit; index++) {
    if (!await exists(idFor(index))) return index;
  }
  throw ProtocolException(
    'Found $limit occupied slots in a row without reaching the end. Either '
    'the sequence is longer than this wallet supports or the probe is wrong.',
  );
}
