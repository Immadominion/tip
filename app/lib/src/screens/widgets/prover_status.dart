/// A warning that the slow step is not going to work.
///
/// Proving is the one piece a self-custody wallet cannot do for itself, so it
/// is also the piece most likely to be down. Finding that out at the end costs
/// a minute of somebody's attention to arrive at an answer this gets in a
/// second, so the screens ask first.
///
/// It warns and does not block. A health check is evidence, not authority: if
/// it is wrong, refusing to let someone send their own money is a worse
/// failure than letting them try and telling them plainly if it does not work.
library;

import 'package:flutter/material.dart';

import '../../privacy/pool_session.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';

class ProverStatus extends StatefulWidget {
  const ProverStatus({super.key, required this.session});

  final PoolSession session;

  @override
  State<ProverStatus> createState() => _ProverStatusState();
}

class _ProverStatusState extends State<ProverStatus> {
  /// Null until the first answer, so a slow check shows nothing rather than
  /// flashing a warning it is about to withdraw.
  bool? _reachable;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final reachable = await widget.session.proverReachable();
    if (!mounted) return;
    setState(() => _reachable = reachable);
  }

  @override
  Widget build(BuildContext context) {
    if (_reachable != false) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;

    // The gap belongs to the warning, so a screen with a healthy prover has
    // no dead space where it would have been.
    return Container(
      margin: const EdgeInsets.only(top: TipTheme.spaceMd),
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.cloud_off, size: 18, color: TipPalette.warning),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The proving service is not answering',
                  style: text.labelMedium?.copyWith(color: TipPalette.warning),
                ),
                const SizedBox(height: 2),
                Text(
                  'Private transactions need a proof, and this wallet cannot '
                  'build one on its own. You can still try, but it is likely '
                  'to fail without moving anything.',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() => _reachable = null);
              _check();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
