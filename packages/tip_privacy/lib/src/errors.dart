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
