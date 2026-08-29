/// Claiming a tip.
///
/// Someone arrives here holding a link and, quite possibly, no idea what
/// Starknet is. So the screen has one job: turn the link into a number, say
/// what they will get, and move it. Everything about throwaway accounts,
/// deployments and gas stays out of the way unless something goes wrong.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../activity/activity_entry.dart';
import '../claim/claim_link.dart';
import '../claim/claim_service.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../wallet/wallet_controller.dart';
import 'scan_screen.dart';

enum _Stage { paste, found, claiming, done }

class ClaimScreen extends StatefulWidget {
  const ClaimScreen({super.key, required this.wallet, this.initialLink});

  final WalletController wallet;

  /// Prefilled when the app was opened by a link rather than by hand.
  final String? initialLink;

  @override
  State<ClaimScreen> createState() => _ClaimScreenState();
}

class _ClaimScreenState extends State<ClaimScreen> {
  final _link = TextEditingController();

  late final ClaimService _claims = ClaimService(client: widget.wallet.client);

  _Stage _stage = _Stage.paste;
  bool _busy = false;
  String? _error;
  ClaimKey? _key;
  ClaimStatus? _status;
  ClaimResult? _result;

  @override
  void initState() {
    super.initState();
    _link.addListener(() => setState(() {}));
    final initial = widget.initialLink;
    if (initial != null) {
      _link.text = initial;
      unawaited(_look());
    }
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  String? get _linkProblem {
    if (_link.text.isEmpty) return null;
    try {
      ClaimLinks.parse(
        _link.text,
        accountClassHash: widget.wallet.network.accountClassHash,
      );
      return null;
    } on ClaimLinkException catch (error) {
      return error.message;
    }
  }

  /// Scans a tip code and looks it up straight away.
  ///
  /// Scanning is the phone-to-phone case: one person shows the code, the other
  /// points a camera at it. Making them press a second button afterwards would
  /// be a step with nothing in it.
  Future<void> _scanLink() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const ScanScreen(
          title: 'Scan a tip',
          hint: 'Point the camera at the code on the other phone.',
        ),
      ),
    );
    if (scanned == null || !mounted) return;

    _link.text = scanned.trim();
    if (_linkProblem == null) await _look();
  }

  Future<void> _look() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final key = ClaimLinks.parse(
        _link.text,
        accountClassHash: widget.wallet.network.accountClassHash,
      );
      final status = await _claims.inspect(
        key,
        reference: widget.wallet.keys.signing,
      );
      if (!mounted) return;
      setState(() {
        _key = key;
        _status = status;
        _stage = _Stage.found;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim() async {
    final key = _key;
    if (key == null) return;

    setState(() {
      _stage = _Stage.claiming;
      _error = null;
    });
    try {
      final result = await _claims.claim(
        key: key,
        recipient: widget.wallet.keys.signing,
      );
      await widget.wallet.record(
        ActivityEntry.send(
          kind: ActivityKind.claim,
          txHash: result.transactionHash.toHexString(),
          amount: result.amount,
          counterparty: key.address.toHexString(),
          submittedAt: DateTime.now(),
        ),
      );
      await widget.wallet.client.awaitTransaction(result.transactionHash);
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _Stage.done;
      });
      unawaited(widget.wallet.refresh());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _stage = _Stage.found;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Claim a tip')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: switch (_stage) {
            _Stage.paste => _paste(),
            _Stage.found => _found(),
            _Stage.claiming => _claiming(),
            _Stage.done => _done(),
          },
        ),
      ),
    );
  }

  Widget _paste() {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Paste the tip link you were sent. It goes into this wallet.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: TipTheme.spaceLg),
        TextField(
          controller: _link,
          maxLines: 2,
          autocorrect: false,
          enableSuggestions: false,
          style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: 'https://$claimLinkHost$claimLinkPath#...',
            errorText: _linkProblem,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                  tooltip: 'Scan',
                  onPressed: _scanLink,
                ),
                IconButton(
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  tooltip: 'Paste',
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null) _link.text = data!.text!.trim();
                  },
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(message: _error!),
        ],
        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed:
              _link.text.isEmpty || _linkProblem != null || _busy ? null : _look,
          child: _busy ? const _Spinner() : const Text('Look it up'),
        ),
      ],
    );
  }

  Widget _found() {
    final text = Theme.of(context).textTheme;
    final status = _status!;

    if (status.isEmpty) {
      return _Message(
        icon: Icons.inbox_outlined,
        tint: TipPalette.inkMuted,
        title: 'This link is empty',
        body: 'Either it has already been claimed, or the funding transfer '
            'has not landed yet. If it was only just sent, wait a moment and '
            'look it up again.',
        action: TextButton(onPressed: _look, child: const Text('Look again')),
      );
    }

    // Unpriced is not the same as short. Saying it is short by "a little" when
    // nothing could be estimated invents a fact, and the number it used to
    // invent was that the whole balance was claimable.
    if (status.costUnknown) {
      return _Message(
        icon: Icons.help_outline,
        tint: TipPalette.warning,
        title: 'Cannot work out what this is worth',
        body: 'This link holds ${status.balance.formatWithSymbol()}, but the '
            'network fees to move it could not be estimated just now, so how '
            'much would reach you is unknown. Try again in a moment.',
        action: TextButton(onPressed: _look, child: const Text('Try again')),
      );
    }

    if (!status.canClaim) {
      return _Message(
        icon: Icons.error_outline,
        tint: TipPalette.negative,
        title: 'Not enough in it to claim',
        body: 'This link holds ${status.balance.formatWithSymbol()}, which '
            'does not cover the network fees to move it. It is short by about '
            '${status.shortfall?.formatWithSymbol() ?? 'a little'}. Whoever '
            'sent it can top the same link up.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: TipTheme.spaceLg),
        Center(
          child: Column(
            children: [
              Text('You will get at least', style: text.bodyMedium),
              const SizedBox(height: TipTheme.spaceXs),
              Text(status.claimable.format(), style: text.displayLarge),
              Text(status.claimable.token.symbol, style: text.bodyMedium),
            ],
          ),
        ),
        const SizedBox(height: TipTheme.spaceMd),
        Text(
          'At least, rather than exactly: the network fees are budgeted at '
          'their ceiling and whatever is left over comes to you too.',
          style: text.labelSmall,
          textAlign: TextAlign.center,
        ),
        if (status.deployed) ...[
          const SizedBox(height: TipTheme.spaceMd),
          Text(
            'A claim on this link was started before and did not finish. '
            'Carrying on from here is safe.',
            style: text.labelSmall,
            textAlign: TextAlign.center,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(message: _error!),
        ],
        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: _claim,
          child: const Text('Claim it'),
        ),
      ],
    );
  }

  Widget _claiming() {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TipTheme.space2xl),
      child: Column(
        children: [
          const CircularProgressIndicator(color: TipPalette.accent),
          const SizedBox(height: TipTheme.spaceLg),
          Text('Claiming', style: text.titleMedium),
          const SizedBox(height: TipTheme.spaceXs),
          Text(
            'This takes two transactions: setting up the link’s account, '
            'then emptying it into yours. Give it a minute.',
            style: text.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _done() {
    final result = _result!;
    return _Message(
      icon: Icons.check_circle_rounded,
      tint: TipPalette.positive,
      title: 'Claimed',
      body: '${result.amount.formatWithSymbol()} is in your wallet.',
      action: FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.tint,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: TipTheme.spaceXl),
        Icon(icon, size: 48, color: tint),
        const SizedBox(height: TipTheme.spaceLg),
        Text(title, style: text.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: TipTheme.spaceSm),
        Text(body, style: text.bodyMedium, textAlign: TextAlign.center),
        if (action != null) ...[
          const SizedBox(height: TipTheme.spaceXl),
          action!,
        ],
      ],
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
          const Icon(
            Icons.error_outline,
            size: 18,
            color: TipPalette.negative,
          ),
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
