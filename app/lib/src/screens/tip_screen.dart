/// Creating a tip link.
///
/// The screen has one idea to get across that a normal send does not: this is
/// bearer money. Whoever reads the link can take it. Everything else here is
/// arithmetic, shown rather than hidden, because a tip costs more in fees than
/// a transfer does and finding that out afterwards would feel like a trick.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../activity/activity_entry.dart';
import '../chain/amount.dart';
import '../claim/claim_service.dart';
import '../claim/pending_tips.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet_controller.dart';
import '../widgets/address_qr.dart';

class TipScreen extends StatefulWidget {
  const TipScreen({super.key, required this.wallet});

  final WalletController wallet;

  @override
  State<TipScreen> createState() => _TipScreenState();
}

class _TipScreenState extends State<TipScreen> {
  final _amount = TextEditingController();

  late final ClaimService _claims = ClaimService(client: widget.wallet.client);

  /// Holds the link before the money moves, so an app killed at the wrong
  /// moment does not take the only copy of the secret with it.
  final PendingTipsStore _pending = PendingTipsStore();

  TokenAmount? _fees;
  bool _pricing = false;
  bool _busy = false;
  String? _error;
  ClaimIssue? _issue;

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
    unawaited(_loadFees());
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _loadFees() async {
    setState(() {
      _pricing = true;
      _error = null;
    });
    try {
      final fees = await _claims.estimateClaimCost(widget.wallet.keys.signing);
      if (mounted) setState(() => _fees = fees);
    } catch (error) {
      // The exception already says what went wrong. Prefixing it produces the
      // sort of doubled sentence that makes an app look like it is reading its
      // own stack trace out loud.
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _pricing = false);
    }
  }

  TokenAmount? get _wanted =>
      TokenAmount.tryParse(_amount.text, widget.wallet.network.feeToken);

  TokenAmount? get _total {
    final wanted = _wanted;
    final fees = _fees;
    if (wanted == null || fees == null) return null;
    return TokenAmount(wanted.raw + fees.raw, wanted.token);
  }

  bool get _ready =>
      !_busy && _total != null && _wanted != null && !_wanted!.isZero;

  Future<void> _create() async {
    final total = _total;
    if (total == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final issue = await _claims.createTip(
        from: widget.wallet.keys.signing,
        amount: total,
        // Saved before the transaction goes out. The link is the money, and
        // this is the only window in which losing it is unrecoverable.
        onKeyCreated: (key) => _pending.add(
          PendingTip(
            link: key.link().toString(),
            address: key.address.toHexString(),
            createdAt: DateTime.now(),
            amountLabel: total.formatWithSymbol(),
          ),
        ),
      );
      await widget.wallet.record(
        ActivityEntry.send(
          kind: ActivityKind.tip,
          txHash: issue.transactionHash.toHexString(),
          amount: total,
          counterparty: issue.key.address.toHexString(),
          submittedAt: DateTime.now(),
        ),
      );
      if (!mounted) return;
      setState(() => _issue = issue);
      unawaited(widget.wallet.refresh());
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Whether the link has been copied or shared since it was funded.
  ///
  /// Not a claim that the recipient has it — only that it left this screen by
  /// some route the user chose.
  bool _shared = false;

  Future<bool> _confirmLeave() async {
    if (_issue == null || _shared) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave without the link?'),
        content: const Text(
          'This tip is funded and the link is the only way to reach it. It is '
          'saved under Unclaimed tips in Settings, so it is not lost — but '
          'nobody can claim it until you send it to them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && mounted) {
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_issue == null ? 'Send a tip' : 'Tip link')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: _issue == null ? _compose() : _created(_issue!),
        ),
      ),
    );
  }

  Widget _compose() {
    final text = Theme.of(context).textTheme;
    final token = widget.wallet.network.feeToken;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'A tip link works for someone who has no wallet yet. They install '
          'tip, open the link, and the money is theirs.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: TipTheme.spaceXl),

        Row(
          children: [
            Text('They receive', style: text.labelSmall),
            const Spacer(),
            Text(
              'Balance ${widget.wallet.balanceOf(token).formatWithSymbol()}',
              style: text.labelSmall,
            ),
          ],
        ),
        const SizedBox(height: TipTheme.spaceXs),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: text.headlineMedium,
          decoration: InputDecoration(
            hintText: '0',
            suffixText: token.symbol,
          ),
        ),

        const SizedBox(height: TipTheme.spaceLg),
        Card(
          child: Column(
            children: [
              _Line(
                label: 'Fees to create and claim',
                value: _fees?.formatWithSymbol() ??
                    (_pricing ? 'working it out' : 'unknown'),
              ),
              _Line(
                label: 'Total you pay',
                value: _total?.formatWithSymbol() ?? '—',
              ),
            ],
          ),
        ),
        const SizedBox(height: TipTheme.spaceSm),
        Text(
          'A tip costs two transactions rather than one, because the link '
          'holds the money in an account of its own until it is claimed. '
          'Whatever the fees do not use goes to the person claiming it, not '
          'back to you.',
          style: text.labelSmall,
        ),

        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Warning(message: _error!, tone: TipPalette.negative),
          const SizedBox(height: TipTheme.spaceSm),
          // Pricing a tip is one network call, and a free endpoint dropping it
          // should not leave the screen permanently dead.
          OutlinedButton(
            onPressed: _pricing ? null : _loadFees,
            child: const Text('Try again'),
          ),
        ],

        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: _ready ? _create : null,
          child: _busy
              ? const _Spinner()
              : Text(
                  _total == null
                      ? 'Create the link'
                      : 'Pay ${_total!.formatWithSymbol()}',
                ),
        ),
      ],
    );
  }

  Widget _created(ClaimIssue issue) {
    final text = Theme.of(context).textTheme;
    final link = issue.key.link().toString();
    // The QR carries the app's own scheme rather than the https link. A camera
    // pointed at https opens a browser, and until usetip.xyz serves its
    // association files that browser shows a 404 instead of the tip.
    final scannable = issue.key.appLink().toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Column(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                size: 40,
                color: TipPalette.positive,
              ),
              const SizedBox(height: TipTheme.spaceMd),
              Text('The link is funded', style: text.titleLarge),
              const SizedBox(height: TipTheme.spaceXs),
              Text(
                'Hand it to whoever you are tipping.',
                style: text.bodyMedium,
              ),
            ],
          ),
        ),
        const SizedBox(height: TipTheme.spaceLg),

        Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: TipPalette.surfaceRaised,
              borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
              border: Border.all(color: TipPalette.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(TipTheme.spaceMd),
              child: AddressQr(
                data: scannable,
                size: 200,
                foreground: TipPalette.ink,
                background: TipPalette.surfaceRaised,
              ),
            ),
          ),
        ),

        const SizedBox(height: TipTheme.spaceSm),
        Text(
          'Point a camera at this if they are next to you.',
          style: text.labelSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: TipTheme.spaceLg),
        SelectableText(
          link,
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
        ),

        const SizedBox(height: TipTheme.spaceLg),
        _Warning(
          message: 'Anyone who reads this link can claim it. Send it the way '
              'you would send cash, and remember that a chat history keeps it '
              'claimable by anyone who can read that history later.',
          tone: TipPalette.warning,
        ),

        const SizedBox(height: TipTheme.spaceLg),
        FilledButton.icon(
          icon: const Icon(Icons.ios_share_rounded, size: 18),
          label: const Text('Share the link'),
          onPressed: () {
            setState(() => _shared = true);
            SharePlus.instance.share(
              ShareParams(text: link, subject: 'A tip for you'),
            );
          },
        ),
        const SizedBox(height: TipTheme.spaceSm),
        OutlinedButton.icon(
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Copy'),
          onPressed: () {
            setState(() => _shared = true);
            Clipboard.setData(ClipboardData(text: link));
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                const SnackBar(content: Text('Tip link copied')),
              );
          },
        ),
        const SizedBox(height: TipTheme.spaceSm),
        TextButton(
          onPressed: () async {
            final leave = await _confirmLeave();
            if (leave && mounted) Navigator.of(context).pop();
          },
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TipTheme.spaceMd,
        vertical: TipTheme.spaceSm + 2,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: text.labelSmall),
          Text(value, style: text.titleMedium),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.message, required this.tone});

  final String message;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: tone),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Text(
              message,
              style:
                  Theme.of(context).textTheme.bodyMedium?.copyWith(color: tone),
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
