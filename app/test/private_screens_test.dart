/// The private send and unshield screens.
///
/// Both make a claim about what is visible on chain, and the claims are
/// opposite. Getting either backwards would mislead someone about the only
/// thing this product is for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/activity/activity_entry.dart';
import 'package:tip/src/activity/activity_store.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/privacy/pool_config.dart';
import 'package:tip/src/privacy/pool_session.dart';
import 'package:tip/src/privacy/privacy_controller.dart';
import 'package:tip/src/screens/private_send_screen.dart';
import 'package:tip/src/screens/unshield_screen.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip/src/wallet/wallet_controller.dart';

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

class _StubChain extends ChainClient {
  _StubChain() : super(network: _network);

  @override
  Future<BalanceSnapshot> balances(Felt address) async => BalanceSnapshot(
        amounts: [TokenAmount.parse('5', _network.feeToken)],
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

class _StubSession extends PoolSession {
  _StubSession()
      : super(
          config: _config,
          keys: _keys(),
          chainId: _network.chainId,
          feeToken: _network.feeToken.address.toBigInt(),
        );

  /// Answers for the prover without a network call. The widget tests are
  /// about the screens, and a stub that quietly tried to reach a real prover
  /// would make them depend on whether one was up.
  bool proverUp = true;

  @override
  Future<BigInt> registeredPublicKey(BigInt address) async => BigInt.one;

  @override
  Future<bool> proverReachable() async => proverUp;
}

Future<(WalletController, PrivacyController)> _pump(
  WidgetTester tester,
  Widget Function(WalletController, PrivacyController) build,
) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final wallet = WalletController(
    keys: _keys(),
    client: _StubChain(),
    activityStore: _MemoryActivity(),
  );
  await wallet.refresh();

  final privacy = PrivacyController(
    keys: wallet.keys,
    network: _network,
    session: _StubSession(),
  );

  await tester.pumpWidget(
    MaterialApp(theme: TipTheme.light, home: build(wallet, privacy)),
  );
  await tester.pump();
  return (wallet, privacy);
}

void main() {
  group('private send', () {
    Future<(WalletController, PrivacyController)> pump(WidgetTester t) => _pump(
          t,
          (w, p) => PrivateSendScreen(wallet: w, privacy: p),
        );

    testWidgets('claims nothing appears on chain', (tester) async {
      final (w, p) = await pump(tester);
      expect(find.text('Nothing about this appears on chain'), findsOneWidget);
      expect(find.textContaining('Not the amount, not you, not them'),
          findsOneWidget);
      w.dispose();
      p.dispose();
    });

    testWidgets('says the recipient has to be set up too', (tester) async {
      // A note is encrypted to their viewing key. Without one there is nobody
      // to encrypt it to, and that is not obvious from the outside.
      final (w, p) = await pump(tester);
      expect(find.textContaining('has to have set up private transfers'),
          findsOneWidget);
      w.dispose();
      p.dispose();
    });

    testWidgets('refuses more than is shielded, naming the balance',
        (tester) async {
      final (w, p) = await pump(tester);
      await tester.enterText(find.byType(TextField).first, '0x1234abcd');
      await tester.enterText(find.byType(TextField).last, '1');
      await tester.pump();

      expect(find.textContaining('You have 0 STRK shielded'), findsOneWidget);
      w.dispose();
      p.dispose();
    });

    testWidgets('an Ethereum address is still refused by name', (tester) async {
      final (w, p) = await pump(tester);
      await tester.enterText(
        find.byType(TextField).first,
        '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045',
      );
      await tester.pump();
      expect(find.textContaining('Ethereum'), findsOneWidget);
      w.dispose();
      p.dispose();
    });
  });

  group('unshield', () {
    Future<(WalletController, PrivacyController)> pump(WidgetTester t) => _pump(
          t,
          (w, p) => UnshieldScreen(wallet: w, privacy: p),
        );

    testWidgets('says the withdrawal is public, which is the opposite claim',
        (tester) async {
      final (w, p) = await pump(tester);
      expect(find.text('The withdrawal is public'), findsOneWidget);
      w.dispose();
      p.dispose();
    });

    testWidgets('defaults to this wallet and says so', (tester) async {
      final (w, p) = await pump(tester);
      expect(find.textContaining('comes back to this wallet'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      w.dispose();
      p.dispose();
    });

    testWidgets('the warning changes when sending elsewhere', (tester) async {
      // To yourself the link is unavoidable; elsewhere it is the whole point.
      final (w, p) = await pump(tester);
      expect(find.textContaining('paying this wallet'), findsOneWidget);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();

      expect(find.textContaining('not obviously yours'), findsOneWidget);
      w.dispose();
      p.dispose();
    });

    testWidgets('sending elsewhere needs an address before it will go',
        (tester) async {
      final (w, p) = await pump(tester);
      await tester.enterText(find.byType(TextField).first, '0.5');
      await tester.pump();

      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Unshield'),
            )
            .onPressed,
        isNull,
      );
      w.dispose();
      p.dispose();
    });
  });
}
