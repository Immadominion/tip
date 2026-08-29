/// The shielded side's state.
///
/// What matters here is the failure states. A wallet that shows a confident
/// zero when it simply could not read the pool is a wallet that will one day
/// show a confident zero when the money is gone.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:tip_privacy/tip_privacy.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;
import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/activity/activity_entry.dart';
import 'package:tip/src/activity/activity_store.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/screens/home_screen.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/wallet/wallet_controller.dart';
import 'package:tip/src/privacy/pool_config.dart';
import 'package:tip/src/privacy/pool_session.dart';
import 'package:tip/src/privacy/privacy_controller.dart';
import 'package:tip/src/wallet/wallet.dart';

final _network = TipNetwork.sepolia;

final _config = PoolConfig(
  poolAddress: BigInt.from(0x1234),
  provingUrl: Uri.parse('https://prover.test'),
  discoveryUrl: Uri.parse('https://discovery.test'),
  rpcUrl: Uri.parse('https://node.test'),
);

WalletKeys _keys() => WalletFactory(
      accountClassHash: _network.accountClassHash,
    ).deriveFrom(WalletFactory.generateMnemonic());

/// Answers the one question the controller asks before anything else.
class _StubSession extends PoolSession {
  _StubSession({required this.publicKey, this.throwOnRead = false})
      : super(
          config: _config,
          keys: _keys(),
          chainId: _network.chainId,
          feeToken: _network.feeToken.address.toBigInt(),
        );

  final BigInt publicKey;
  final bool throwOnRead;

  @override
  Future<BigInt> registeredPublicKey(BigInt address) async {
    if (throwOnRead) throw const PoolException('node down');
    return publicKey;
  }
}

PrivacyController _controller({PoolSession? session, PoolConfig? config}) =>
    PrivacyController(
      keys: _keys(),
      network: _network,
      config: config,
      session: session,
    );

class _StubChain extends ChainClient {
  _StubChain() : super(network: _network);

  @override
  Future<BalanceSnapshot> balances(Felt address) async => BalanceSnapshot(
        amounts: [TokenAmount.zero(_network.feeToken)],
        failures: const {},
      );

  @override
  Future<bool> isDeployed(Felt address) async => true;
}

class _MemoryActivity extends ActivityStore {
  @override
  Future<List<ActivityEntry>> read() async => const [];

  @override
  Future<void> write(List<ActivityEntry> next) async {}
}

/// Pumps the home screen on its private tab.
Future<WalletController> _pumpHome(
  WidgetTester tester, {
  required PrivacyController privacy,
}) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final wallet = WalletController(
    keys: _keys(),
    client: _StubChain(),
    activityStore: _MemoryActivity(),
  );
  await wallet.refresh();

  await tester.pumpWidget(
    MaterialApp(
      theme: TipTheme.light,
      home: HomeScreen(
        controller: wallet,
        onWalletErased: () {},
        privacy: privacy,
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('Private'));
  await tester.pump();
  return wallet;
}

void main() {
  group('before anything is read', () {
    test('a build with no pool reports itself unconfigured', () async {
      final controller = _controller();
      expect(controller.isConfigured, isFalse);

      await controller.refresh();
      expect(controller.state, equals(PrivacyState.unconfigured));
      controller.dispose();
    });

    test('an unconfigured refresh does not pretend to have loaded', () async {
      final controller = _controller();
      await controller.refresh();
      expect(controller.hasLoaded, isFalse);
      expect(controller.total.isZero, isTrue);
      controller.dispose();
    });
  });

  group('registration', () {
    test('a wallet with no viewing key is unregistered, not empty', () async {
      // The difference matters: one is "you have not set this up", the other
      // is "you have nothing", and they need different words on screen.
      final controller = _controller(
        session: _StubSession(publicKey: BigInt.zero),
      );
      await controller.refresh();

      expect(controller.state, equals(PrivacyState.unregistered));
      expect(controller.notes, isEmpty);
      controller.dispose();
    });

    test('an unregistered wallet has still loaded', () async {
      final controller = _controller(
        session: _StubSession(publicKey: BigInt.zero),
      );
      await controller.refresh();
      expect(controller.hasLoaded, isTrue);
      controller.dispose();
    });
  });

  group('when the pool cannot be read', () {
    test('it says unreachable rather than showing zero', () async {
      final controller = _controller(
        session: _StubSession(publicKey: BigInt.one, throwOnRead: true),
      );
      await controller.refresh();

      expect(controller.state, equals(PrivacyState.unreachable));
      expect(controller.error, isNotNull);
      controller.dispose();
    });

    test('the refreshing flag comes back down', () async {
      final controller = _controller(
        session: _StubSession(publicKey: BigInt.one, throwOnRead: true),
      );
      await controller.refresh();
      expect(controller.isRefreshing, isFalse);
      controller.dispose();
    });
  });

  group('balances', () {
    test('the fee token is listed even at zero', () {
      // Its absence is why a shield or a claim would fail, so it stays visible.
      final controller = _controller();
      expect(
        controller.visibleBalances.map((a) => a.token.symbol),
        contains('STRK'),
      );
      controller.dispose();
    });

    test('a token with nothing in it is not listed', () {
      final controller = _controller();
      expect(
        controller.visibleBalances.map((a) => a.token.symbol),
        isNot(contains('ETH')),
      );
      controller.dispose();
    });
  });

  _heroTests();
  _transportTests();
  _boundsTests();
}

void _heroTests() {
  // The home screen's private side, exercised through the controller states
  // it renders from. Every branch says something different on purpose.
  group('what the private side shows', () {
    testWidgets('a build with no pool says so, rather than showing a zero',
        (tester) async {
      final wallet = await _pumpHome(tester, privacy: _controller());
      expect(find.textContaining('without a privacy pool'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      wallet.dispose();
    });

    testWidgets('an unregistered wallet is told it is not set up',
        (tester) async {
      final privacy = _controller(
        session: _StubSession(publicKey: BigInt.zero),
      );
      await privacy.refresh();
      final wallet = await _pumpHome(tester, privacy: privacy);

      expect(find.text('Not set up yet'), findsOneWidget);
      expect(find.textContaining('one time step'), findsOneWidget);
      wallet.dispose();
      privacy.dispose();
    });

    testWidgets('an unreadable pool says unknown, not zero', (tester) async {
      final privacy = _controller(
        session: _StubSession(publicKey: BigInt.one, throwOnRead: true),
      );
      await privacy.refresh();
      final wallet = await _pumpHome(tester, privacy: privacy);

      expect(find.text('Cannot reach the pool'), findsOneWidget);
      expect(find.textContaining('unknown rather than zero'), findsOneWidget);
      wallet.dispose();
      privacy.dispose();
    });
  });
}

void _transportTests() {
  group('the transport', () {
    test('is encrypted, not plain', () async {
      // Every live call this project made before this was plaintext, which
      // handed the viewing key to whoever terminates TLS. That is the gap
      // this closes, and it is worth a test that fails if anyone swaps it
      // back for convenience.
      final session = _StubSession(publicKey: BigInt.one);
      final transport = session.transportTo(_config.discoveryUrl);
      expect(transport, isA<OhttpTransport>());
      expect(transport, isNot(isA<PlainJsonTransport>()));
    });

    test('a build with no pinned key still gets an encrypted transport', () {
      // Unpinned OHTTP is weaker than pinned, not equivalent to plaintext: the
      // payload is still hidden from a passive observer.
      expect(_config.pinnedOhttpKey, isNull);
      expect(
        _StubSession(publicKey: BigInt.one).transportTo(_config.provingUrl),
        isA<OhttpTransport>(),
      );
    });

    test('the pinned key survives into the config', () {
      final pinned = PoolConfig(
        poolAddress: BigInt.one,
        provingUrl: Uri.parse('https://p.test'),
        discoveryUrl: Uri.parse('https://d.test'),
        rpcUrl: Uri.parse('https://r.test'),
        pinnedOhttpKey: Uint8List.fromList([1, 2, 3]),
      );
      expect(pinned.pinnedOhttpKey, equals([1, 2, 3]));
    });
  });
}

void _boundsTests() {
  group('submission ceilings', () {
    // Measured from three real Sepolia submissions: l1_gas 0, l2_gas between
    // 80 and 86 million, l1_data_gas under 1,500, actual fee about 2.8 STRK.
    final l2Used = BigInt.from(86000000);
    final dataUsed = BigInt.from(1500);

    tp.ResourceBounds bounds() => const tp.ResourceBounds(
          l1Gas: tp.ResourceBound(maxAmount: '0x2710', maxPricePerUnit: '0x1'),
          l1DataGas:
              tp.ResourceBound(maxAmount: '0x4e20', maxPricePerUnit: '0x1'),
          l2Gas:
              tp.ResourceBound(maxAmount: '0xbebc200', maxPricePerUnit: '0x1'),
        );

    BigInt amount(tp.ResourceBound b) =>
        BigInt.parse(b.maxAmount.replaceFirst('0x', ''), radix: 16);

    test('cover what real submissions actually used', () {
      expect(amount(bounds().l2Gas), greaterThan(l2Used));
      expect(amount(bounds().l1DataGas), greaterThan(dataUsed));
    });

    test('do not cover it so generously that nobody can pay the ceiling', () {
      // The bug this exists for. Validation requires the account to hold the
      // whole ceiling, not the fee it will pay, so an over-generous bound
      // makes the transaction unsubmittable. The first version asked for 78
      // STRK and was refused by an account holding 77.
      expect(
        amount(bounds().l2Gas),
        lessThan(l2Used * BigInt.from(4)),
        reason: 'more than about four times measured usage is waste that the '
            'account still has to hold',
      );
    });

    test('the ceiling is the sum of each resource at its bound', () {
      final session = _StubSession(publicKey: BigInt.one);
      // Prices of one, so the total is just the amounts.
      expect(
        session.maxFeeFor(bounds()),
        equals(
          amount(bounds().l1Gas) +
              amount(bounds().l1DataGas) +
              amount(bounds().l2Gas),
        ),
      );
    });
  });
}
