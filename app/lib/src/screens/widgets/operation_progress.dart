/// What a private operation is doing while it takes a minute.
///
/// Proving is remote and slow by design, so this names the step rather than
/// spinning silently. A wallet that goes blank for fifty seconds is a wallet
/// people force-quit halfway through a transaction.
library;

import 'package:flutter/material.dart';

import '../../privacy/private_operations.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';

class OperationProgress extends StatelessWidget {
  const OperationProgress({super.key, required this.stage, this.hash});

  final OperationStage stage;

  /// Present once the transaction has been sent.
  final String? hash;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    final (title, detail) = switch (stage) {
      OperationStage.reading => (
          'Reading the pool',
          'Working out where your note goes.',
        ),
      OperationStage.proving => (
          'Proving',
          'This is the slow part, about a minute. The proof is built on a '
              'server because a phone cannot do it in reasonable time.',
        ),
      OperationStage.submitting => (
          'Sending',
          'The proof is done. Putting it on chain.',
        ),
      OperationStage.waiting => (
          'Waiting for the network',
          'Starknet usually confirms in under a minute.',
        ),
    };

    final steps = OperationStage.values;
    final reached = steps.indexOf(stage);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TipTheme.spaceXl),
      child: Column(
        children: [
          const CircularProgressIndicator(color: TipPalette.accent),
          const SizedBox(height: TipTheme.spaceLg),
          Text(title, style: text.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: TipTheme.spaceXs),
          Text(detail, style: text.bodyMedium, textAlign: TextAlign.center),
          const SizedBox(height: TipTheme.spaceXl),
          // A row of pips rather than a percentage. The steps take wildly
          // different amounts of time, so a bar would lie about progress.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < steps.length; i++)
                Container(
                  width: i == reached ? 22 : 8,
                  height: 8,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: i <= reached
                        ? TipPalette.accent
                        : TipPalette.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ],
          ),
          if (hash != null) ...[
            const SizedBox(height: TipTheme.spaceLg),
            Text(
              'Sent. Closing this will not undo it.',
              style: text.labelSmall,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
