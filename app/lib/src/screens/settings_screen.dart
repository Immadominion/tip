/// Settings.
///
/// Two of these entries can lose someone their money, so both are built to be
/// hard to do by accident and clear about what they mean. Revealing the phrase
/// puts the whole wallet on screen. Removing the wallet is irreversible from
/// inside the app, and the phrase is the only thing that undoes it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_service.dart';
import '../backup/backup_service.dart';
import '../chain/address.dart';
import '../security/app_lock.dart';
import '../theme/palette.dart';
import '../security/secret_clipboard.dart';
import 'unclaimed_tips_screen.dart';
import '../theme/theme.dart';
import '../wallet/wallet_controller.dart';
import 'backup_screen.dart';
import 'sign_in_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.wallet,
    required this.onErased,
    this.lock,
    this.auth,
  });

  final WalletController wallet;

  /// Null in tests that do not exercise the lock.
  final AppLock? lock;

  /// Null when sign-in is not configured for this build.
  final AuthService? auth;

  /// Called once the wallet has been removed from the device.
  final VoidCallback onErased;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _phraseVisible = false;

  bool _hasBackup = false;
  bool _checkingBackup = false;

  bool _lockAvailable = false;
  bool _lockEnabled = false;
  bool _lockBusy = false;

  WalletController get _wallet => widget.wallet;

  @override
  void initState() {
    super.initState();
    _readLock();
    _readBackup();
  }

  Future<void> _readBackup() async {
    final auth = widget.auth;
    if (auth == null || !auth.isSignedIn) return;
    setState(() => _checkingBackup = true);
    final exists = await BackupService().exists();
    if (!mounted) return;
    setState(() {
      _hasBackup = exists;
      _checkingBackup = false;
    });
  }

  Future<void> _backUp() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => BackupScreen(
          service: BackupService(),
          mnemonic: _wallet.keys.mnemonic,
          replacing: _hasBackup,
        ),
      ),
    );
    if (!mounted) return;
    if (saved ?? false) {
      setState(() => _hasBackup = true);
      _say('Backup saved.');
    }
  }

  Future<void> _removeBackup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove the backup?'),
        content: const Text(
          'The sealed copy is deleted from the server. This wallet stays on '
          'this phone, but signing in on another one will no longer bring it '
          'back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TipPalette.negative,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;

    try {
      await BackupService().remove();
      if (mounted) setState(() => _hasBackup = false);
    } catch (error) {
      if (mounted) _say('Could not remove it: $error');
    }
  }

  Future<void> _signIn() async {
    final auth = widget.auth;
    if (auth == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SignInScreen(
          auth: auth,
          onSignedIn: () => Navigator.of(context).pop(),
        ),
      ),
    );
    if (mounted) {
      setState(() {});
      await _readBackup();
    }
  }

  Future<void> _signOut() async {
    await widget.auth?.signOut();
    if (mounted) setState(() {});
  }

  Future<void> _readLock() async {
    final lock = widget.lock;
    if (lock == null) return;
    final available = await lock.isAvailable;
    final enabled = await lock.isEnabled();
    if (!mounted) return;
    setState(() {
      _lockAvailable = available;
      _lockEnabled = enabled;
    });
  }

  /// Turning the lock on asks for it first.
  ///
  /// Otherwise it is possible to enable a lock the device cannot actually
  /// satisfy, and only find out on the next launch, with the wallet on the
  /// other side of it.
  Future<void> _toggleLock(bool wanted) async {
    final lock = widget.lock;
    if (lock == null) return;

    setState(() => _lockBusy = true);
    try {
      final confirmed = await lock.authenticate(
        reason: wanted ? 'Confirm to turn the lock on' : 'Confirm to turn it off',
      );
      if (!confirmed) {
        if (mounted) _say('Not confirmed, so nothing changed.');
        return;
      }
      await lock.setEnabled(wanted);
      if (mounted) setState(() => _lockEnabled = wanted);
    } finally {
      if (mounted) setState(() => _lockBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final address = _wallet.keys.accountAddress;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          children: [
            Text('Account', style: text.titleLarge),
            const SizedBox(height: TipTheme.spaceMd),
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: Text('Address', style: text.labelSmall),
                    subtitle: SelectableText(
                      StarknetAddress.canonical(address),
                      style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(
                            text: StarknetAddress.canonical(address),
                          ),
                        );
                        _say('Address copied');
                      },
                    ),
                  ),
                  ListTile(
                    title: Text('Network', style: text.labelSmall),
                    subtitle: Text(
                      _wallet.network.label,
                      style: text.bodyMedium,
                    ),
                  ),
                  ListTile(
                    title: Text('Deployed', style: text.labelSmall),
                    subtitle: Text(
                      _wallet.hasLoaded
                          ? (_wallet.isDeployed ? 'Yes' : 'Not yet')
                          : 'Checking',
                      style: text.bodyMedium,
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.open_in_new_rounded, size: 18),
                    title: const Text('View on the explorer'),
                    onTap: () => _open(_wallet.network.addressUrl(address)),
                  ),
                  // A funded tip link is money that only exists in the link, so
                  // there has to be somewhere to get it back from.
                  ListTile(
                    leading: const Icon(Icons.link_rounded, size: 18),
                    title: const Text('Unclaimed tips'),
                    subtitle: const Text('Links you funded and can still send'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const UnclaimedTipsScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            if (widget.auth?.isAvailable ?? false) ...[
              const SizedBox(height: TipTheme.spaceXl),
              Text('Sign-in', style: text.titleLarge),
              const SizedBox(height: TipTheme.spaceMd),
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline, size: 20),
                      title: Text(
                        widget.auth!.isSignedIn ? 'Signed in' : 'Not signed in',
                        style: text.titleMedium,
                      ),
                      subtitle: Text(
                        widget.auth!.displayName ??
                            'Sign in so your wallet can follow you to another '
                                'phone.',
                        style: text.labelSmall,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        TipTheme.spaceMd,
                        0,
                        TipTheme.spaceMd,
                        TipTheme.spaceMd,
                      ),
                      child: widget.auth!.isSignedIn
                          ? OutlinedButton(
                              onPressed: _signOut,
                              child: const Text('Sign out'),
                            )
                          : FilledButton(
                              onPressed: _signIn,
                              child: const Text('Sign in'),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        TipTheme.spaceMd,
                        0,
                        TipTheme.spaceMd,
                        TipTheme.spaceMd,
                      ),
                      child: Text(
                        'Signing out leaves this wallet exactly where it is. '
                        'Your keys are on this phone and no session holds '
                        'them.',
                        style: text.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if ((widget.auth?.isSignedIn ?? false)) ...[
              const SizedBox(height: TipTheme.spaceXl),
              Text('Backup', style: text.titleLarge),
              const SizedBox(height: TipTheme.spaceMd),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(TipTheme.spaceMd),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _checkingBackup
                            ? 'Checking'
                            : _hasBackup
                                ? 'Sealed and stored'
                                : 'No backup yet',
                        style: text.titleMedium,
                      ),
                      const SizedBox(height: TipTheme.spaceXs),
                      Text(
                        _hasBackup
                            ? 'Signing in on another phone and typing your '
                                'backup password brings this wallet back. We '
                                'hold it locked and cannot open it.'
                            : 'Lock your recovery phrase with a password and '
                                'store it, so signing in on a new phone is '
                                'enough to get this wallet back.',
                        style: text.bodyMedium,
                      ),
                      const SizedBox(height: TipTheme.spaceMd),
                      FilledButton(
                        onPressed: _checkingBackup ? null : _backUp,
                        child: Text(
                          _hasBackup ? 'Change the password' : 'Back up',
                        ),
                      ),
                      if (_hasBackup) ...[
                        const SizedBox(height: TipTheme.spaceSm),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: TipPalette.negative,
                          ),
                          onPressed: _removeBackup,
                          child: const Text('Remove the backup'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],

            if (_lockAvailable) ...[
              const SizedBox(height: TipTheme.spaceXl),
              Text('Lock', style: text.titleLarge),
              const SizedBox(height: TipTheme.spaceMd),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      value: _lockEnabled,
                      onChanged: _lockBusy ? null : _toggleLock,
                      title: const Text('Ask to unlock on open'),
                      subtitle: Text(
                        'Face ID, fingerprint, or your device passcode.',
                        style: text.labelSmall,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        TipTheme.spaceMd,
                        0,
                        TipTheme.spaceMd,
                        TipTheme.spaceMd,
                      ),
                      child: Text(
                        'This stops someone who picks up your unlocked phone '
                        'from opening the wallet. It does not encrypt anything '
                        'further: your recovery phrase is already held by the '
                        'device keystore either way.',
                        style: text.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: TipTheme.spaceXl),
            Text('Recovery', style: text.titleLarge),
            const SizedBox(height: TipTheme.spaceMd),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(TipTheme.spaceMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your recovery phrase is the wallet. Anyone who reads it '
                      'can spend everything in it and read everything it has '
                      'ever done, on any device, forever.',
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: TipTheme.spaceMd),
                    if (_phraseVisible)
                      _Phrase(mnemonic: _wallet.keys.mnemonic)
                    else
                      OutlinedButton.icon(
                        icon: const Icon(Icons.visibility_outlined, size: 18),
                        label: const Text('Show recovery phrase'),
                        onPressed: _confirmReveal,
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: TipTheme.spaceXl),
            Text('This device', style: text.titleLarge),
            const SizedBox(height: TipTheme.spaceMd),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(TipTheme.spaceMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Removing the wallet erases the phrase and the activity '
                      'log from this device. The funds stay where they are on '
                      'chain, and your phrase is the only way back to them. '
                      'Deleting the app does not reliably do this.',
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: TipTheme.spaceMd),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: TipPalette.negative,
                      ),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Remove wallet from this device'),
                      onPressed: _confirmErase,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: TipTheme.spaceXl),
          ],
        ),
      ),
    );
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      // No browser, or the platform refused. Copying is the useful fallback,
      // and saying nothing would look like the tap did not register.
      await Clipboard.setData(ClipboardData(text: url));
      _say('Could not open a browser. Link copied instead.');
    }
  }

  /// Device authentication in front of an action that exposes or destroys the
  /// only copy of the money.
  ///
  /// Gated on whether the device *can* authenticate, not on whether the app
  /// lock is switched on. Those are different questions: the lock is a
  /// preference about opening the app, while this is about the three actions
  /// that are irreversible no matter how the app was opened. Revealing the
  /// phrase, copying it, and erasing the wallet were all reachable in three
  /// taps from an unlocked phone, on a screen that already asks for
  /// authentication before letting you toggle a *preference*.
  ///
  /// A device with no authentication at all falls through to the existing
  /// confirmation dialog. Refusing the action entirely would lock someone out
  /// of their own recovery phrase because their phone has no passcode.
  Future<bool> _reauthorize(String reason) async {
    final lock = widget.lock;
    if (lock == null) return true;
    if (!await lock.isAvailable) return true;
    final ok = await lock.authenticate(reason: reason);
    if (!ok && mounted) _say('Not confirmed, so nothing changed.');
    return ok;
  }

  Future<void> _confirmReveal() async {
    if (!await _reauthorize('Confirm to show your recovery phrase')) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Show the phrase?'),
        content: const Text(
          'Make sure nobody can see your screen, and that you are not sharing '
          'it. Screenshots of a recovery phrase end up in cloud backups.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Show it'),
          ),
        ],
      ),
    );
    if (ok ?? false) setState(() => _phraseVisible = true);
  }

  Future<void> _confirmErase() async {
    if (!await _reauthorize('Confirm to remove this wallet')) return;
    if (!mounted) return;
    // What this costs depends on whether there is a backup, and the dialog used
    // to say the funds were gone either way. For someone who made an encrypted
    // backup on purpose that is simply false, and it is the most frightening
    // possible way to be wrong.
    final hasBackup = _hasBackup;

    // Tri-state on purpose: null means keep the backup, which is the safe
    // default and what happens if the dialog is dismissed.
    var alsoDeleteBackup = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Remove this wallet?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasBackup
                    ? 'This erases the phrase from this device. Your encrypted '
                        'backup stays where it is, so you can restore from it '
                        'with your backup password.'
                    : 'This erases the phrase from this device. If you have '
                        'not written it down, the funds are gone and nobody '
                        'can recover them for you.',
              ),
              if (hasBackup) ...[
                const SizedBox(height: TipTheme.spaceMd),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: alsoDeleteBackup,
                  onChanged: (v) =>
                      setDialogState(() => alsoDeleteBackup = v ?? false),
                  title: const Text('Delete the backup too'),
                  subtitle: const Text(
                    'Then nothing is left anywhere, and only the written '
                    'phrase can bring the wallet back.',
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep it'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: TipPalette.negative,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        ),
      ),
    );
    if (!(ok ?? false)) return;

    try {
      // The backup first. Erasing the wallet navigates away, so anything left
      // until afterwards would not run — and a half-done erase that kept the
      // blob while claiming to have removed everything is worse than not
      // offering the option.
      if (alsoDeleteBackup) await BackupService().remove();

      await _wallet.erase();

      // Signing out too. Leaving a session behind means the next person to open
      // the app lands in someone else's account, and after the erase there is
      // no screen left to sign out from.
      await widget.auth?.signOut();

      widget.onErased();
    } catch (error) {
      if (!mounted) return;
      _say('Could not remove the wallet: $error');
    }
  }
}

class _Phrase extends StatelessWidget {
  const _Phrase({required this.mnemonic});

  final String mnemonic;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final words = mnemonic.split(' ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: TipTheme.spaceSm,
          runSpacing: TipTheme.spaceSm,
          children: [
            for (var i = 0; i < words.length; i++)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: TipTheme.spaceSm + 2,
                  vertical: TipTheme.spaceXs + 2,
                ),
                decoration: BoxDecoration(
                  color: TipPalette.surfaceSunken,
                  borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
                ),
                child: Text(
                  '${i + 1}. ${words[i]}',
                  style: text.bodyMedium,
                ),
              ),
          ],
        ),
        const SizedBox(height: TipTheme.spaceMd),
        TextButton.icon(
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Copy phrase'),
          onPressed: () {
            SecretClipboard.copy(mnemonic);
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                const SnackBar(
                  content: Text(
                    'Phrase copied. It clears from the clipboard in a minute, '
                    'or when you leave the app.',
                  ),
                ),
              );
          },
        ),
      ],
    );
  }
}
