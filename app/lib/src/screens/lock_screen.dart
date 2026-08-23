/// The gate in front of a locked wallet.
///
/// It prompts as soon as it appears, because a lock screen that makes you
/// press a button before it will even ask is one extra tap on every launch for
/// no benefit. The button is there for the second attempt, and for the case
/// where the first prompt was dismissed by accident.
library;

import 'package:flutter/material.dart';

import '../security/app_lock.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.lock, required this.onUnlocked});

  final AppLock lock;
  final VoidCallback onUnlocked;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _asking = false;
  bool _refused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
  }

  Future<void> _ask() async {
    if (_asking) return;
    setState(() {
      _asking = true;
      _refused = false;
    });

    final ok = await widget.lock.authenticate();
    if (!mounted) return;

    setState(() {
      _asking = false;
      _refused = !ok;
    });
    if (ok) widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: TipPalette.heroGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(TipTheme.spaceLg),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: TipPalette.actionGradient,
                    borderRadius: BorderRadius.circular(TipTheme.radiusMedium),
                  ),
                  child: const Icon(
                    Icons.lock_outline,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                const SizedBox(height: TipTheme.spaceLg),
                Text('tip', style: text.displayLarge, textAlign: TextAlign.center),
                const SizedBox(height: TipTheme.spaceSm),
                Text(
                  _refused
                      ? 'Not unlocked. Try again when you are ready.'
                      : 'Locked',
                  style: text.bodyMedium?.copyWith(
                    color: _refused ? TipPalette.negative : null,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: TipTheme.spaceXl),
                FilledButton(
                  onPressed: _asking ? null : _ask,
                  child: _asking
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Unlock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
