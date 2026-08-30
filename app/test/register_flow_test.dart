/// The way into the shielded side.
///
/// This is the wiring test the project did not have. `PrivateOperations.register`
/// existed and worked — it had put a viewing key on Sepolia — but nothing in
/// `app/lib` ever called it, and the home screen rendered the unregistered
/// state as a `const` explanation with no button. A freshly installed wallet
/// could read about the private balance and never reach it, and every test
/// passed the whole time because no test ever asked whether a button was there.
///
/// So these assert reachability, not appearance: from the private tab of a
/// wallet the pool does not know, can a person get to the screen that fixes it.
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
import 'package:tip/src/screens/home_screen.dart';
import 'package:tip/src/screens/register_screen.dart';
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

/// A pool that has never heard of this wallet. Zero is what the pool returns
/// for an address with no viewing key, and it is what puts the controller into
/// `unregistered`.
class _UnregisteredSession extends PoolSession {
  _UnregisteredSession()
      : super(
          config: _config,
          keys: _keys(),
          chainId: _network.chainId,
          feeToken: _network.feeToken.address.toBigInt(),
        );

  @override
  Future<BigInt> registeredPublicKey(BigInt address) async => BigInt.zero;

  @override
  Future<bool> proverReachable() async => true;
}

Future<(WalletController, PrivacyController)> _pumpHome(
  WidgetTester tester,
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
    session: _UnregisteredSession(),
  );
  await privacy.refresh();

  await tester.pumpWidget(
    MaterialApp(
      theme: TipTheme.light,
      home: HomeScreen(
        controller: wallet,
        privacy: privacy,
        onWalletErased: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (wallet, privacy);
}

void main() {
  testWidgets('an unregistered wallet reads as unregistered', (tester) async {
    final (w, p) = await _pumpHome(tester);
    expect(p.state, PrivacyState.unregistered);
    w.dispose();
    p.dispose();
  });

  testWidgets('the private tab offers a way in, not just an explanation',
      (tester) async {
    final (w, p) = await _pumpHome(tester);

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();

    expect(find.text('Not set up yet'), findsOneWidget);
    // The regression: this used to be the end of the road.
    expect(find.widgetWithText(FilledButton, 'Set up private balance'),
        findsOneWidget);

    w.dispose();
    p.dispose();
  });

  testWidgets('the button actually opens the register screen', (tester) async {
    final (w, p) = await _pumpHome(tester);

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Set up private balance'));
    await tester.pumpAndSettle();

    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Set up'), findsOneWidget);

    w.dispose();
    p.dispose();
  });

  testWidgets('the register screen says the key is write-once before the button',
      (tester) async {
    // `SetViewingKey` cannot be replaced, so a wallet that registers the wrong
    // key is stuck with it. That has to be said in front of the action, not in
    // the result screen afterwards.
    final (w, p) = await _pumpHome(tester);

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Set up private balance'));
    await tester.pumpAndSettle();

    expect(find.textContaining('will not replace it'), findsOneWidget);
    expect(find.textContaining('recovery phrase'), findsWidgets);

    w.dispose();
    p.dispose();
  });

  testWidgets('it says who can actually read the shielded balance',
      (tester) async {
    final (w, p) = await _pumpHome(tester);

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Set up private balance'));
    await tester.pumpAndSettle();

    // The screen used to say "The key stays on this phone", which is false:
    // the discovery service receives the viewing key and decrypts with it. A
    // privacy product may not overstate its own privacy.
    expect(find.text('Who can see your private balance'), findsOneWidget);
    expect(find.textContaining('receives your viewing key'), findsOneWidget);

    w.dispose();
    p.dispose();
  });
}
