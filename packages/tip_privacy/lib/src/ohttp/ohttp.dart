/// Oblivious HTTP (RFC 9458), client side.
///
/// OHTTP encrypts an HTTP request end to end between the client and the
/// gateway, independently of TLS. For this wallet that matters twice over: a
/// relay in front of the gateway sees the client's IP but not the request, and
/// whatever terminates TLS sees neither the viewing key nor the notes coming
/// back.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../errors.dart';
import 'bhttp.dart';
import 'hpke.dart';

/// Length of the response nonce, `max(Nn, Nk)`.
///
/// This is 16 for AES-128-GCM. Writing it as max() rather than Nk keeps the
/// intent right for any other AEAD.
const int responseNonceLength = nN > nK ? nN : nK;

final _requestInfoLabel = ascii.encode('message/bhttp request');
final _responseExportLabel = ascii.encode('message/bhttp response');

/// One HPKE key configuration served by a gateway.
class OhttpKeyConfig {
  const OhttpKeyConfig({
    required this.keyId,
    required this.kemId,
    required this.publicKey,
    required this.symmetricAlgorithms,
  });

  final int keyId;
  final int kemId;
  final Uint8List publicKey;

  /// Supported `(kdfId, aeadId)` pairs, in the gateway's order of preference.
  final List<({int kdfId, int aeadId})> symmetricAlgorithms;

  /// Whether this config offers the one suite this client implements.
  bool get supportsOurSuite =>
      kemId == kemX25519HkdfSha256 &&
      symmetricAlgorithms.any(
        (a) => a.kdfId == kdfHkdfSha256 && a.aeadId == aeadAes128Gcm,
      );

  /// Parses a single bare key configuration (RFC 9458 section 3.1).
  factory OhttpKeyConfig.parse(Uint8List bytes) {
    final (config, consumed) = _parseOne(bytes, 0);
    if (consumed != bytes.length) {
      throw ProtocolException(
        'Key configuration has ${bytes.length - consumed} trailing bytes',
      );
    }
    return config;
  }

  /// Parses an `application/ohttp-keys` document (RFC 9458 section 3.2).
  ///
  /// Each configuration is prefixed by its own two-byte length, with no overall
  /// count or header, so parsing runs to the end of the buffer.
  ///
  /// The RFC requires discarding the whole document on any encoding error
  /// rather than salvaging the entries that did parse, because differences in
  /// how clients recover are themselves a fingerprinting signal. This throws
  /// instead of returning a partial list.
  static List<OhttpKeyConfig> parseList(Uint8List bytes) {
    final configs = <OhttpKeyConfig>[];
    var offset = 0;

    while (offset < bytes.length) {
      if (offset + 2 > bytes.length) {
        throw const ProtocolException(
          'Truncated length prefix in ohttp-keys document',
        );
      }
      final length = (bytes[offset] << 8) | bytes[offset + 1];
      offset += 2;

      if (offset + length > bytes.length) {
        throw ProtocolException(
          'Key configuration claims $length bytes but only '
          '${bytes.length - offset} remain',
        );
      }

      final slice = Uint8List.sublistView(bytes, offset, offset + length);
      final (config, consumed) = _parseOne(slice, 0);
      if (consumed != length) {
        throw const ProtocolException(
          'Key configuration length prefix disagrees with its contents',
        );
      }
      configs.add(config);
      offset += length;
    }

    if (configs.isEmpty) {
      throw const ProtocolException(
        'ohttp-keys document contained no key configurations',
      );
    }
    return configs;
  }

  static (OhttpKeyConfig, int) _parseOne(Uint8List bytes, int offset) {
    int need(int n, String what) {
      if (offset + n > bytes.length) {
        throw ProtocolException('Truncated key configuration reading $what');
      }
      return n;
    }

    need(1, 'key_id');
    final keyId = bytes[offset];
    offset += 1;

    need(2, 'kem_id');
    final kemId = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;

    // The public key has no length prefix; its size is implied by kem_id.
    final publicKeyLength = _publicKeyLengthFor(kemId);
    need(publicKeyLength, 'public_key');
    final publicKey =
        Uint8List.sublistView(bytes, offset, offset + publicKeyLength);
    offset += publicKeyLength;

    need(2, 'symmetric algorithms length');
    final algorithmsLength = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;

    if (algorithmsLength == 0 || algorithmsLength % 4 != 0) {
      throw ProtocolException(
        'Symmetric algorithms length must be a non-zero multiple of 4, '
        'got $algorithmsLength',
      );
    }
    need(algorithmsLength, 'symmetric algorithms');

    final algorithms = <({int kdfId, int aeadId})>[];
    for (var i = 0; i < algorithmsLength; i += 4) {
      algorithms.add((
        kdfId: (bytes[offset + i] << 8) | bytes[offset + i + 1],
        aeadId: (bytes[offset + i + 2] << 8) | bytes[offset + i + 3],
      ));
    }
    offset += algorithmsLength;

    return (
      OhttpKeyConfig(
        keyId: keyId,
        kemId: kemId,
        publicKey: Uint8List.fromList(publicKey),
        symmetricAlgorithms: algorithms,
      ),
      offset,
    );
  }

  static int _publicKeyLengthFor(int kemId) => switch (kemId) {
        0x0010 => 65, // DHKEM(P-256, HKDF-SHA256)
        0x0011 => 97, // DHKEM(P-384, HKDF-SHA384)
        0x0012 => 133, // DHKEM(P-521, HKDF-SHA512)
        0x0020 => 32, // DHKEM(X25519, HKDF-SHA256)
        0x0021 => 56, // DHKEM(X448, HKDF-SHA512)
        _ => throw ProtocolException(
            'Unknown KEM id 0x${kemId.toRadixString(16).padLeft(4, '0')} in '
            'key configuration',
          ),
      };
}

/// An encapsulated request, together with what is needed to open its response.
class EncapsulatedRequest {
  const EncapsulatedRequest({required this.body, required this.context});

  /// The bytes to POST, with content type `message/ohttp-req`.
  final Uint8List body;

  /// Retained so the response can be decapsulated. Single use.
  final HpkeContext context;
}

/// Encapsulates [request] for the gateway described by [config].
///
/// [ephemeral] pins the ephemeral key for tests. Leave it null in production:
/// a fresh key per request is what makes successive requests unlinkable.
Future<EncapsulatedRequest> encapsulateRequest({
  required OhttpKeyConfig config,
  required BinaryHttpRequest request,
  SimpleKeyPair? ephemeral,
}) async {
  if (!config.supportsOurSuite) {
    throw const ProtocolException(
      'Gateway key configuration does not offer '
      'DHKEM(X25519,HKDF-SHA256)/HKDF-SHA256/AES-128-GCM',
    );
  }

  // The seven-byte header is both the wire prefix and the tail of the HPKE
  // info string, so it is built once and used twice.
  final header = Uint8List.fromList([
    config.keyId,
    ...i2osp2(kemX25519HkdfSha256),
    ...i2osp2(kdfHkdfSha256),
    ...i2osp2(aeadAes128Gcm),
  ]);

  final info = Uint8List.fromList([
    ..._requestInfoLabel,
    0x00,
    ...header,
  ]);

  final context = await setupBaseSender(
    pkRm: config.publicKey,
    info: info,
    ephemeral: ephemeral,
  );

  // The header is bound into the ciphertext through `info`, not through AAD,
  // so the AAD here is genuinely empty.
  final ciphertext = await context.seal(const [], request.encode());

  return EncapsulatedRequest(
    body: Uint8List.fromList([...header, ...context.enc, ...ciphertext]),
    context: context,
  );
}

/// Decapsulates a `message/ohttp-res` body using the context from the request.
Future<BinaryHttpResponse> decapsulateResponse({
  required HpkeContext context,
  required Uint8List body,
}) async {
  if (body.length < responseNonceLength + nT) {
    throw ProtocolException(
      'Encapsulated response is ${body.length} bytes, too short to hold a '
      '$responseNonceLength-byte nonce and a $nT-byte tag',
    );
  }

  final responseNonce = Uint8List.sublistView(body, 0, responseNonceLength);
  final ciphertext = Uint8List.sublistView(body, responseNonceLength);

  final secret = await context.export(
    _responseExportLabel,
    responseNonceLength,
  );

  // These are the bare KDF primitives, not the labeled HPKE wrappers. Using
  // LabeledExtract/LabeledExpand here still produces plausible key material
  // and fails only at the final authentication check, which makes it an
  // unusually annoying bug to track down.
  final salt = Uint8List.fromList([...context.enc, ...responseNonce]);
  final prk = await hkdfExtract(salt, secret);
  final key = await hkdfExpand(prk, ascii.encode('key'), nK);
  final nonce = await hkdfExpand(prk, ascii.encode('nonce'), nN);

  final plaintext = await aeadOpen(
    key: key,
    nonce: nonce,
    aad: const [],
    ciphertextAndTag: Uint8List.fromList(ciphertext),
  );

  return BinaryHttpResponse.decode(plaintext);
}

/// Derives an X25519 key pair from a raw 32-byte secret.
///
/// Useful for reproducing published test vectors, which give the secret scalar
/// directly rather than the IKM it was derived from.
Future<SimpleKeyPair> keyPairFromSecret(List<int> secret) =>
    const DartX25519().newKeyPairFromSeed(secret);

/// Generates a cryptographically random response nonce.
///
/// Only the gateway needs this; it is exposed so tests can build a full
/// encapsulated response.
Uint8List randomResponseNonce([Random? random]) {
  final rng = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(responseNonceLength, (_) => rng.nextInt(256)),
  );
}
