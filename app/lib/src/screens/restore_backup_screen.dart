/// Opening a backup on a new phone.
///
/// The moment this screen exists for is the one the whole feature is about:
/// somebody has a new phone, has just signed in, and wants their wallet back
/// without having typed twenty-four words. All that is left is the password.
///
/// It is also where someone discovers they have forgotten it, so the way out
/// is on the screen from the start rather than after three failures.
library;

import 'package:flutter/material.dart';

import '../backup/backup_service.dart';
import '../backup/seed_vault.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';

class RestoreBackupScreen extends StatefulWidget {
  const RestoreBackupScreen({
    super.key,
    required this.service,
    required this.onRestored,
    required this.onUsePhrase,
  });

  final BackupService service;

  /// Called with the recovered phrase.
  final Future<void> Function(String mnemonic) onRestored;

  /// The way out for someone who has forgotten the password.
  final VoidCallback onUsePhrase;

  @override
  State<RestoreBackupScreen> createState() => _RestoreBackupScreenState();
}

class _RestoreBackupScreenState extends State<RestoreBackupScreen> {
  final _password = TextEditingController();

  bool _shown = false;
  bool _busy = false;
  int _attempts = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mnemonic = await widget.service.restore(password: _password.text);
      await widget.onRestored(mnemonic);
    } on SeedVaultException catch (failure) {
      if (mounted) {
        setState(() {
          _attempts++;
          _error = failure.message;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Unlock your backup')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: TipTheme.spaceSm),
              Center(
                child: Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: TipPalette.actionGradient,
                    borderRadius: BorderRadius.circular(TipTheme.radiusMedium),
                  ),
                  child: const Icon(
                    Icons.lock_open_outlined,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
              const SizedBox(height: TipTheme.spaceLg),
              Text(
                'There is a backup on this account',
                style: text.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: TipTheme.spaceXs),
              Text(
                'Type the password you sealed it with and your wallet comes '
                'back exactly as it was.',
                style: text.bodyMedium,
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: TipTheme.spaceXl),
              TextField(
                controller: _password,
                obscureText: !_shown,
                autocorrect: false,
                enableSuggestions: false,
                autofocus: true,
                onSubmitted: (_) => _busy ? null : _open(),
                decoration: InputDecoration(
                  hintText: 'Backup password',
                  suffixIcon: IconButton(
                    tooltip: _shown ? 'Hide' : 'Show',
                    icon: Icon(
                      _shown
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _shown = !_shown),
                  ),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: TipTheme.spaceMd),
                _Problem(message: _error!),
              ],

              const SizedBox(height: TipTheme.spaceXl),
              FilledButton(
                onPressed: _password.text.isEmpty || _busy ? null : _open,
                child: _busy ? const _Spinner() : const Text('Unlock'),
              ),

              const SizedBox(height: TipTheme.spaceLg),
              // Present from the start, not surfaced after three failures.
              // Somebody who knows straight away that they have forgotten the
              // password should not have to prove it to the app first.
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(TipTheme.spaceMd),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _attempts >= 2
                            ? 'Still not opening?'
                            : 'Forgotten the password?',
                        style: text.titleSmall,
                      ),
                      const SizedBox(height: TipTheme.spaceXs),
                      Text(
                        'Nobody can reset it, including us. Your twenty-four '
                        'word recovery phrase still works and does the same '
                        'job.',
                        style: text.bodySmall,
                      ),
                      const SizedBox(height: TipTheme.spaceMd),
                      OutlinedButton(
                        onPressed: _busy ? null : widget.onUsePhrase,
                        child: const Text('Use my recovery phrase'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.negative.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: TipPalette.negative),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: TipPalette.negative),
            ),
          ),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
}
