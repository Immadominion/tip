/// Turning a failed private operation into something worth reading.
///
/// The screens used to fall back to interpolating the exception, so a prover
/// that was down reached the user as `ClientException with SocketException:
/// Failed host lookup`. That is bad on its own, but the real problem is what it
/// leaves out: after a minute of waiting and a confirmation tap, the one thing
/// somebody needs to know is whether their money moved.
///
/// The answer is knowable, and it is knowable from the stage. Proving touches
/// nothing on chain, and submission either produced a transaction hash or threw
/// before broadcasting. Only a failure while waiting is genuinely ambiguous,
/// and that one gets said out loud rather than smoothed over.
library;

import 'package:tip_privacy/tip_privacy.dart' as tp;

import 'pool_session.dart';
import 'private_operations.dart';

/// A failure, described for the person who was waiting on it.
class OperationFailure {
  const OperationFailure({required this.message, required this.settled});

  /// One or two plain sentences. Ends with what happened to the funds when
  /// that is known.
  final String message;

  /// Whether the outcome is known. False only when a transaction is on chain
  /// and we could not read how it ended.
  final bool settled;

  @override
  String toString() => message;
}

/// Describes [error], which happened during [stage].
OperationFailure describeFailure(Object error, {OperationStage? stage}) {
  final untouched = _nothingMoved(stage);
  final reassurance = switch (stage) {
    OperationStage.waiting =>
      ' The transaction was submitted, so check it on the explorer before '
          'trying again.',
    _ when untouched => ' Nothing was submitted and your balance is unchanged.',
    _ => '',
  };

  return OperationFailure(
    message: _sentenceFor(error, stage) + reassurance,
    settled: untouched,
  );
}

/// Whether a failure at [stage] can only have left the chain alone.
bool _nothingMoved(OperationStage? stage) => switch (stage) {
      OperationStage.reading ||
      OperationStage.proving ||
      OperationStage.submitting =>
        true,
      // Past submission the hash exists, so this is the one case where we do
      // not get to promise anything.
      OperationStage.waiting => false,
      null => true,
    };

String _sentenceFor(Object error, OperationStage? stage) {
  switch (error) {
    case OperationRefused():
      return error.message;

    case PoolException():
      return error.message;

    case tp.TransportException():
      // Naming which service failed is the difference between a user checking
      // their connection and a user reporting a real outage.
      final who = stage == OperationStage.proving
          ? 'The proving service'
          : 'A service this wallet needs';
      return error.timedOut
          ? '$who did not answer in time.'
          : '$who could not be reached.';

    case tp.ProvingException():
      return switch (error.code) {
        tp.serviceBusyCode =>
          'The proving service is busy. It kept saying so, so this is worth '
              'trying again in a minute.',
        10000 => 'This transaction was rejected by the compliance screening '
            'the pool applies to deposits.',
        24 => 'The proof was built against a block the pool no longer accepts. '
            'Trying again picks a newer one.',
        _ => 'The proving service could not prove this transaction.',
      };

    case tp.InsufficientNotesException():
      return 'Your shielded balance does not cover this amount.';

    case tp.ReorgException():
      return 'The chain reorganised while this was in flight, so the notes '
          'this was built from have to be read again.';

    case tp.DiscoveryException():
      return 'The discovery service could not return this wallet\'s notes.';

    case tp.ProtocolException():
      return 'A service answered in a shape this wallet does not understand.';

    default:
      return 'This did not go through.';
  }
}
