/// A [DiscoveryTransport] that carries requests inside Oblivious HTTP.
///
/// Drop-in replacement for [PlainJsonTransport]. The discovery and proving
/// clients are written against the interface, so switching a wallet from
/// plaintext to private transport is a one-line change at construction.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../discovery/transport.dart';
import '../errors.dart';
import 'bhttp.dart';
import 'ohttp.dart';

/// Synthetic origin for the inner request.
///
/// The gateway routes the decapsulated request by path, so the scheme and
/// authority are inert. A fixed reserved-TLD origin (RFC 6761 `.invalid`) keeps
/// whatever outer URL this client happens to be configured with from leaking
/// into the encrypted request, which would otherwise both break routing behind
/// a path-prefixing proxy and reveal deployment details to the gateway.
const String innerRequestOrigin = 'ohttp-target.invalid';

/// Sends discovery and proving requests through an OHTTP gateway.
class OhttpTransport implements DiscoveryTransport {
  OhttpTransport({
    required Uri gatewayUrl,
    Uri? relayUrl,
    Uint8List? pinnedKeyConfig,
    http.Client? client,
  })  : _gatewayUrl = gatewayUrl,
        _relayUrl = relayUrl,
        _pinnedKeyConfig = pinnedKeyConfig,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Where `/ohttp-keys` is fetched from, and where encapsulated requests go
  /// when there is no relay.
  final Uri _gatewayUrl;

  /// Optional relay. When set, encapsulated requests are POSTed here instead,
  /// so the gateway never sees the client's IP. Key configs still come from the
  /// gateway.
  final Uri? _relayUrl;

  /// A key configuration pinned out of band.
  ///
  /// Worth using. Without pinning, the config is fetched over TLS, and anything
  /// terminating that TLS can substitute its own key and read every subsequent
  /// request. Pinning is what makes OHTTP meaningful against a hostile CDN
  /// rather than merely against a passive observer.
  final Uint8List? _pinnedKeyConfig;

  final http.Client _client;
  final bool _ownsClient;

  OhttpKeyConfig? _config;

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) =>
      _send(
        path,
        BinaryHttpRequest(
          method: 'POST',
          scheme: 'https',
          authority: innerRequestOrigin,
          path: path,
          headers: const {'content-type': 'application/json'},
          content: utf8.encode(jsonEncode(body)),
        ),
      );

  @override
  Future<Map<String, dynamic>> get(String path) => _send(
        path,
        BinaryHttpRequest(
          method: 'GET',
          scheme: 'https',
          authority: innerRequestOrigin,
          path: path,
        ),
      );

  Future<Map<String, dynamic>> _send(
    String path,
    BinaryHttpRequest request,
  ) async {
    final config = await _keyConfig();
    final encapsulated =
        await encapsulateRequest(config: config, request: request);

    final target = _relayUrl ?? _gatewayUrl;
    final response = await _client.post(
      target,
      headers: const {'content-type': 'message/ohttp-req'},
      body: encapsulated.body,
    );

    // A decapsulation failure arrives in the clear, since the gateway never got
    // far enough to encrypt a reply. Usually it means the key config rotated
    // under us, so drop the cached one and let the next call re-fetch.
    if (response.statusCode == 422) {
      _config = null;
      throw DiscoveryException(
        'Gateway could not decapsulate the request, its key may have rotated',
        statusCode: 422,
      );
    }

    if (response.statusCode != 200) {
      throw DiscoveryException(
        'OHTTP request to $path failed: ${response.body}',
        statusCode: response.statusCode,
      );
    }

    final inner = await decapsulateResponse(
      context: encapsulated.context,
      body: Uint8List.fromList(response.bodyBytes),
    );

    // The gateway wraps API errors inside the envelope and returns 200 on the
    // outside, so the real status is the inner one. This is the path a reorg
    // actually arrives on.
    return decodeDiscoveryResponse(path, inner.statusCode, inner.body);
  }

  Future<OhttpKeyConfig> _keyConfig() async {
    final cached = _config;
    if (cached != null) return cached;

    final Uint8List raw;
    if (_pinnedKeyConfig != null) {
      raw = _pinnedKeyConfig;
    } else {
      final url = _gatewayUrl.replace(
        path: '${_gatewayUrl.path}/ohttp-keys'.replaceAll('//', '/'),
      );
      final response = await _client.get(url);
      if (response.statusCode != 200) {
        throw DiscoveryException(
          'Could not fetch the OHTTP key configuration',
          statusCode: response.statusCode,
        );
      }
      raw = Uint8List.fromList(response.bodyBytes);
    }

    // Gateways are meant to serve the length-prefixed list form, but some
    // serve a bare configuration. Accept either rather than failing on a
    // deployment detail.
    List<OhttpKeyConfig> configs;
    try {
      configs = OhttpKeyConfig.parseList(raw);
    } on ProtocolException {
      configs = [OhttpKeyConfig.parse(raw)];
    }

    final usable = configs.where((c) => c.supportsOurSuite).toList();
    if (usable.isEmpty) {
      throw const ProtocolException(
        'No key configuration offered a supported HPKE suite',
      );
    }

    return _config = usable.first;
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
