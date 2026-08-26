/// Transport abstraction for talking to the discovery service.
///
/// The service accepts plain JSON on its API paths, and also accepts the same
/// calls encapsulated in Oblivious HTTP through a single gateway endpoint. Both
/// carry identical payloads, so the client is written against this interface and
/// the privacy of the transport is a deployment choice rather than a rewrite.
///
/// [PlainJsonTransport] is fine for development and for talking to a service you
/// operate. Anything handling a real user's viewing key should use the OHTTP
/// transport, because the viewing key travels in the request body and a plain
/// transport exposes it to whatever terminates TLS.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../errors.dart';

/// HTTP 409 is used by the discovery service exclusively to signal a reorg.
const int reorgStatusCode = 409;

/// Statuses that mean the service is briefly unavailable rather than wrong.
///
/// A wallet syncing a balance should ride these out rather than showing the
/// user an error. The live service returns 502 with "please try again in 30
/// seconds" during deploys, and a balance that disappears because a server was
/// restarting is a balance the user stops trusting.
const Set<int> transientStatusCodes = {429, 500, 502, 503, 504};

/// How hard to retry a service that is briefly unavailable.
class DiscoveryRetryPolicy {
  const DiscoveryRetryPolicy({
    this.maxRetries = 3,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 15),
  });

  /// No retries. For tests, and for callers who would rather fail fast.
  static const none = DiscoveryRetryPolicy(maxRetries: 0);

  final int maxRetries;
  final Duration baseDelay;
  final Duration maxDelay;

  /// Backoff before retry [attempt], zero-indexed: 1s, 2s, 4s by default.
  Duration delayFor(int attempt) {
    final scaled = baseDelay * (1 << attempt);
    return scaled > maxDelay ? maxDelay : scaled;
  }
}

/// Sends JSON requests to the discovery service and returns decoded responses.
abstract class DiscoveryTransport {
  /// POSTs [body] to [path] and returns the decoded JSON object.
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body);

  /// GETs [path] and returns the decoded JSON object.
  Future<Map<String, dynamic>> get(String path);

  /// Releases any underlying resources.
  void close();
}

/// Plain JSON over HTTPS, straight to the service's API paths.
class PlainJsonTransport implements DiscoveryTransport {
  PlainJsonTransport({
    required Uri baseUrl,
    http.Client? client,
    this.retryPolicy = const DiscoveryRetryPolicy(),
    Future<void> Function(Duration)? sleep,
  })  : _baseUrl = baseUrl,
        _client = client ?? http.Client(),
        _ownsClient = client == null,
        _sleep = sleep ?? Future<void>.delayed;

  final Uri _baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  final DiscoveryRetryPolicy retryPolicy;
  final Future<void> Function(Duration) _sleep;

  Uri _resolve(String path) =>
      _baseUrl.replace(path: '${_baseUrl.path}$path'.replaceAll('//', '/'));

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) =>
      _withRetry(path, () async {
        final response = await _client.post(
          _resolve(path),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        );
        return (response.statusCode, response.body);
      });

  @override
  Future<Map<String, dynamic>> get(String path) => _withRetry(path, () async {
        final response = await _client.get(_resolve(path));
        return (response.statusCode, response.body);
      });

  /// Sends, and rides out a service that is briefly unavailable.
  ///
  /// Only the statuses that mean "not now" are retried. A reorg, a bad request
  /// and a malformed response are all real answers, and repeating them wastes
  /// the user's time to arrive at the same place.
  Future<Map<String, dynamic>> _withRetry(
    String path,
    Future<(int, String)> Function() send,
  ) async {
    for (var attempt = 0;; attempt++) {
      final (status, body) = await send();
      if (!transientStatusCodes.contains(status) ||
          attempt >= retryPolicy.maxRetries) {
        return _decode(path, status, body);
      }
      await _sleep(retryPolicy.delayFor(attempt));
    }
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

/// Turns a status code and body into a decoded response or the right exception.
///
/// Shared by every transport so that a reorg is reported identically whether it
/// arrived as a plain HTTP status or as the inner status of an OHTTP envelope.
Map<String, dynamic> decodeDiscoveryResponse(
  String path,
  int statusCode,
  String body,
) =>
    _decode(path, statusCode, body);

Map<String, dynamic> _decode(String path, int statusCode, String body) {
  if (statusCode == reorgStatusCode) {
    throw ReorgException('Block reorged during $path: $body');
  }

  if (statusCode != 200) {
    throw DiscoveryException(
      'Request to $path failed: $body',
      statusCode: statusCode,
      errorCode: _errorCodeOf(body),
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw ProtocolException('Response from $path was not valid JSON: $e');
  }

  if (decoded is! Map<String, dynamic>) {
    throw ProtocolException(
      'Response from $path was ${decoded.runtimeType}, expected a JSON object',
    );
  }
  return decoded;
}

/// Best-effort extraction of the service's error code from an error body.
String? _errorCodeOf(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final code = decoded['error_code'] ?? decoded['code'];
      if (code is String) return code;
    }
  } on FormatException {
    // Error bodies are not guaranteed to be JSON; the message is enough.
  }
  return null;
}
