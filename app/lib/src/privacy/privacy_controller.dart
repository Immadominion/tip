/// The wallet's shielded state.
///
/// Mirrors `WalletController` for the private side: what is in the pool, how
/// fresh that answer is, and whether the pool is reachable at all. Kept
/// separate because the two halves fail independently. The public balance
/// comes from any Starknet node; the shielded one needs a pool, a discovery
/// service and a registered viewing key, and any of those can be missing while
/// the wallet still works.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

import '../chain/amount.dart';
import '../chain/network.dart';
import '../chain/token.dart';
import '../wallet/wallet.dart';
import 'pool_config.dart';
import 'pool_session.dart';

/// Why the shielded side is not showing a balance.
enum PrivacyState {
  /// This build was given no pool to talk to.
  unconfigured,

  /// Configured, but this wallet has never registered a viewing key.
  unregistered,

  /// Registered, and the balance below is real.
  ready,

  /// Configured and registered, but the last read failed.
  unreachable,
}

class PrivacyController extends ChangeNotifier {
  PrivacyController({
    required this.keys,
    required this.network,
    PoolConfig? config,
    PoolSession? session,
  })  : config = config ?? PoolConfig.fromEnvironment(),
        _injectedSession = session;

  final WalletKeys keys;
  final TipNetwork network;
  final PoolConfig? config;
  final PoolSession? _injectedSession;

  PoolSession? _session;

  /// The session, or null when there is nothing configured to talk to.
  PoolSession? get session {
    if (_injectedSession != null) return _injectedSession;
    final settings = config;
    if (settings == null) return null;
    return _session ??= PoolSession(
      config: settings,
      keys: keys,
      chainId: network.chainId,
      feeToken: network.feeToken.address.toBigInt(),
    );
  }

  bool get isConfigured => session != null;

  PrivacyState _state = PrivacyState.unconfigured;
  PrivacyState get state => _state;

  bool _isRefreshing = false;
  bool get isRefreshing => _isRefreshing;

  Object? _error;
  Object? get error => _error;

  DateTime? _lastUpdated;
  DateTime? get lastUpdated => _lastUpdated;
  bool get hasLoaded => _lastUpdated != null;

  List<tp.SpendableNote> _notes = const [];

  /// Notes this wallet can spend, newest read first.
  List<tp.SpendableNote> get notes => _notes;

  final Map<BigInt, BigInt> _byToken = {};

  Timer? _timer;

  /// The shielded balance of [token].
  TokenAmount shieldedBalance(TipToken token) => TokenAmount(
        _byToken[token.address.toBigInt()] ?? BigInt.zero,
        token,
      );

  /// Total shielded, in the network's fee token.
  TokenAmount get total => shieldedBalance(network.feeToken);

  /// Tokens with something in them, fee token always shown.
  List<TokenAmount> get visibleBalances {
    final shown = <TokenAmount>[];
    for (final token in network.tokens) {
      final amount = shieldedBalance(token);
      if (!amount.isZero || token == network.feeToken) shown.add(amount);
    }
    return shown;
  }

  /// Reads the pool.
  ///
  /// The note list comes from the discovery service, which already leaves out
  /// notes whose nullifier has been published. That is good enough to show a
  /// balance; spending re-checks each note against the chain, because whether
  /// a note is spendable is a fact about the chain rather than about what a
  /// service chose to send.
  /// Notes the service sent that we could not key to a channel, and so cannot
  /// spend. Normally zero. A non-zero count means either a channel we have not
  /// discovered yet or a note that is not ours, and either way it is honest to
  /// leave it out of the balance rather than show money that cannot move.
  int _unspendableNotes = 0;
  int get unspendableNotes => _unspendableNotes;

  Future<void> refresh() async {
    final pool = session;
    if (pool == null) {
      _state = PrivacyState.unconfigured;
      notifyListeners();
      return;
    }
    if (_isRefreshing) return;

    _isRefreshing = true;
    _error = null;
    notifyListeners();

    try {
      final self = keys.accountAddress.toBigInt();
      final publicKey = await pool.registeredPublicKey(self);

      if (publicKey == BigInt.zero) {
        _state = PrivacyState.unregistered;
        _notes = const [];
        _byToken.clear();
        _lastUpdated = DateTime.now();
        return;
      }

      final channel = pool.channelTo(
        recipient: self,
        recipientPublicKey: publicKey,
        token: network.feeToken.address.toBigInt(),
      );

      // Encrypted, because the request carries the viewing key. A plain
      // transport hands it to whoever terminates TLS, which for a hosted
      // service is not necessarily the service.
      final client = tp.DiscoveryClient(
        transport: pool.transportTo(pool.config.discoveryUrl),
        poolContractAddress: pool.config.poolAddress,
      );
      final incoming = await client.syncIncoming(
        address: self,
        viewingKey: keys.viewingKey,
      );
      client.close();

      final keyed = keyIncomingNotes(
        notes: incoming.notes,
        channels: incoming.channels,
        self: self,
        selfChannelKey: channel.key,
      );
      _notes = keyed.notes;
      _unspendableNotes = keyed.unspendable;

      _byToken.clear();
      for (final note in _notes) {
        _byToken[note.token] = (_byToken[note.token] ?? BigInt.zero) + note.amount;
      }

      _state = PrivacyState.ready;
      _lastUpdated = DateTime.now();
    } catch (error) {
      _error = error;
      // The notes and balances already read are deliberately left alone. A
      // shielded balance that drops to zero because a service blinked is worse
      // than a stale one shown next to a warning.
      _state = PrivacyState.unreachable;
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Refreshes now, then on a timer.
  ///
  /// Slower than the public balance. A shielded read is a full discovery sync
  /// and costs the service real work, and shielded balances change only when
  /// this wallet moves them or someone pays it.
  void startPolling({Duration every = const Duration(minutes: 2)}) {
    _timer?.cancel();
    unawaited(refresh());
    _timer = Timer.periodic(every, (_) => refresh());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}

/// The result of matching discovered notes to the channels they belong to.
class KeyedNotes {
  const KeyedNotes({required this.notes, required this.unspendable});

  /// Notes we hold the channel key for, deduplicated, ready to spend.
  final List<tp.SpendableNote> notes;

  /// How many the service sent that we could not key. Normally zero.
  final int unspendable;
}

/// Matches each discovered note to the channel key it was created under.
///
/// A note belongs to the channel its *sender* opened to us, and the channel key
/// is what `UseNote` is built against. This used to stamp every note with our
/// own self-channel key, which is only correct for notes we created ourselves
/// by shielding: a note from anybody else was counted in the balance and then
/// could not be spent, because the `UseNote` it produced named a note id that
/// does not exist on chain. The sender's key was in the response the whole
/// time, in `channels`, and was being discarded.
///
/// The sender-to-key map is not trusted, it is checked. A note id is
/// `h(NOTE_ID_TAG, channel_key, token, index, 0)`, so recomputing it with the
/// key we picked and comparing against the id the service sent proves the key
/// is the right one. A note that fails that check is not ours to spend, and
/// crediting it would put a number on the home screen that no transaction can
/// ever move.
KeyedNotes keyIncomingNotes({
  required List<tp.IncomingNote> notes,
  required List<tp.IncomingChannel> channels,
  required BigInt self,
  required BigInt selfChannelKey,
}) {
  final channelKeyBySender = <BigInt, BigInt>{
    // Seeded with our own, so shielding keeps working even if the service does
    // not echo the self-channel back to us.
    self: selfChannelKey,
    for (final c in channels) c.senderAddr: c.channelKey,
  };

  final spendable = <tp.SpendableNote>[];
  var unspendable = 0;

  // Two notes with the same (channel, token, index) are the same note. The
  // service paginates, and a page boundary that moves under a cursor can repeat
  // one; spending it twice would build a batch the pool refuses.
  final seen = <String>{};

  for (final note in notes) {
    final key = channelKeyBySender[note.senderAddr];
    if (key == null) {
      unspendable++;
      continue;
    }
    final expected = tp.computeNoteId(
      channelKey: key,
      token: note.token,
      index: note.index,
    );
    if (expected != note.noteId) {
      unspendable++;
      continue;
    }
    if (!seen.add('$key:${note.token}:${note.index}')) continue;
    spendable.add(
      tp.SpendableNote(
        channelKey: key,
        token: note.token,
        index: note.index,
        amount: note.amount,
      ),
    );
  }

  return KeyedNotes(notes: spendable, unspendable: unspendable);
}
