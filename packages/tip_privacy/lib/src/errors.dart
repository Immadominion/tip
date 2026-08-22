/// Errors raised by the privacy client.
library;

/// Base class for every error this package raises.
sealed class PrivacyException implements Exception {
  const PrivacyException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The chain reorganised while a discovery sync was in flight.
///
/// The discovery service reports this as HTTP 409 (`BLOCK_REORGED`). It is not
/// a failure so much as an instruction: discard any locally accumulated notes,
/// channels, and cursor, and sync again from scratch. Retrying with a stale
/// cursor will not work.
class ReorgException extends PrivacyException {
  const ReorgException(super.message);
}

/// The discovery service rejected a request or returned an error status.
class DiscoveryException extends PrivacyException {
  const DiscoveryException(super.message, {this.statusCode, this.errorCode});

  /// HTTP status, when the failure came back as one.
  final int? statusCode;

  /// Service error code, for example `DECRYPTION_FAILED` or `RPC_UNAVAILABLE`.
  final String? errorCode;

  @override
  String toString() {
    final parts = <String>[
      if (statusCode != null) 'HTTP $statusCode',
      if (errorCode != null) errorCode!,
    ];
    final prefix = parts.isEmpty ? '' : '(${parts.join(' ')}) ';
    return 'DiscoveryException: $prefix$message';
  }
}

/// A response could not be parsed into the shape the API contract promises.
class ProtocolException extends PrivacyException {
  const ProtocolException(super.message);
}

/// Not enough shielded balance in a token to cover a spend.
///
/// Distinct from a protocol error: nothing is malformed, the wallet simply does
/// not hold enough. Callers usually want to show this to the user rather than
/// treat it as a failure.
class InsufficientNotesException extends PrivacyException {
  InsufficientNotesException({
    required this.requested,
    required this.available,
    required this.token,
  }) : super(
          'Need $requested but only $available is available in token '
          '0x${token.toRadixString(16)}',
        );

  final BigInt requested;
  final BigInt available;
  final BigInt token;
}

/// JSON-RPC error code the prover returns when it is temporarily overloaded.
const int serviceBusyCode = -32005;

/// Errors from the proving service, carrying the JSON-RPC code so callers can
/// branch on it.
///
/// Codes seen in practice:
/// - `24` block not found
/// - `55` account validation failed
/// - `61` unsupported transaction version
/// - `1000` invalid transaction input
/// - `-32005` service busy, retry later
/// - `-32603` internal prover error
/// - `10000` rejected by the screening interceptor
///
/// Lives here rather than beside the proving client because [PrivacyException]
/// is sealed, which buys callers exhaustive matching over every failure this
/// package can produce.
class ProvingException extends PrivacyException {
  const ProvingException(this.code, super.message, {this.data});

  final int code;
  final String? data;

  /// Whether retrying this request could plausibly succeed.
  bool get isTransient => code == serviceBusyCode;

  @override
  String toString() =>
      'ProvingException($code): $message${data == null ? '' : ': $data'}';
}
