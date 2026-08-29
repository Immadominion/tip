/// How a submitted transaction's outcome is classified.
///
/// The bug: `awaitSettled` returned the raw execution-status string and
/// invented `'PENDING'` for its own timeout. Every private result screen then
/// asked `outcome == 'SUCCEEDED'` and rendered everything else as "the
/// transaction reverted and the fee was still charged". For a timeout that is
/// simply false — the transaction was accepted and will most likely land — and
/// it is the case a judge on a slow network is most likely to see.
///
/// Telling someone a private transfer failed when it did not is how they send
/// it a second time.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/privacy/pool_session.dart';

void main() {
  test('SUCCEEDED is success', () {
    expect(Settlement.fromExecutionStatus('SUCCEEDED'), Settlement.succeeded);
    expect(Settlement.fromExecutionStatus('SUCCEEDED').isSuccess, isTrue);
  });

  test('REVERTED is the only thing treated as a failure', () {
    final reverted = Settlement.fromExecutionStatus('REVERTED');
    expect(reverted, Settlement.reverted);
    expect(reverted.isReverted, isTrue);
    expect(reverted.isSuccess, isFalse);
  });

  test('an unknown status is pending, not reverted', () {
    // Starknet has added execution statuses before. Treating a new one as a
    // revert would tell the user their money is gone when it is not.
    for (final status in ['ACCEPTED_ON_L2', 'RECEIVED', 'SOMETHING_NEW', '']) {
      expect(
        Settlement.fromExecutionStatus(status),
        Settlement.pending,
        reason: '$status must not be reported as a revert',
      );
    }
  });

  test('pending is not a failure and not a success', () {
    expect(Settlement.pending.isSuccess, isFalse);
    expect(Settlement.pending.isReverted, isFalse);
    expect(Settlement.pending.isPending, isTrue);
  });

  test('every case is distinct, so no screen can collapse two of them', () {
    expect(Settlement.values.toSet(), hasLength(3));
  });
}
