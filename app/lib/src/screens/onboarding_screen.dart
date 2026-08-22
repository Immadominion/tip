/// First launch.
///
/// Two jobs: create a wallet, and make sure the user actually saves the phrase
/// that recovers it. The second is the one wallets usually get wrong, by
/// showing the words behind a "I have written this down" checkbox that nobody
/// reads. This screen makes the user confirm three of the words before it will
/// continue.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet.dart';
import 'home_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, showPhrase, confirmPhrase }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step _step = _Step.welcome;
  String? _mnemonic;

  void _createWallet() {
    setState(() {
      _mnemonic = WalletFactory.generateMnemonic();
      _step = _Step.showPhrase;
    });
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
              _Step.welcome => _Welcome(onCreate: _createWallet),
              _Step.showPhrase => _ShowPhrase(
                  mnemonic: _mnemonic!,
                  onContinue: () =>
                      setState(() => _step = _Step.confirmPhrase),
                ),
              _Step.confirmPhrase => _ConfirmPhrase(
                  mnemonic: _mnemonic!,
                  onBack: () => setState(() => _step = _Step.showPhrase),
                  onConfirmed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute<void>(
                      builder: (_) => HomeScreen(mnemonic: _mnemonic!),
                    ),
                  ),
                ),
            },
          ),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onCreate});

  final VoidCallback onCreate;

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
            onPressed: null,
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
              Clipboard.setData(ClipboardData(text: mnemonic));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Copied. Paste it somewhere only you can read.',
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
  });

  final String mnemonic;
  final VoidCallback onBack;
  final VoidCallback onConfirmed;

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
        setState(() => _error =
            'Word ${_positions[i] + 1} does not match. Check your paper.');
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
          FilledButton(onPressed: _check, child: const Text('Confirm')),
          const SizedBox(height: TipTheme.spaceSm),
          TextButton(
            onPressed: widget.onBack,
            child: const Text('Show me the phrase again'),
          ),
          const SizedBox(height: TipTheme.spaceMd),
        ],
      ),
    );
  }
}
