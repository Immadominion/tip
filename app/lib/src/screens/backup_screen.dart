/// Choosing a password for a backup.
///
/// The screen exists to make one thing unmissable before anyone commits to it:
/// this password cannot be reset. Not by us, not by support, not by proving
/// who you are. Every wallet that has ever offered a "forgot password" link
/// for an encrypted backup was either storing the key or lying, and saying so
/// up front is cheaper than saying it afterwards.
library;

import 'package:flutter/material.dart';

import '../backup/backup_service.dart';
import '../backup/seed_vault.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    required this.service,
    required this.mnemonic,
    this.replacing = false,
  });

  final BackupService service;

  /// The phrase to seal. Never leaves this screen unsealed.
  final String mnemonic;

  /// True when a backup already exists and this one will replace it.
  final bool replacing;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _shown = false;
  bool _understood = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
    _confirm.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? get _passwordProblem =>
      _password.text.isEmpty ? null : SeedVault.passwordProblem(_password.text);

  String? get _confirmProblem {
    if (_confirm.text.isEmpty) return null;
    return _confirm.text == _password.text ? null : 'These do not match';
  }

  bool get _ready =>
      !_busy &&
      _understood &&
      _password.text.isNotEmpty &&
      _passwordProblem == null &&
      _confirmProblem == null &&
      _confirm.text.isNotEmpty;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.create(
        mnemonic: widget.mnemonic,
        password: _password.text,
      );
      if (mounted) Navigator.of(context).pop(true);
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
      appBar: AppBar(
        title: Text(widget.replacing ? 'Change the password' : 'Back up'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.replacing
                    ? 'Your phrase will be sealed again under the new password. '
                        'The old one stops working.'
                    : 'Your recovery phrase gets locked with a password and '
                        'stored. Signing in on another phone and typing this '
                        'password brings your wallet back.',
                style: text.bodyMedium,
              ),

              const SizedBox(height: TipTheme.spaceLg),
              const _NoResets(),

              const SizedBox(height: TipTheme.spaceLg),
              Text('Password', style: text.labelSmall),
              const SizedBox(height: TipTheme.spaceXs),
              TextField(
                controller: _password,
                obscureText: !_shown,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  errorText: _passwordProblem,
                  errorMaxLines: 3,
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

              const SizedBox(height: TipTheme.spaceMd),
              Text('Again', style: text.labelSmall),
              const SizedBox(height: TipTheme.spaceXs),
              TextField(
                controller: _confirm,
                obscureText: !_shown,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(errorText: _confirmProblem),
              ),

              const SizedBox(height: TipTheme.spaceMd),
              CheckboxListTile(
                value: _understood,
                onChanged: (value) =>
                    setState(() => _understood = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'I have written this password down somewhere safe.',
                  style: text.bodyMedium,
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: TipTheme.spaceMd),
                _Problem(message: _error!),
              ],

              const SizedBox(height: TipTheme.spaceXl),
              FilledButton(
                onPressed: _ready ? _save : null,
                child: _busy
                    ? const _Spinner()
                    : Text(widget.replacing ? 'Re-seal the backup' : 'Back up'),
              ),
              const SizedBox(height: TipTheme.spaceSm),
              Text(
                'Sealing takes a moment. The password is deliberately slow to '
                'turn into a key, which is what makes guessing it expensive.',
                style: text.labelSmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The warning that has to land before anything else on this screen.
class _NoResets extends StatelessWidget {
  const _NoResets();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
        border: Border.all(
          color: TipPalette.warning.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 20,
            color: TipPalette.warning,
          ),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'There is no way to reset this',
                  style: text.titleSmall?.copyWith(color: TipPalette.warning),
                ),
                const SizedBox(height: 4),
                Text(
                  'We store the backup locked and we do not have the key. If '
                  'you forget this password the backup is scrap, and only your '
                  'recovery phrase gets the wallet back.',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
        ],
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
