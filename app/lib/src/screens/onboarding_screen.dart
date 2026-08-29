/// First launch.
///
/// Two jobs: create a wallet, and make sure the user actually saves the phrase
/// that recovers it. The second is the one wallets usually get wrong, by
/// showing the words behind a "I have written this down" checkbox that nobody
/// reads. This screen makes the user confirm three of the words before it will
/// continue.
library;

import 'package:flutter/material.dart';

import '../theme/palette.dart';
import 'restore_backup_screen.dart';
import 'sign_in_screen.dart';
import '../security/secret_clipboard.dart';
import '../theme/theme.dart';
import '../auth/auth_service.dart';
import '../backup/backup_service.dart';
import '../wallet/wallet.dart';
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onReady});

  /// Called with a phrase the user has created and confirmed, or restored.
  /// Whoever supplies this is responsible for saving it before the wallet is
  /// shown.
  final Future<void> Function(String mnemonic) onReady;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, showPhrase, confirmPhrase, restore }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step _step = _Step.welcome;
  String? _mnemonic;
  bool _saving = false;

  void _createWallet() {
    setState(() {
      _mnemonic = WalletFactory.generateMnemonic();
      _step = _Step.showPhrase;
    });
  }

  /// Signs in, then either brings a wallet back or makes one.
  ///
  /// This is the whole point of sign-in: on a second phone there is a sealed
  /// phrase waiting, and the only thing between the user and their wallet is
  /// the password they chose. On a first phone there is nothing waiting, so it
  /// falls through to creating one.
  Future<void> _signIn() async {
    final auth = AuthService();
    if (!auth.isAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign-in is not available in this build')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SignInScreen(
          auth: auth,
          onSignedIn: () => Navigator.of(context).pop(),
        ),
      ),
    );
    if (!mounted || !auth.isSignedIn) return;

    setState(() => _saving = true);
    final hasBackup = await BackupService().exists();
    if (!mounted) return;
    setState(() => _saving = false);

    if (!hasBackup) {
      _createWallet();
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RestoreBackupScreen(
          service: BackupService(),
          onRestored: (mnemonic) async {
            Navigator.of(context).pop();
            await _finish(mnemonic);
          },
          onUsePhrase: () {
            Navigator.of(context).pop();
            setState(() => _step = _Step.restore);
          },
        ),
      ),
    );
  }

  Future<void> _finish(String mnemonic) async {
    setState(() => _saving = true);
    try {
      await widget.onReady(mnemonic);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: TipPalette.heroGradient),
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            child: switch (_step) {
              _Step.welcome => _Welcome(
                onCreate: _createWallet,
                onRestore: () => setState(() => _step = _Step.restore),
                onSignIn: _signIn,
              ),
              _Step.restore => _Restore(
                busy: _saving,
                onBack: () => setState(() => _step = _Step.welcome),
                onRestore: _finish,
              ),
              _Step.showPhrase => _ShowPhrase(
                mnemonic: _mnemonic!,
                onContinue: () => setState(() => _step = _Step.confirmPhrase),
              ),
              _Step.confirmPhrase => _ConfirmPhrase(
                mnemonic: _mnemonic!,
                onBack: () => setState(() => _step = _Step.showPhrase),
                busy: _saving,
                onConfirmed: () => _finish(_mnemonic!),
              ),
            },
          ),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({
    required this.onCreate,
    required this.onRestore,
    required this.onSignIn,
  });

  final VoidCallback onCreate;
  final VoidCallback onRestore;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.all(TipTheme.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          Text('tip', style: text.displayLarge),
          const SizedBox(height: TipTheme.spaceSm),
          Text(
            'Money that is nobody else’s business.',
            style: text.headlineMedium?.copyWith(color: TipPalette.inkMuted),
          ),
          const SizedBox(height: TipTheme.spaceMd),
          Text(
            'Send and receive on Starknet without publishing who you paid, '
            'who paid you, or how much.',
            style: text.bodyMedium,
          ),
          const Spacer(),
          FilledButton(
            onPressed: onCreate,
            child: const Text('Create a wallet'),
          ),
          const SizedBox(height: TipTheme.spaceSm),
          OutlinedButton(
            onPressed: onSignIn,
            child: const Text('Sign in'),
          ),
          const SizedBox(height: TipTheme.spaceSm),
          OutlinedButton(
            onPressed: onRestore,
            child: const Text('I already have a phrase'),
          ),
          const SizedBox(height: TipTheme.spaceMd),
        ],
      ),
    );
  }
}

class _ShowPhrase extends StatelessWidget {
  const _ShowPhrase({required this.mnemonic, required this.onContinue});

  final String mnemonic;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final words = mnemonic.split(' ');

    return Padding(
      padding: const EdgeInsets.all(TipTheme.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: TipTheme.spaceMd),
          Text('Your recovery phrase', style: text.headlineMedium),
          const SizedBox(height: TipTheme.spaceSm),
          Text(
            'These 24 words are the only way back to this wallet. Write them '
            'down on paper. Anyone who reads them can spend your money and '
            'read your whole history.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: TipTheme.spaceLg),
          Expanded(
            child: SingleChildScrollView(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(TipTheme.spaceMd),
                  child: Wrap(
                    spacing: TipTheme.spaceSm,
                    runSpacing: TipTheme.spaceSm,
                    children: [
                      for (var i = 0; i < words.length; i++)
                        _WordChip(index: i + 1, word: words[i]),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: TipTheme.spaceMd),
          TextButton.icon(
            onPressed: () {
              SecretClipboard.copy(mnemonic);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Copied. It clears from the clipboard in a minute, or '
                    'when you leave the app.',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy'),
          ),
          const SizedBox(height: TipTheme.spaceSm),
          FilledButton(
            onPressed: onContinue,
            child: const Text('I have written it down'),
          ),
          const SizedBox(height: TipTheme.spaceMd),
        ],
      ),
    );
  }
}

class _WordChip extends StatelessWidget {
  const _WordChip({required this.index, required this.word});

  final int index;
  final String word;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: TipTheme.spaceSm + 2,
        vertical: TipTheme.spaceSm,
      ),
      decoration: BoxDecoration(
        color: TipPalette.surfaceSunken,
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$index', style: text.labelSmall),
          const SizedBox(width: TipTheme.spaceSm),
          Text(word, style: text.titleMedium),
        ],
      ),
    );
  }
}

/// Asks for three words back before letting the user through.
///
/// Picking the positions from the phrase itself rather than always asking for
/// the same three means a user cannot learn to screenshot only part of it.
class _ConfirmPhrase extends StatefulWidget {
  const _ConfirmPhrase({
    required this.mnemonic,
    required this.onBack,
    required this.onConfirmed,
    required this.busy,
  });

  final String mnemonic;
  final VoidCallback onBack;
  final VoidCallback onConfirmed;

  /// True while the phrase is being written to the keystore.
  final bool busy;

  @override
  State<_ConfirmPhrase> createState() => _ConfirmPhraseState();
}

class _ConfirmPhraseState extends State<_ConfirmPhrase> {
  late final List<int> _positions;
  late final List<TextEditingController> _controllers;
  String? _error;

  @override
  void initState() {
    super.initState();
    final words = widget.mnemonic.split(' ');
    // Spread the checks across the phrase so a user who only copied the first
    // line cannot pass.
    _positions = [2, words.length ~/ 2, words.length - 1];
    _controllers = List.generate(3, (_) => TextEditingController());
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _check() {
    final words = widget.mnemonic.split(' ');
    for (var i = 0; i < _positions.length; i++) {
      final expected = words[_positions[i]];
      if (_controllers[i].text.trim().toLowerCase() != expected) {
        setState(
          () => _error =
              'Word ${_positions[i] + 1} does not match. Check your paper.',
        );
        return;
      }
    }
    widget.onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.all(TipTheme.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: TipTheme.spaceMd),
          Text('Check your phrase', style: text.headlineMedium),
          const SizedBox(height: TipTheme.spaceSm),
          Text(
            'Type these three words to confirm you have the phrase saved.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: TipTheme.spaceLg),
          for (var i = 0; i < _positions.length; i++) ...[
            Text('Word ${_positions[i] + 1}', style: text.labelSmall),
            const SizedBox(height: TipTheme.spaceXs),
            TextField(
              controller: _controllers[i],
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(hintText: 'word'),
            ),
            const SizedBox(height: TipTheme.spaceMd),
          ],
          if (_error != null)
            Text(
              _error!,
              style: text.bodyMedium?.copyWith(color: TipPalette.negative),
            ),
          const Spacer(),
          FilledButton(
            onPressed: widget.busy ? null : _check,
            child: widget.busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Confirm'),
          ),
          const SizedBox(height: TipTheme.spaceSm),
          TextButton(
            onPressed: widget.busy ? null : widget.onBack,
            child: const Text('Show me the phrase again'),
          ),
          const SizedBox(height: TipTheme.spaceMd),
        ],
      ),
    );
  }
}

/// Restoring a wallet from a phrase the user already has.
///
/// The checksum is the whole point of this screen. A BIP39 phrase with one
/// mistyped word still derives a valid, empty wallet, so without the check the
/// user is shown a working wallet with none of their money in it and no
/// explanation. Checking here turns that into a typo they can fix.
class _Restore extends StatefulWidget {
  const _Restore({
    required this.onBack,
    required this.onRestore,
    required this.busy,
  });

  final VoidCallback onBack;
  final Future<void> Function(String mnemonic) onRestore;
  final bool busy;

  @override
  State<_Restore> createState() => _RestoreState();
}

class _RestoreState extends State<_Restore> {
  final _phrase = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _phrase.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  /// Whitespace and case are the user's problem to make, not to fix.
  String get _normalised =>
      _phrase.text.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  int get _wordCount => _normalised.isEmpty ? 0 : _normalised.split(' ').length;

  void _submit() {
    if (!WalletFactory.isValidMnemonic(_normalised)) {
      setState(() {
        _error = _wordCount == 12 || _wordCount == 24
            ? 'That phrase does not check out. One of the words is probably '
                'misspelled or in the wrong place.'
            : 'A recovery phrase is 12 or 24 words. This one has $_wordCount.';
      });
      return;
    }
    widget.onRestore(_normalised);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.all(TipTheme.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: TipTheme.spaceMd),
          Text('Restore a wallet', style: text.headlineMedium),
          const SizedBox(height: TipTheme.spaceSm),
          Text(
            'Type or paste your recovery phrase. The words go in the order '
            'you wrote them down.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: TipTheme.spaceLg),
          TextField(
            controller: _phrase,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            decoration: InputDecoration(
              hintText: 'abandon ability able ...',
              errorText: _error,
              helperText: _wordCount == 0 ? null : '$_wordCount words',
            ),
          ),
          const Spacer(),
          FilledButton(
            onPressed: _wordCount == 0 || widget.busy ? null : _submit,
            child: widget.busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Restore wallet'),
          ),
          const SizedBox(height: TipTheme.spaceSm),
          TextButton(onPressed: widget.busy ? null : widget.onBack, child: const Text('Back')),
          const SizedBox(height: TipTheme.spaceMd),
        ],
      ),
    );
  }
}
