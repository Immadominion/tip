/// The parts of the chain layer that can be checked without a node.
///
/// The rest is checked against live chains by `tool/check_account.dart`, since
/// a mock that returns what I expect only proves I am consistent with myself.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/chain/token.dart';

void main() {
  group('uint256FromFelts', () {
    test('reads the low limb', () {
      expect(
        uint256FromFelts([Felt.fromInt(1500), Felt.zero], 'TEST'),
        equals(BigInt.from(1500)),
      );
    });

    test('reads the high limb, which a low-limb-only reader would drop', () {
      // 2^128 exactly: low is zero, and a client that ignores the high limb
      // reports a balance of nothing.
      expect(
        uint256FromFelts([Felt.zero, Felt.fromInt(1)], 'TEST'),
        equals(BigInt.two.pow(128)),
      );
    });

    test('combines both limbs', () {
      expect(
        uint256FromFelts([Felt.fromInt(7), Felt.fromInt(3)], 'TEST'),
        equals(BigInt.from(3) * BigInt.two.pow(128) + BigInt.from(7)),
      );
    });

    test('rejects a response that is not a u256', () {
      expect(
        () => uint256FromFelts([Felt.zero], 'TEST'),
        throwsA(isA<ChainException>()),
      );
      expect(
        () => uint256FromFelts([], 'TEST'),
        throwsA(isA<ChainException>()),
      );
    });
  });

  group('BalanceSnapshot', () {
    final strk = TipTokens.strk;
    final eth = TipTokens.eth;

    test('finds an amount by token', () {
      final snapshot = BalanceSnapshot(
        amounts: [TokenAmount.parse('1.5', strk), TokenAmount.zero(eth)],
        failures: const {},
      );
      expect(snapshot.of(strk)?.format(), equals('1.5'));
      expect(snapshot.of(eth)?.isZero, isTrue);
      expect(snapshot.isComplete, isTrue);
    });

    test('reports which tokens could not be read', () {
      final snapshot = BalanceSnapshot(
        amounts: [TokenAmount.zero(strk)],
        failures: {strk: 'node down'},
      );
      expect(snapshot.isComplete, isFalse);
      expect(snapshot.failures.keys, contains(strk));
    });
  });

  group('TransactionResult', () {
    test('only a mined outcome counts as settled', () {
      const settled = [
        TransactionOutcome.succeeded,
        TransactionOutcome.reverted,
      ];
      for (final outcome in TransactionOutcome.values) {
        expect(
          TransactionResult(outcome: outcome).isSettled,
          equals(settled.contains(outcome)),
          reason: '$outcome',
        );
      }
    });
  });

  group('network', () {
    test('each network knows its own fee token', () {
      expect(TipNetwork.mainnet.feeToken.symbol, equals('STRK'));
      expect(TipNetwork.sepolia.feeToken.symbol, equals('STRK'));
    });

    test('only mainnet is mainnet', () {
      expect(TipNetwork.mainnet.isMainnet, isTrue);
      expect(TipNetwork.sepolia.isMainnet, isFalse);
    });

    test('every network has more than one endpoint to fall back on', () {
      for (final network in [TipNetwork.mainnet, TipNetwork.sepolia]) {
        expect(network.rpcUrls.length, greaterThan(1), reason: network.label);
      }
    });

    test('looks a token up by address', () {
      expect(
        TipNetwork.mainnet.tokenAt(TipTokens.usdcMainnet.address)?.symbol,
        equals('USDC'),
      );
      expect(
        TipNetwork.sepolia.tokenAt(TipTokens.usdcMainnet.address),
        isNull,
      );
    });

    test('builds explorer links from the hex address, not the decimal one', () {
      final url = TipNetwork.sepolia.addressUrl(Felt.fromInt(255));
      expect(url, contains('0xff'));
      expect(url, isNot(contains('255')));
    });

    test('no mainnet pool address is claimed until one is verified', () {
      expect(TipNetwork.sepolia.poolAddress, isNotNull);
      expect(TipNetwork.mainnet.poolAddress, isNull);
    });
  });
}
