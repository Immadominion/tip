/// Every screen at once, for looking at.
///
/// A separate entrypoint, never reached from `main.dart`, so there is no debug
/// route inside the shipped app. Run it on an iPad simulator, where several
/// phone-sized frames fit side by side, and the whole interface can be
/// reviewed in one screenshot:
///
///   flutter run -t lib/gallery.dart -d IPAD_SIMULATOR_ID
///
/// Each frame is a real screen with a real controller, so a layout that
/// overflows here overflows on a phone.
library;

import 'package:flutter/material.dart';
import 'package:starknet/starknet.dart';

import 'src/activity/activity_entry.dart';
import 'src/activity/activity_store.dart';
import 'src/chain/amount.dart';
import 'src/chain/chain_client.dart';
import 'src/chain/network.dart';
import 'src/screens/claim_screen.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/lock_screen.dart';
import 'src/screens/onboarding_screen.dart';
import 'src/screens/receive_screen.dart';
import 'src/screens/send_screen.dart';
import 'src/screens/settings_screen.dart';
import 'src/screens/tip_screen.dart';
import 'src/security/app_lock.dart';
import 'src/theme/palette.dart';
import 'src/theme/theme.dart';
import 'src/wallet/wallet.dart';
import 'src/wallet/wallet_controller.dart';

final _network = TipNetwork.sepolia;

/// Fixed so the gallery looks the same every time it is opened.
const _phrase =
    'legal winner thank year wave sausage worth useful legal winner thank '
    'year wave sausage worth useful legal will';

class _GalleryChain extends ChainClient {
  _GalleryChain() : super(network: _network);

  @override
  Future<BalanceSnapshot> balances(Felt address) async => BalanceSnapshot(
        amounts: [
          TokenAmount.parse('1284.5', _network.tokens[0]),
          TokenAmount.parse('0.42', _network.tokens[1]),
        ],
        failures: const {},
      );

  @override
  Future<bool> isDeployed(Felt address) async => true;
}

/// Answers without touching a platform channel, so the toggle renders.
class _GalleryLock extends AppLock {
  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> isEnabled() async => true;

  @override
  Future<bool> authenticate({String reason = ''}) async => true;
}

class _GalleryActivity extends ActivityStore {
  @override
  Future<List<ActivityEntry>> read() async => [
        ActivityEntry(
          txHash: '0x1',
          kind: ActivityKind.claim,
          submittedAt: DateTime.now().subtract(const Duration(minutes: 8)),
          status: ActivityStatus.succeeded,
          tokenSymbol: 'STRK',
          tokenDecimals: 18,
          rawAmount: '2500000000000000000',
        ),
        ActivityEntry(
          txHash: '0x2',
          kind: ActivityKind.tip,
          submittedAt: DateTime.now().subtract(const Duration(hours: 3)),
          status: ActivityStatus.succeeded,
          tokenSymbol: 'STRK',
          tokenDecimals: 18,
          rawAmount: '700000000000000000',
          counterparty: '0xabc',
        ),
        ActivityEntry(
          txHash: '0x3',
          kind: ActivityKind.send,
          submittedAt: DateTime.now().subtract(const Duration(days: 2)),
          status: ActivityStatus.reverted,
          tokenSymbol: 'STRK',
          tokenDecimals: 18,
          rawAmount: '12000000000000000000',
          counterparty:
              '0x30a7cef4289ca32268279642bfb19fcf924a8b34a919210f79920b366e1d0cc',
        ),
      ];

  @override
  Future<void> write(List<ActivityEntry> next) async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final wallet = WalletController(
    keys: WalletFactory(accountClassHash: _network.accountClassHash)
        .deriveFrom(_phrase),
    client: _GalleryChain(),
    activityStore: _GalleryActivity(),
  );
  await wallet.refresh();

  runApp(_Gallery(wallet: wallet));
}

class _Gallery extends StatelessWidget {
  const _Gallery({required this.wallet});

  final WalletController wallet;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: TipTheme.light,
      home: ColoredBox(
        color: const Color(0xFFDCD8EA),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Wrap(
            spacing: 20,
            runSpacing: 20,
            children: [
              _Frame(
                label: 'Onboarding',
                child: OnboardingScreen(onReady: (_) async {}),
              ),
              _Frame(
                label: 'Home',
                child: HomeScreen(controller: wallet, onWalletErased: () {}),
              ),
              _Frame(label: 'Send', child: SendScreen(wallet: wallet)),
              _Frame(
                label: 'Receive',
                child: ReceiveScreen(
                  address: wallet.keys.accountAddress.toHexString(),
                  networkLabel: _network.label,
                ),
              ),
              _Frame(label: 'Tip', child: TipScreen(wallet: wallet)),
              _Frame(label: 'Claim', child: ClaimScreen(wallet: wallet)),
              _Frame(
                label: 'Settings',
                child: SettingsScreen(
                  wallet: wallet,
                  onErased: () {},
                  lock: _GalleryLock(),
                ),
              ),
              _Frame(
                label: 'Lock',
                child: LockScreen(lock: _GalleryLock(), onUnlocked: () {}),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One phone-sized window onto a screen.
class _Frame extends StatelessWidget {
  const _Frame({required this.label, required this.child});

  final String label;
  final Widget child;

  /// A real phone's logical size, shrunk to fit several side by side. The
  /// screen still lays out at 390x844, so anything that overflows on a phone
  /// overflows here; only the pixels are smaller.
  static const size = Size(390, 844);
  static const scale = 0.52;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 4),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: TipPalette.inkMuted,
            ),
          ),
        ),
        SizedBox(
          width: size.width * scale,
          height: size.height * scale,
          child: FittedBox(
            fit: BoxFit.contain,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: SizedBox.fromSize(
                size: size,
                child: MediaQuery(
                  data: MediaQueryData(size: size, devicePixelRatio: 3),
                  child: Navigator(
                    onGenerateRoute: (_) =>
                        MaterialPageRoute<void>(builder: (_) => child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
