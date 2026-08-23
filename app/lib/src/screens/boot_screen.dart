/// What happens before the wallet appears.
///
/// One job: decide whether there is already a wallet on this device. Getting
/// it wrong in the safe-looking direction, by treating an unreadable keystore
/// as "no wallet", would walk the user into onboarding and overwrite a seed
/// that was only temporarily unavailable. So a read that fails is an error the
/// user sees, never a fresh start.
library;

import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet.dart';
import '../wallet/wallet_controller.dart';
import '../wallet/wallet_store.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';

enum _Phase { checking, onboarding, ready, failed }

class BootScreen extends StatefulWidget {
  const BootScreen({super.key, WalletStore? store}) : _store = store;

  final WalletStore? _store;

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> {
  late final WalletStore _store = widget._store ?? WalletStore();

  _Phase _phase = _Phase.checking;
  WalletController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
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
      setState(() {
        _controller = WalletController.forMnemonic(stored);
        _phase = _Phase.ready;
      });
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
      _controller = WalletController.forMnemonic(mnemonic);
      _phase = _Phase.ready;
    });
  }

  @override
  Widget build(BuildContext context) => switch (_phase) {
        _Phase.checking => const _Splash(),
        _Phase.onboarding => OnboardingScreen(onReady: _adopt),
        _Phase.ready => HomeScreen(controller: _controller!),
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
