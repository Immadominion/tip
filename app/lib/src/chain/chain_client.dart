/// Everything the wallet asks the chain.
///
/// Two things this layer is responsible for that a thin RPC wrapper would not
/// be. It falls through to another node when one is unhealthy, because these
/// are free public endpoints and they do go down mid-session. And it separates
/// a node being broken from the chain giving a real answer: "this contract is
/// not deployed" is information, not a failure, and retrying it against three
/// more nodes only makes the user wait longer for the same answer.
library;

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';

import 'amount.dart';
import 'network.dart';
import 'signing_account.dart';
import 'token.dart';

/// A real answer from the chain that the caller has to deal with.
class ChainException implements Exception {
  const ChainException(this.message, {this.code});

  final String message;
  final JsonRpcApiErrorCode? code;

  @override
  String toString() => code == null ? message : '$message (${code!.name})';
}

/// Internal: this node could not answer, so try the next one.
class _NodeUnhealthy implements Exception {
  _NodeUnhealthy(this.detail);

  final String detail;

  @override
  String toString() => detail;
}

/// Error codes that mean the node is having a bad time rather than the chain
/// having given an answer.
///
/// `UNKNOWN` covers the -32000 that a proxy in front of a dead node returns,
/// and `METHOD_NOT_FOUND` covers a node that simply does not implement the
/// method, which some free endpoints do not.
const _unhealthyCodes = {
  JsonRpcApiErrorCode.UNKNOWN,
  JsonRpcApiErrorCode.INTERNAL_SEQUENCER,
  JsonRpcApiErrorCode.METHOD_NOT_FOUND,
  JsonRpcApiErrorCode.UNEXPECTED_ERROR,
};

Never _raise(JsonRpcApiError error) {
  if (_unhealthyCodes.contains(error.code)) {
    throw _NodeUnhealthy('${error.code.name}: ${error.message}');
  }
  throw ChainException(error.message, code: error.code);
}

/// What happened to a transaction the wallet sent.
enum TransactionOutcome {
  /// The node has not seen it. Right after submission this is normal.
  unknown,

  /// Accepted by the sequencer, not yet in a block.
  pending,

  /// In a block and it did what it was asked.
  succeeded,

  /// In a block and it reverted. The fee was still charged.
  reverted,
}

class TransactionResult {
  const TransactionResult({required this.outcome, this.failureReason});

  final TransactionOutcome outcome;
  final String? failureReason;

  bool get isSettled =>
      outcome == TransactionOutcome.succeeded ||
      outcome == TransactionOutcome.reverted;
}

class ChainClient {
  ChainClient({required this.network})
      : _providers = [
          for (final url in network.rpcUrls) JsonRpcProvider(nodeUri: url),
        ];

  final TipNetwork network;
  final List<JsonRpcProvider> _providers;

  /// How long one endpoint gets before we try the next.
  ///
  /// Generous, because a slow node is still better than no node, and short
  /// enough that trying every endpoint stays inside a person's patience rather
  /// than inside a network stack's.
  static const readTimeout = Duration(seconds: 15);

  /// The provider an [Account] signs and submits through.
  ///
  /// Only the first endpoint, deliberately. Failover is safe for reads and
  /// unsafe for writes: resubmitting a signed transaction to a second node
  /// after the first one timed out can land it twice.
  Provider get submissionProvider => _providers.first;

  /// Runs [body] against each endpoint until one answers.
  ///
  /// A [ChainException] is the chain's answer, so it stops the loop. Anything
  /// else, a socket error or an unhealthy node, moves on to the next endpoint.
  Future<R> _read<R>(Future<R> Function(JsonRpcProvider) body) async {
    Object? lastError;
    for (final provider in _providers) {
      try {
        // The timeout is what makes the failover work at all. Without it a
        // black-holed socket — the commonest mobile failure, and what a captive
        // portal or a dead endpoint actually looks like — hangs here forever
        // rather than throwing, so the loop never reaches the next endpoint and
        // the caller never returns. The SDK's own http.post has no timeout
        // either, so there is nothing underneath this to fall back on.
        return await body(provider).timeout(readTimeout);
      } on ChainException {
        rethrow;
      } catch (error) {
        lastError = error;
      }
    }
    throw ChainException('No Starknet node answered. Last error: $lastError');
  }

  /// Balance of one token, as an amount that knows its own decimals.
  Future<TokenAmount> balanceOf({
    required TipToken token,
    required Felt address,
  }) async {
    final felts = await _read((provider) async {
      final response = await provider.call(
        request: FunctionCall(
          contractAddress: token.address,
          entryPointSelector: getSelectorByName('balanceOf'),
          calldata: [address],
        ),
        blockId: BlockId.latest,
      );
      return response.when(error: _raise, result: (result) => result);
    });

    return TokenAmount(uint256FromFelts(felts, token.symbol), token);
  }

  /// Balances for every token the network lists.
  ///
  /// Concurrent, and one token failing does not hide the others: a token that
  /// cannot be read comes back as zero rather than taking the whole screen
  /// down. The caller is told which ones failed so it can say so.
  Future<BalanceSnapshot> balances(Felt address) async {
    final failures = <TipToken, Object>{};

    final amounts = <TokenAmount>[
      ...await Future.wait([
        for (final token in network.tokens)
          balanceOf(token: token, address: address).then<TokenAmount>(
            (amount) => amount,
            onError: (Object error) {
              failures[token] = error;
              return TokenAmount.zero(token);
            },
          ),
      ]),
    ];

    return BalanceSnapshot(amounts: amounts, failures: failures);
  }

  /// Whether the account contract exists on chain yet.
  ///
  /// A tip address is computable before deployment, so it can be shown and
  /// paid into immediately. It cannot send until this is true.
  Future<bool> isDeployed(Felt address) async {
    try {
      await _read((provider) async {
        final response = await provider.getClassHashAt(
          contractAddress: address,
          blockId: BlockId.latest,
        );
        return response.when(error: _raise, result: (result) => result);
      });
      return true;
    } on ChainException catch (error) {
      if (error.code == JsonRpcApiErrorCode.CONTRACT_NOT_FOUND) return false;
      rethrow;
    }
  }

  /// Next nonce for an account, or zero if it is not deployed yet.
  Future<Felt> nonceOf(Felt address) async {
    try {
      return await _read((provider) async {
        final response = await provider.getNonce(
          contractAddress: address,
          blockId: BlockId.latest,
        );
        return response.when(error: _raise, result: (result) => result);
      });
    } on ChainException catch (error) {
      if (error.code == JsonRpcApiErrorCode.CONTRACT_NOT_FOUND) {
        return Felt.zero;
      }
      rethrow;
    }
  }

  /// Guards against the wallet talking to a chain it did not mean to.
  ///
  /// Cheap to check and expensive to get wrong: a mainnet key signing against
  /// a node that quietly points at a testnet produces confusing failures, and
  /// the reverse produces real losses.
  Future<bool> chainIdMatches() async {
    final id = await _read((provider) async {
      final response = await provider.chainId();
      return response.when(error: _raise, result: (result) => result);
    });
    return Felt.fromHexString(id) == network.chainId;
  }

  /// Where a transaction has got to.
  Future<TransactionResult> transactionResult(Felt hash) async {
    try {
      final status = await _read((provider) async {
        final response = await provider.getTransactionStatus(hash);
        return response.when(error: _raise, result: (result) => result);
      });

      if (status.executionStatus == TxnExecutionStatus.REVERTED) {
        return TransactionResult(
          outcome: TransactionOutcome.reverted,
          failureReason: status.failureReason,
        );
      }

      switch (status.finalityStatus) {
        case TxnStatus.ACCEPTED_ON_L2:
        case TxnStatus.ACCEPTED_ON_L1:
          return const TransactionResult(outcome: TransactionOutcome.succeeded);
        case TxnStatus.RECEIVED:
        case TxnStatus.CANDIDATE:
        case TxnStatus.PRE_CONFIRMED:
          return const TransactionResult(outcome: TransactionOutcome.pending);
      }
    } on ChainException catch (error) {
      if (error.code == JsonRpcApiErrorCode.TXN_HASH_NOT_FOUND) {
        return const TransactionResult(outcome: TransactionOutcome.unknown);
      }
      rethrow;
    }
  }

  /// Polls until the transaction settles or [timeout] elapses.
  ///
  /// Returns the last thing it saw rather than throwing on timeout. A slow
  /// transaction is not a failed one, and a wallet that says "failed" when it
  /// means "still waiting" teaches people to distrust it.
  Future<TransactionResult> awaitTransaction(
    Felt hash, {
    Duration timeout = const Duration(minutes: 3),
    Duration pollInterval = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var last = const TransactionResult(outcome: TransactionOutcome.unknown);

    while (DateTime.now().isBefore(deadline)) {
      last = await transactionResult(hash);
      if (last.isSettled) return last;
      await Future<void>.delayed(pollInterval);
    }
    return last;
  }

  /// An account ready to sign, for [who].
  Account accountFor(SigningAccount who) => Account(
        provider: submissionProvider,
        signer: StarkAccountSigner(
          signer: StarkSigner(privateKey: who.privateKey),
        ),
        accountAddress: who.address,
        chainId: network.chainId,
      );
}

/// A read of every balance at one moment, including what could not be read.
class BalanceSnapshot {
  const BalanceSnapshot({required this.amounts, required this.failures});

  final List<TokenAmount> amounts;

  /// Tokens whose balance call failed. Their entry in [amounts] is zero, and
  /// the UI should say so rather than show a confident zero.
  final Map<TipToken, Object> failures;

  bool get isComplete => failures.isEmpty;

  TokenAmount? of(TipToken token) {
    for (final amount in amounts) {
      if (amount.token == token) return amount;
    }
    return null;
  }
}

/// Reads a Cairo `u256` return value.
///
/// A u256 crosses the felt boundary and comes back as a low and a high limb.
/// Reading only the low one works for every amount anybody tests with and
/// fails silently at 2^128, which is exactly the kind of bug that ships.
///
/// Public so the boundary can be tested without a node.
BigInt uint256FromFelts(List<Felt> felts, String context) {
  if (felts.length < 2) {
    throw ChainException(
      '$context balance came back as ${felts.length} felt(s), expected a u256',
    );
  }
  return felts[0].toBigInt() + (felts[1].toBigInt() << 128);
}
