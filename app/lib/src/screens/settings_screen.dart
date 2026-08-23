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

import '../chain/address.dart';
import '../security/app_lock.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet_controller.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.wallet,
    required this.onErased,
    this.lock,
  });

  final WalletController wallet;

  /// Null in tests that do not exercise the lock.
  final AppLock? lock;

  /// Called once the wallet has been removed from the device.
  final VoidCallback onErased;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _phraseVisible = false;

  bool _lockAvailable = false;
  bool _lockEnabled = false;
  bool _lockBusy = false;

  WalletController get _wallet => widget.wallet;

  @override
  void initState() {
    super.initState();
    _readLock();
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
                ],
              ),
            ),

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

  Future<void> _confirmReveal() async {
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this wallet?'),
        content: const Text(
          'This erases the phrase from this device. If you have not written it '
          'down, the funds are gone and nobody can recover them for you.',
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
      await _wallet.erase();
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
            Clipboard.setData(ClipboardData(text: mnemonic));
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                const SnackBar(
                  content: Text(
                    'Phrase copied. Clear your clipboard when you are done.',
                  ),
                ),
              );
          },
        ),
      ],
    );
  }
}
