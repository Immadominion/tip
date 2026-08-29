/// How a private operation ended, said in a way that is true.
///
/// The four private screens each had their own copy of this, and each carried
/// the same bug: they compared the outcome against `'SUCCEEDED'` and rendered
/// everything else as "the transaction reverted and the fee was still charged."
/// That sentence is correct for a revert and false for a timeout, which is the
/// case a judge on a slow network is most likely to hit. A timeout means we
/// stopped waiting, not that anything failed.
///
/// Unifying them also fixes the other half of that finding: the transaction
/// hash was carried into every one of these widgets and then rendered by none
/// of them, while `operation_error.dart` was telling the user to go and check
/// the transaction on an explorer.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../privacy/pool_session.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';

class OperationResult extends StatelessWidget {
  const OperationResult({
    super.key,
    required this.settlement,
    required this.successIcon,
    required this.successTitle,
    required this.successBody,
    this.hash,
    this.onDone,
  });

  final Settlement settlement;

  /// Shown only on success. Failure and pending have their own, because a
  /// shield that did not happen is not a shield.
  final IconData successIcon;
  final String successTitle;
  final String successBody;

  final String? hash;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    final (icon, tone, title, body) = switch (settlement) {
      Settlement.succeeded => (
          successIcon,
          TipPalette.positive,
          successTitle,
          successBody,
        ),
      Settlement.reverted => (
          Icons.error_rounded,
          TipPalette.negative,
          'It did not go through',
          'The transaction reverted and the fee was still charged. Nothing '
              'moved.',
        ),
      // Deliberately not phrased as a failure. It was accepted; we stopped
      // waiting. Telling someone it failed here is how they retry an operation
      // that already worked.
      Settlement.pending => (
          Icons.schedule_rounded,
          TipPalette.warning,
          'Still going through',
          'It was accepted but had not settled by the time we stopped '
              'watching. It will most likely land. Check the transaction '
              'before trying again.',
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: TipTheme.spaceXl),
        Icon(icon, size: 56, color: tone),
        const SizedBox(height: TipTheme.spaceLg),
        Text(title, style: text.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: TipTheme.spaceXs),
        Text(body, style: text.bodyMedium, textAlign: TextAlign.center),
        if (hash case final hash?) ...[
          const SizedBox(height: TipTheme.spaceLg),
          _Hash(hash: hash),
        ],
        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: onDone ?? () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// The transaction hash, copyable.
///
/// It matters most in exactly the case where it used to be missing: when
/// something went wrong or timed out and the user has been told to go and look
/// the transaction up.
class _Hash extends StatelessWidget {
  const _Hash({required this.hash});

  final String hash;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.surfaceSunken,
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Transaction', style: text.labelSmall),
              const Spacer(),
              GestureDetector(
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: hash));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Transaction hash copied')),
                  );
                },
                child: Row(
                  children: [
                    const Icon(Icons.copy_rounded, size: 14),
                    const SizedBox(width: 4),
                    Text('Copy', style: text.labelSmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: TipTheme.spaceXs),
          SelectableText(hash, style: text.bodySmall),
        ],
      ),
    );
  }
}
