/// The wallet's live state: what is on chain, and how fresh that answer is.
///
/// Kept deliberately small and dependency-free. A wallet's state is a handful
/// of values and one refresh, and reaching for a state management framework
/// for that adds a layer to debug without removing one.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chain/amount.dart';
import '../chain/chain_client.dart';
import '../chain/network.dart';
import '../chain/token.dart';
import 'wallet.dart';

class WalletController extends ChangeNotifier {
  WalletController({required this.keys, required this.client});

  /// Builds a controller from a seed phrase, on the network this build points
  /// at. The account class hash comes from the network, since an address is
  /// derived from it and a hash undeclared on that chain yields an address the
  /// user can be paid at and can never spend from.
  factory WalletController.forMnemonic(
    String mnemonic, {
    TipNetwork? network,
  }) {
    final target = network ?? TipNetwork.current;
    return WalletController(
      keys: WalletFactory(accountClassHash: target.accountClassHash)
          .deriveFrom(mnemonic),
      client: ChainClient(network: target),
    );
  }

  final WalletKeys keys;
  final ChainClient client;

  TipNetwork get network => client.network;

  BalanceSnapshot? _balances;
  BalanceSnapshot? get balances => _balances;

  /// Whether the account contract exists on chain.
  ///
  /// False is the normal state for a brand new wallet. The address is real and
  /// can be paid into; it just cannot send until the first deployment.
  bool _isDeployed = false;
  bool get isDeployed => _isDeployed;

  bool _isRefreshing = false;
  bool get isRefreshing => _isRefreshing;

  /// Set when the whole refresh failed, as opposed to one token failing.
  Object? _error;
  Object? get error => _error;

  DateTime? _lastUpdated;
  DateTime? get lastUpdated => _lastUpdated;

  /// True until the first answer arrives, so the UI can tell "loading" apart
  /// from "loaded, and the balance really is zero".
  bool get hasLoaded => _lastUpdated != null;

  Timer? _timer;

  TokenAmount balanceOf(TipToken token) =>
      _balances?.of(token) ?? TokenAmount.zero(token);

  TokenAmount get feeBalance => balanceOf(network.feeToken);

  /// Tokens worth listing: everything with a balance, plus the fee token,
  /// which stays visible at zero because its absence is why sending fails.
  List<TokenAmount> get visibleBalances {
    final all = _balances?.amounts ?? [
      for (final token in network.tokens) TokenAmount.zero(token),
    ];
    final shown = all
        .where((a) => !a.isZero || a.token == network.feeToken)
        .toList();
    shown.sort((a, b) {
      if (a.token == network.feeToken) return -1;
      if (b.token == network.feeToken) return 1;
      return b.raw.compareTo(a.raw);
    });
    return shown;
  }

  Future<void> refresh() async {
    if (_isRefreshing) return;
    _isRefreshing = true;
    _error = null;
    notifyListeners();

    try {
      final results = await Future.wait([
        client.balances(keys.accountAddress),
        client.isDeployed(keys.accountAddress),
      ]);
      _balances = results[0] as BalanceSnapshot;
      _isDeployed = results[1] as bool;
      _lastUpdated = DateTime.now();
    } catch (error) {
      _error = error;
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Refreshes now, then on a timer.
  ///
  /// Thirty seconds is well under a Starknet block, so a balance is never more
  /// than one block stale on a screen the user is looking at, without hammering
  /// a public endpoint that is rate limited.
  void startPolling({Duration every = const Duration(seconds: 30)}) {
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
