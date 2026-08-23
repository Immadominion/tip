/// The wallet's live state: what is on chain, and how fresh that answer is.
///
/// Kept deliberately small and dependency-free. A wallet's state is a handful
/// of values and one refresh, and reaching for a state management framework
/// for that adds a layer to debug without removing one.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:starknet/starknet.dart';

import '../activity/activity_entry.dart';
import '../activity/activity_store.dart';
import '../chain/amount.dart';
import '../chain/chain_client.dart';
import '../chain/network.dart';
import '../chain/token.dart';
import 'wallet.dart';
import 'wallet_store.dart';

class WalletController extends ChangeNotifier {
  WalletController({
    required this.keys,
    required this.client,
    ActivityStore? activityStore,
    WalletStore? walletStore,
  })  : _activityStore = activityStore ?? ActivityStore(),
        _walletStore = walletStore ?? WalletStore();

  /// Builds a controller from a seed phrase, on the network this build points
  /// at. The account class hash comes from the network, since an address is
  /// derived from it and a hash undeclared on that chain yields an address the
  /// user can be paid at and can never spend from.
  factory WalletController.forMnemonic(
    String mnemonic, {
    TipNetwork? network,
    ActivityStore? activityStore,
    WalletStore? walletStore,
  }) {
    final target = network ?? TipNetwork.current;
    return WalletController(
      keys: WalletFactory(accountClassHash: target.accountClassHash)
          .deriveFrom(mnemonic),
      client: ChainClient(network: target),
      activityStore: activityStore,
      walletStore: walletStore,
    );
  }

  final WalletKeys keys;
  final ChainClient client;
  final ActivityStore _activityStore;
  final WalletStore _walletStore;

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

  List<ActivityEntry> _activity = const [];

  /// Newest first.
  List<ActivityEntry> get activity => _activity;

  Timer? _timer;

  bool _activityLoaded = false;

  /// Loads the stored activity log. Safe to call more than once.
  Future<void> loadActivity() async {
    try {
      _activity = await _activityStore.read();
      _activityLoaded = true;
      notifyListeners();
    } catch (_) {
      // A history that will not load is an inconvenience, not a reason to
      // stop the wallet from opening.
    }
  }

  /// Adds an entry and saves it.
  Future<void> record(ActivityEntry entry) async {
    _activity = [entry, ..._activity.where((e) => e.txHash != entry.txHash)];
    notifyListeners();
    await _save();
  }

  /// Re-checks anything still in flight and updates it.
  ///
  /// Runs as part of a refresh, so an entry that settled while the app was
  /// closed stops saying "pending" as soon as the wallet is opened again.
  Future<void> refreshPendingActivity() async {
    final pending = _activity.where((e) => e.isPending).toList();
    if (pending.isEmpty) return;

    var changed = false;
    for (final entry in pending) {
      try {
        final result = await client.transactionResult(
          Felt.fromHexString(entry.txHash),
        );
        final status = switch (result.outcome) {
          TransactionOutcome.succeeded => ActivityStatus.succeeded,
          TransactionOutcome.reverted => ActivityStatus.reverted,
          TransactionOutcome.pending => ActivityStatus.pending,
          TransactionOutcome.unknown => ActivityStatus.unknown,
        };
        if (status == entry.status) continue;

        _activity = [
          for (final e in _activity)
            if (e.txHash == entry.txHash)
              e.copyWith(status: status, failureReason: result.failureReason)
            else
              e,
        ];
        changed = true;
      } catch (_) {
        // Leave it pending. A node that cannot answer is not a verdict.
      }
    }

    if (changed) {
      notifyListeners();
      await _save();
    }
  }

  /// Removes the wallet from this device.
  ///
  /// The seed goes last. If clearing the activity log fails, the wallet is
  /// still openable and the user can try again; if the seed went first and the
  /// log then failed, they would be left with a history they cannot open and
  /// no way to remove it.
  Future<void> erase() async {
    await _activityStore.clear();
    await _walletStore.deleteSeedPhrase();
    _activity = const [];
    _balances = null;
    _lastUpdated = null;
    stopPolling();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await _activityStore.write(_activity);
    } catch (_) {
      // The entry is still in memory and on chain. Failing to cache it is not
      // worth interrupting a send that already succeeded.
    }
  }

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
      // Load before re-checking, or the first refresh looks at an empty list
      // and everything stored stays "pending" until the one after it.
      if (!_activityLoaded) await loadActivity();
      await refreshPendingActivity();
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
