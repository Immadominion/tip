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

      _byToken.clear();
      _notes = [
        for (final note in incoming.notes)
          tp.SpendableNote(
            channelKey: channel.key,
            token: note.token,
            index: note.index,
            amount: note.amount,
          ),
      ];
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
