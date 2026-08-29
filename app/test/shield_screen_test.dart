/// The shield screen.
///
/// Two things it must not get wrong: refusing an amount the wallet cannot
/// cover before a proof is paid for, and never letting anyone believe the
/// deposit itself is private.
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
import 'package:tip/src/screens/shield_screen.dart';
import 'package:tip/src/screens/widgets/operation_progress.dart';
import 'package:tip/src/privacy/private_operations.dart';
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
  _StubSession({this.proverUp = true})
      : super(
          config: _config,
          keys: _keys(),
          chainId: _network.chainId,
          feeToken: _network.feeToken.address.toBigInt(),
        );

  /// Answers for the prover without a network call. The widget tests are
  /// about the screens, and a stub that quietly tried to reach a real prover
  /// would make them depend on whether one was up.
  final bool proverUp;

  @override
  Future<BigInt> registeredPublicKey(BigInt address) async => BigInt.one;

  @override
  Future<bool> proverReachable() async => proverUp;
}

Future<(WalletController, PrivacyController)> _pump(
  WidgetTester tester, {
  bool proverUp = true,
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

  final privacy = PrivacyController(
    keys: wallet.keys,
    network: _network,
    session: _StubSession(proverUp: proverUp),
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: TipTheme.light,
      home: ShieldScreen(wallet: wallet, privacy: privacy),
    ),
  );
  await tester.pump();
  return (wallet, privacy);
}

Finder get _button => find.widgetWithText(FilledButton, 'Shield');

void main() {
  testWidgets('it says the deposit itself is public, before anything is typed',
      (tester) async {
    // Shielding hides what happens after the deposit, not the deposit. A user
    // who believes otherwise is making a decision on a false premise.
    final (wallet, privacy) = await _pump(tester);
    expect(find.text('The deposit itself is public'), findsOneWidget);
    wallet.dispose();
    privacy.dispose();
  });

  testWidgets('the button is dead until there is an amount', (tester) async {
    final (wallet, privacy) = await _pump(tester);
    expect(tester.widget<FilledButton>(_button).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '1');
    await tester.pump();
    expect(tester.widget<FilledButton>(_button).onPressed, isNotNull);

    wallet.dispose();
    privacy.dispose();
  });

  testWidgets('more than the public balance is refused, with the balance',
      (tester) async {
    final (wallet, privacy) = await _pump(tester);

    await tester.enterText(find.byType(TextField), '9');
    await tester.pump();

    expect(find.textContaining('You have 5 STRK'), findsOneWidget);
    expect(tester.widget<FilledButton>(_button).onPressed, isNull);

    wallet.dispose();
    privacy.dispose();
  });

  testWidgets('zero is refused', (tester) async {
    final (wallet, privacy) = await _pump(tester);
    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();
    expect(find.text('Enter an amount above zero'), findsOneWidget);
    wallet.dispose();
    privacy.dispose();
  });

  testWidgets('it warns that this takes about a minute', (tester) async {
    final (wallet, privacy) = await _pump(tester);
    expect(find.textContaining('about a minute'), findsOneWidget);
    wallet.dispose();
    privacy.dispose();
  });

  group('when the prover is not answering', () {
    testWidgets('it says so before a minute is spent finding out',
        (tester) async {
      final (wallet, privacy) = await _pump(tester, proverUp: false);
      await tester.pump();

      expect(
        find.text('The proving service is not answering'),
        findsOneWidget,
      );
      wallet.dispose();
      privacy.dispose();
    });

    testWidgets('it warns without taking the decision away', (tester) async {
      // A health check is evidence, not authority. Refusing to let somebody
      // move their own money on the strength of one failed request is a worse
      // failure than letting them try.
      final (wallet, privacy) = await _pump(tester, proverUp: false);
      await tester.enterText(find.byType(TextField), '1');
      await tester.pump();

      expect(tester.widget<FilledButton>(_button).onPressed, isNotNull);
      wallet.dispose();
      privacy.dispose();
    });

    testWidgets('a healthy prover is not mentioned at all', (tester) async {
      final (wallet, privacy) = await _pump(tester);
      await tester.pump();

      expect(find.textContaining('proving service is not'), findsNothing);
      wallet.dispose();
      privacy.dispose();
    });
  });

  group('the progress view', () {
    testWidgets('names the step rather than spinning silently', (tester) async {
      // Fifty seconds of unexplained spinner is a transaction people force
      // quit halfway through.
      for (final stage in OperationStage.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: TipTheme.light,
            home: Scaffold(body: OperationProgress(stage: stage)),
          ),
        );
        await tester.pump();
        expect(
          find.byType(CircularProgressIndicator),
          findsOneWidget,
          reason: stage.name,
        );
      }
    });

    testWidgets('says the slow part is the proof', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TipTheme.light,
          home: const Scaffold(
            body: OperationProgress(stage: OperationStage.proving),
          ),
        ),
      );
      expect(find.text('Proving'), findsOneWidget);
      expect(find.textContaining('a phone cannot do it'), findsOneWidget);
    });

    testWidgets('once sent, it says closing will not undo it', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TipTheme.light,
          home: const Scaffold(
            body: OperationProgress(
              stage: OperationStage.waiting,
              hash: '0xabc',
            ),
          ),
        ),
      );
      expect(find.textContaining('will not undo it'), findsOneWidget);
    });
  });
}
