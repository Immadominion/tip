/// Tip links that have been funded and not yet claimed.
///
/// Saving the secret before the money moves is only half of the fix; the other
/// half is being able to get it back out. Without this screen the store is a
/// safety net nobody can reach, and the link is still effectively lost the
/// moment the tip screen is closed.
///
/// Each row is a bearer secret, so the link itself is never rendered. Copy and
/// share are actions, not text on a page that could be shoulder-surfed or end
/// up in a screenshot.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../claim/pending_tips.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';

class UnclaimedTipsScreen extends StatefulWidget {
  const UnclaimedTipsScreen({super.key, this.store});

  /// Injected in tests; the real one is built on first use.
  final PendingTipsStore? store;

  @override
  State<UnclaimedTipsScreen> createState() => _UnclaimedTipsScreenState();
}

class _UnclaimedTipsScreenState extends State<UnclaimedTipsScreen> {
  late final PendingTipsStore _store = widget.store ?? PendingTipsStore();

  List<PendingTip>? _tips;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tips = await _store.read();
    if (!mounted) return;
    setState(() => _tips = tips);
  }

  Future<void> _forget(PendingTip tip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this link?'),
        content: const Text(
          'This removes the only copy of the secret held on this device. If '
          'nobody else has the link, the money it holds becomes unreachable '
          'for good. Send it to yourself first if you are unsure.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.remove(tip.address);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tips = _tips;

    return Scaffold(
      appBar: AppBar(title: const Text('Unclaimed tips')),
      body: SafeArea(
        child: tips == null
            ? const Center(child: CircularProgressIndicator())
            : tips.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(TipTheme.spaceXl),
                      child: Text(
                        'Nothing here. Tip links you fund are kept until you '
                        'forget them, so a closed app never takes the only '
                        'copy of one with it.',
                        style: text.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(TipTheme.spaceLg),
                    itemCount: tips.length + 1,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: TipTheme.spaceMd),
                    itemBuilder: (context, i) {
                      if (i == 0) return const _Caution();
                      return _Row(
                        tip: tips[i - 1],
                        onForget: () => _forget(tips[i - 1]),
                      );
                    },
                  ),
      ),
    );
  }
}

class _Caution extends StatelessWidget {
  const _Caution();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Text(
        'A tip link is money in a URL. Anyone who has it can claim it, and this '
        'list does not know whether one already has been — it only knows what '
        'this device funded.',
        style: text.bodySmall,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.tip, required this.onForget});

  final PendingTip tip;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.surfaceRaised,
        border: Border.all(color: TipPalette.border),
        borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(tip.amountLabel ?? 'Tip link', style: text.titleSmall),
              const Spacer(),
              Text(_when(tip.createdAt), style: text.labelSmall),
            ],
          ),
          const SizedBox(height: 2),
          // The address, not the link. It identifies the tip without being
          // able to spend it.
          Text(
            _short(tip.address),
            style: text.bodySmall?.copyWith(color: TipPalette.inkMuted),
          ),
          const SizedBox(height: TipTheme.spaceSm),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copy link'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: tip.link));
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      const SnackBar(content: Text('Tip link copied')),
                    );
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.ios_share_rounded, size: 16),
                label: const Text('Share'),
                onPressed: () => SharePlus.instance.share(
                  ShareParams(text: tip.link, subject: 'A tip for you'),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: onForget,
                child: Text(
                  'Forget',
                  style: TextStyle(color: TipPalette.negative),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _short(String address) => address.length <= 14
      ? address
      : '${address.substring(0, 8)}…${address.substring(address.length - 6)}';

  static String _when(DateTime at) {
    final ago = DateTime.now().difference(at);
    if (ago.inMinutes < 1) return 'just now';
    if (ago.inHours < 1) return '${ago.inMinutes}m ago';
    if (ago.inDays < 1) return '${ago.inHours}h ago';
    return '${ago.inDays}d ago';
  }
}
