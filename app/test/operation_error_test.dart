/// What a user is told when a private operation fails.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/privacy/operation_error.dart';
import 'package:tip/src/privacy/pool_session.dart';
import 'package:tip/src/privacy/private_operations.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

void main() {
  group('describeFailure', () {
    test('a prover that cannot be reached is named, and so are the funds', () {
      final failure = describeFailure(
        const tp.TransportException('boom', host: 'prover.example'),
        stage: OperationStage.proving,
      );
      expect(failure.message, contains('proving service'));
      expect(failure.message, contains('balance is unchanged'));
      expect(failure.settled, isTrue);
    });

    test('a timeout says it was abandoned, not refused', () {
      final failure = describeFailure(
        const tp.TransportException(
          'slow',
          host: 'prover.example',
          timedOut: true,
        ),
        stage: OperationStage.proving,
      );
      expect(failure.message, contains('did not answer in time'));
    });

    test('failing while waiting promises nothing', () {
      // The one case where the wallet does not know. A transaction hash
      // exists, so telling the user their balance is untouched would be a
      // guess, and the guess is wrong exactly when it matters.
      final failure = describeFailure(
        const tp.TransportException('gone', host: 'rpc.example'),
        stage: OperationStage.waiting,
      );
      expect(failure.settled, isFalse);
      expect(failure.message, isNot(contains('balance is unchanged')));
      expect(failure.message, contains('explorer'));
    });

    test('a refusal is passed through as written', () {
      final failure = describeFailure(
        const OperationRefused('This wallet is already registered'),
        stage: OperationStage.reading,
      );
      expect(failure.message, startsWith('This wallet is already registered'));
    });

    test('a pool error keeps its own message', () {
      final failure = describeFailure(
        const PoolException('The pool rejected the batch'),
        stage: OperationStage.submitting,
      );
      expect(failure.message, startsWith('The pool rejected the batch'));
    });

    test('screening rejection is not reported as a network problem', () {
      final failure = describeFailure(
        const tp.ProvingException(10000, 'rejected'),
        stage: OperationStage.proving,
      );
      expect(failure.message, contains('compliance screening'));
    });

    test('a busy prover is described as worth retrying', () {
      final failure = describeFailure(
        const tp.ProvingException(tp.serviceBusyCode, 'busy'),
        stage: OperationStage.proving,
      );
      expect(failure.message, contains('trying again'));
    });

    test('a stale proof block explains itself', () {
      final failure = describeFailure(
        const tp.ProvingException(24, 'block not found'),
        stage: OperationStage.proving,
      );
      expect(failure.message, contains('newer'));
    });

    test('an unrecognised error still says something and still reassures', () {
      final failure = describeFailure(
        StateError('nothing anyone planned for'),
        stage: OperationStage.proving,
      );
      expect(failure.message, contains('did not go through'));
      expect(failure.message, contains('balance is unchanged'));
      // Above all, it does not put a Dart type name in front of the user.
      expect(failure.message, isNot(contains('StateError')));
    });
  });
}
