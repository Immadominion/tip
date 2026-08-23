/// What happens before the wallet appears.
///
/// One job: decide whether there is already a wallet on this device. Getting
/// it wrong in the safe-looking direction, by treating an unreadable keystore
/// as "no wallet", would walk the user into onboarding and overwrite a seed
/// that was only temporarily unavailable. So a read that fails is an error the
/// user sees, never a fresh start.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../activity/activity_store.dart';
import '../links/incoming_links.dart';
import '../auth/auth_service.dart';
import '../security/app_lock.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet.dart';
import '../wallet/wallet_controller.dart';
import '../wallet/wallet_store.dart';
import 'claim_screen.dart';
import 'home_screen.dart';
import 'lock_screen.dart';
import 'onboarding_screen.dart';

enum _Phase { checking, onboarding, locked, ready, failed }

class BootScreen extends StatefulWidget {
  const BootScreen({
    super.key,
    this.store,
    this.activityStore,
    this.links,
    this.lock,
    this.auth,
    this.lockAfter = const Duration(seconds: 30),
  });

  /// Everything below is a seam for tests. The app passes nothing and lets
  /// each piece make its own, which keeps the wiring in one place.
  final WalletStore? store;

  final ActivityStore? activityStore;

  /// Left null by tests that do not care about deep links: subscribing to a
  /// platform channel in a widget test buys nothing.
  final IncomingLinks? links;

  final AppLock? lock;

  final AuthService? auth;

  /// How long the app can sit in the background before it locks again.
  ///
  /// Not zero. Authenticating backgrounds the app on some devices, and so does
  /// switching away for two seconds to copy an address out of a message, and
  /// re-prompting for either is the kind of friction that gets a lock turned
  /// off entirely.
  final Duration lockAfter;

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> with WidgetsBindingObserver {
  late final WalletStore _store = widget.store ?? WalletStore();
  late final AppLock _lock = widget.lock ?? AppLock();
  late final AuthService _auth = widget.auth ?? AuthService();

  _Phase _phase = _Phase.checking;
  WalletController? _controller;
  String? _error;

  /// A tip link that arrived before there was a wallet to put it in.
  ///
  /// Someone tapping a tip link may be installing the app because of that
  /// link. Dropping it while they set up a wallet, and making them find it
  /// again in their messages afterwards, is the obvious way to lose them.
  Uri? _pendingClaim;
  bool _claimScreenOpen = false;
  StreamSubscription<Uri>? _linkSubscription;

  /// When the app was last put away, for deciding whether to lock again.
  DateTime? _leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _listenForLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_linkSubscription?.cancel());
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _leftAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;

    final left = _leftAt;
    _leftAt = null;
    if (left == null || _phase != _Phase.ready) return;
    if (DateTime.now().difference(left) < widget.lockAfter) return;

    unawaited(_relock());
  }

  Future<void> _relock() async {
    if (!await _lock.isEnabled()) return;
    if (!mounted || _phase != _Phase.ready) return;
    setState(() => _phase = _Phase.locked);
  }

  void _listenForLinks() {
    final links = widget.links;
    if (links == null) return;

    unawaited(
      links.initial().then((uri) {
        if (uri != null) _receive(uri);
      }).catchError((Object _) {
        // No launch link, or the platform had nothing to say. Not an error.
      }),
    );
    _linkSubscription = links.stream.listen(_receive, onError: (Object _) {});
  }

  void _receive(Uri uri) {
    if (!IncomingLinks.isClaimLink(uri)) return;
    setState(() => _pendingClaim = uri);
    _openPendingClaim();
  }

  /// Opens the claim screen once there is a wallet to claim into.
  void _openPendingClaim() {
    final link = _pendingClaim;
    if (link == null || _phase != _Phase.ready || _claimScreenOpen) return;

    _claimScreenOpen = true;
    _pendingClaim = null;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _claimScreenOpen = false;
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ClaimScreen(
            wallet: _controller!,
            initialLink: link.toString(),
          ),
        ),
      );
      _claimScreenOpen = false;
      // A second link may have arrived while the first was on screen.
      if (mounted) _openPendingClaim();
    });
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
    });
    try {
      final stored = await _store.readSeedPhrase();
      if (!mounted) return;

      if (stored == null) {
        setState(() => _phase = _Phase.onboarding);
        return;
      }
      if (!WalletFactory.isValidMnemonic(stored)) {
        // Do not offer to clear this. A phrase that fails its checksum may
        // still be recoverable by hand, and a wallet that deletes it to get
        // back to a working state destroys the only copy.
        setState(() {
          _phase = _Phase.failed;
          _error = 'The saved recovery phrase did not pass its checksum. '
              'Nothing has been changed. Reinstalling would erase it, so '
              'please get in touch before doing that.';
        });
        return;
      }
      final controller = WalletController.forMnemonic(
        stored,
        activityStore: widget.activityStore,
        walletStore: _store,
      );
      // The lock goes in front of an existing wallet only. A wallet created or
      // restored in this session was just proven to belong to whoever is
      // holding the phone.
      final locked = await _lock.isEnabled();
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _phase = locked ? _Phase.locked : _Phase.ready;
      });
      if (!locked) _openPendingClaim();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = 'Could not read the keystore on this device. $error';
      });
    }
  }

  /// Takes ownership of a phrase the user just created or restored.
  ///
  /// Writes before showing the wallet. A wallet on screen whose seed is not
  /// yet saved is a wallet the user can fund and then lose on the next launch.
  Future<void> _adopt(String mnemonic) async {
    await _store.writeSeedPhrase(mnemonic);
    if (!mounted) return;
    setState(() {
      _controller = WalletController.forMnemonic(
        mnemonic,
        activityStore: widget.activityStore,
        walletStore: _store,
      );
      _phase = _Phase.ready;
    });
    _openPendingClaim();
  }

  /// Returns to onboarding after the wallet has been removed.
  ///
  /// The controller is dropped rather than reused: it still holds the keys of
  /// a wallet that no longer exists on this device.
  void _forget() {
    final gone = _controller;
    setState(() {
      _controller = null;
      _phase = _Phase.onboarding;
    });
    gone?.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (_phase) {
        _Phase.checking => const _Splash(),
        _Phase.onboarding => OnboardingScreen(onReady: _adopt),
        _Phase.locked => LockScreen(
            lock: _lock,
            onUnlocked: () {
              setState(() => _phase = _Phase.ready);
              _openPendingClaim();
            },
          ),
        _Phase.ready => HomeScreen(
            controller: _controller!,
            onWalletErased: _forget,
            lock: _lock,
            auth: _auth,
          ),
        _Phase.failed => _Failed(message: _error!, onRetry: _load),
      };
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: TipPalette.heroGradient),
        child: Center(
          child: CircularProgressIndicator(color: TipPalette.accent),
        ),
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.lock_outline,
                size: 40,
                color: TipPalette.inkMuted,
              ),
              const SizedBox(height: TipTheme.spaceLg),
              Text(
                'Could not open your wallet',
                style: text.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: TipTheme.spaceSm),
              Text(message, style: text.bodyMedium, textAlign: TextAlign.center),
              const SizedBox(height: TipTheme.spaceXl),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
