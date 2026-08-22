/// HPKE (RFC 9180), base mode, for the one cipher suite Oblivious HTTP needs:
/// DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-128-GCM.
///
/// Only the sender side is implemented, which is all a client does: seal one
/// request, export a secret, open one response.
///
/// The pure-Dart implementations from `package:cryptography` are named
/// explicitly rather than going through the `Cryptography.instance` factories.
/// Those factories resolve to Web Crypto when compiled for web, and this
/// package is meant to stay pure Dart everywhere.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../errors.dart';

const _hmac = DartHmac(DartSha256());
const _x25519 = DartX25519();
final _aesGcm = DartAesGcm.with128bits(nonceLength: 12);

/// DHKEM(X25519, HKDF-SHA256).
const int kemX25519HkdfSha256 = 0x0020;

/// HKDF-SHA256.
const int kdfHkdfSha256 = 0x0001;

/// AES-128-GCM.
const int aeadAes128Gcm = 0x0001;

/// Length of the KEM shared secret, in bytes.
const int nSecret = 32;

/// Length of an X25519 public key, and therefore of `enc`.
const int nEnc = 32;

/// AEAD key length.
const int nK = 16;

/// AEAD nonce length.
const int nN = 12;

/// AEAD tag length.
const int nT = 16;

/// HKDF-SHA256 output length.
const int nH = 32;

final _version = ascii.encode('HPKE-v1');

Uint8List _concat(List<List<int>> parts) {
  final out = Uint8List(parts.fold<int>(0, (sum, p) => sum + p.length));
  var offset = 0;
  for (final part in parts) {
    out.setAll(offset, part);
    offset += part.length;
  }
  return out;
}

/// Big-endian two-byte encoding.
Uint8List i2osp2(int value) =>
    Uint8List.fromList([(value >> 8) & 0xff, value & 0xff]);

/// Suite identifier used inside the KEM: `"KEM" || kem_id`.
///
/// Deliberately a separate constant from [hpkeSuiteId]. Using the wrong one in
/// the wrong phase is the classic HPKE bug, and it fails silently: every value
/// still derives, just to the wrong bytes.
final Uint8List kemSuiteId =
    _concat([ascii.encode('KEM'), i2osp2(kemX25519HkdfSha256)]);

/// Suite identifier used everywhere outside the KEM:
/// `"HPKE" || kem_id || kdf_id || aead_id`.
final Uint8List hpkeSuiteId = _concat([
  ascii.encode('HPKE'),
  i2osp2(kemX25519HkdfSha256),
  i2osp2(kdfHkdfSha256),
  i2osp2(aeadAes128Gcm),
]);

/// HKDF-Extract (RFC 5869): `HMAC(key: salt, message: ikm)`.
Future<Uint8List> hkdfExtract(List<int> salt, List<int> ikm) async {
  final mac = await _hmac.calculateMac(ikm, secretKey: SecretKey(salt));
  return Uint8List.fromList(mac.bytes);
}

/// HKDF-Expand (RFC 5869).
Future<Uint8List> hkdfExpand(
  List<int> prk,
  List<int> info,
  int length,
) async {
  if (length > 255 * nH) {
    throw ArgumentError.value(length, 'length', 'HKDF-Expand output too long');
  }
  final out = Uint8List(length);
  var previous = <int>[];
  var offset = 0;
  for (var counter = 1; offset < length; counter++) {
    final mac = await _hmac.calculateMac(
      _concat([
        previous,
        info,
        [counter]
      ]),
      secretKey: SecretKey(prk),
    );
    previous = mac.bytes;
    final take = (length - offset) < previous.length
        ? (length - offset)
        : previous.length;
    out.setRange(offset, offset + take, previous);
    offset += take;
  }
  return out;
}

/// `LabeledExtract` from RFC 9180 section 4.
///
/// Note that [salt] stays the HMAC key and is not part of the labeled input.
Future<Uint8List> labeledExtract(
  List<int> suiteId,
  List<int> salt,
  String label,
  List<int> ikm,
) =>
    hkdfExtract(salt, _concat([_version, suiteId, ascii.encode(label), ikm]));

/// `LabeledExpand` from RFC 9180 section 4.
///
/// The two-byte output length goes first, before the version label.
Future<Uint8List> labeledExpand(
  List<int> suiteId,
  List<int> prk,
  String label,
  List<int> info,
  int length,
) =>
    hkdfExpand(
      prk,
      _concat([i2osp2(length), _version, suiteId, ascii.encode(label), info]),
      length,
    );

/// `DeriveKeyPair` for DHKEM(X25519, HKDF-SHA256) (RFC 9180 section 7.1.3).
///
/// Uses the KEM suite id, not the HPKE one: a DHKEM always derives with its
/// own associated KDF.
Future<SimpleKeyPair> deriveKeyPair(List<int> ikm) async {
  final dkpPrk = await labeledExtract(kemSuiteId, const [], 'dkp_prk', ikm);
  final sk = await labeledExpand(kemSuiteId, dkpPrk, 'sk', const [], 32);
  return _x25519.newKeyPairFromSeed(sk);
}

/// A set up HPKE sender context.
class HpkeContext {
  HpkeContext({
    required this.enc,
    required this.key,
    required this.baseNonce,
    required this.exporterSecret,
  });

  /// The encapsulated KEM shared secret, sent alongside the ciphertext.
  final Uint8List enc;

  final Uint8List key;
  final Uint8List baseNonce;
  final Uint8List exporterSecret;

  int _sequence = 0;

  /// Nonce for the current sequence number: `base_nonce XOR seq`.
  Uint8List _nonce() {
    final nonce = Uint8List.fromList(baseNonce);
    var remaining = _sequence;
    for (var i = nonce.length - 1; i >= 0 && remaining != 0; i--) {
      nonce[i] ^= remaining & 0xff;
      remaining >>= 8;
    }
    return nonce;
  }

  /// Encrypts [plaintext], returning `ciphertext || tag`.
  Future<Uint8List> seal(List<int> aad, List<int> plaintext) async {
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _nonce(),
      aad: aad,
    );
    _sequence++;
    // package:cryptography keeps the tag separate; the wire format wants it
    // appended.
    return Uint8List.fromList(box.concatenation(nonce: false));
  }

  /// Exports a secret bound to this context (RFC 9180 section 5.3).
  Future<Uint8List> export(List<int> context, int length) =>
      labeledExpand(hpkeSuiteId, exporterSecret, 'sec', context, length);
}

/// `SetupBaseS`: establishes a sender context against recipient key [pkRm].
///
/// [ephemeral] exists so tests can pin the ephemeral key and reproduce the
/// RFC's vectors. Production callers leave it null and get a fresh random key,
/// which is what makes each request unlinkable.
Future<HpkeContext> setupBaseSender({
  required List<int> pkRm,
  required List<int> info,
  SimpleKeyPair? ephemeral,
}) async {
  if (pkRm.length != nEnc) {
    throw ProtocolException(
      'X25519 public key must be $nEnc bytes, got ${pkRm.length}',
    );
  }

  final keyPair = ephemeral ?? await _x25519.newKeyPair();
  final enc = Uint8List.fromList((await keyPair.extractPublicKey()).bytes);

  final sharedSecretKey = await _x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(pkRm, type: KeyPairType.x25519),
  );
  final dh = Uint8List.fromList(await sharedSecretKey.extractBytes());

  // RFC 9180 section 7.1.4 requires rejecting a low-order peer key, which
  // yields an all-zero shared secret. Neither Dart crypto library checks this,
  // and an OHTTP client takes its peer key straight off the network.
  if (dh.every((b) => b == 0)) {
    throw const ProtocolException(
      'X25519 produced an all-zero shared secret: the peer public key is '
      'low-order and must be rejected',
    );
  }

  final kemContext = _concat([enc, pkRm]);
  final eaePrk = await labeledExtract(kemSuiteId, const [], 'eae_prk', dh);
  final sharedSecret = await labeledExpand(
    kemSuiteId,
    eaePrk,
    'shared_secret',
    kemContext,
    nSecret,
  );

  // KeySchedule, mode_base: psk and psk_id are both empty.
  final keyScheduleContext = _concat([
    const [0x00],
    await labeledExtract(hpkeSuiteId, const [], 'psk_id_hash', const []),
    await labeledExtract(hpkeSuiteId, const [], 'info_hash', info),
  ]);

  // The operands invert here relative to every other call in the spec: the
  // shared secret is the salt and the (empty) psk is the input keying material.
  final secret =
      await labeledExtract(hpkeSuiteId, sharedSecret, 'secret', const []);

  return HpkeContext(
    enc: enc,
    key:
        await labeledExpand(hpkeSuiteId, secret, 'key', keyScheduleContext, nK),
    baseNonce: await labeledExpand(
        hpkeSuiteId, secret, 'base_nonce', keyScheduleContext, nN),
    exporterSecret:
        await labeledExpand(hpkeSuiteId, secret, 'exp', keyScheduleContext, nH),
  );
}

/// Decrypts `ciphertext || tag` with an explicit key and nonce.
///
/// Used for the OHTTP response, which is sealed with a key derived outside the
/// HPKE context rather than by the context itself.
Future<Uint8List> aeadOpen({
  required List<int> key,
  required List<int> nonce,
  required List<int> aad,
  required Uint8List ciphertextAndTag,
}) async {
  if (ciphertextAndTag.length < nT) {
    throw const ProtocolException(
      'AEAD ciphertext is shorter than its authentication tag',
    );
  }
  final split = ciphertextAndTag.length - nT;
  try {
    final plaintext = await _aesGcm.decrypt(
      SecretBox(
        Uint8List.sublistView(ciphertextAndTag, 0, split),
        nonce: nonce,
        mac: Mac(Uint8List.sublistView(ciphertextAndTag, split)),
      ),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(plaintext);
  } on SecretBoxAuthenticationError {
    throw const ProtocolException(
      'AEAD authentication failed: the response was corrupted or was '
      'encrypted under a different key',
    );
  }
}
