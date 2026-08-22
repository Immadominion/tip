/// HPKE checked against RFC 9180 Appendix A.1, the official test vector for
/// DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-128-GCM in base mode.
///
/// Also covers RFC 5869's HKDF vectors, since a wrong Extract or Expand would
/// otherwise only surface as an unexplained HPKE mismatch.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

Uint8List _hex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('HKDF against RFC 5869', () {
    test('A.1 basic case', () async {
      final prk = await hkdfExtract(
        _hex('000102030405060708090a0b0c'),
        _hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
      );
      expect(
        _toHex(prk),
        equals(
            '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5'),
      );

      final okm = await hkdfExpand(prk, _hex('f0f1f2f3f4f5f6f7f8f9'), 42);
      expect(
        _toHex(okm),
        equals('3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4'
            'c5bf34007208d5b887185865'),
      );
    });

    test('A.3 empty salt and info, the case HPKE relies on', () async {
      final prk = await hkdfExtract(
        const [],
        _hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
      );
      expect(
        _toHex(prk),
        equals(
            '19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04'),
      );

      final okm = await hkdfExpand(prk, const [], 42);
      expect(
        _toHex(okm),
        equals('8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c73'
            '8d2d9d201395faa4b61a96c8'),
      );
    });
  });

  group('suite identifiers', () {
    test('the KEM and HPKE suite ids are distinct and correct', () {
      expect(_toHex(kemSuiteId), equals('4b454d0020'));
      expect(_toHex(hpkeSuiteId), equals('48504b45002000010001'));
    });
  });

  group('RFC 9180 Appendix A.1', () {
    // The RFC's vector, base mode, DHKEM(X25519,HKDF-SHA256)/HKDF-SHA256/
    // AES-128-GCM.
    final info = _hex('4f6465206f6e2061204772656369616e2055726e');
    final ikmE = _hex(
        '7268600d403fce431561aef583ee1613527cff655c1343f29812e66706df3234');
    final ikmR = _hex(
        '6db9df30aa07dd42ee5e8181afdb977e538f5e1fec8a06223f33f7013e525037');
    final pkEm = _hex(
        '37fda3567bdbd628e88668c3c8d7e97d1d1253b6d4ea6d44c150f741f1bf4431');
    final pkRm = _hex(
        '3948cfe0ad1ddb695d780e59077195da6c56506b027329794ab02bca80815c4d');

    test('DeriveKeyPair reproduces the ephemeral public key', () async {
      final keyPair = await deriveKeyPair(ikmE);
      final publicKey = await keyPair.extractPublicKey();
      expect(_toHex(publicKey.bytes), equals(_toHex(pkEm)));
    });

    test('DeriveKeyPair reproduces the recipient public key', () async {
      final keyPair = await deriveKeyPair(ikmR);
      final publicKey = await keyPair.extractPublicKey();
      expect(_toHex(publicKey.bytes), equals(_toHex(pkRm)));
    });

    test('SetupBaseS reproduces every key schedule output', () async {
      final context = await setupBaseSender(
        pkRm: pkRm,
        info: info,
        ephemeral: await deriveKeyPair(ikmE),
      );

      expect(_toHex(context.enc), equals(_toHex(pkEm)));
      expect(_toHex(context.key), equals('4531685d41d65f03dc48f6b8302c05b0'));
      expect(_toHex(context.baseNonce), equals('56d890e5accaaf011cff4b7d'));
      expect(
        _toHex(context.exporterSecret),
        equals(
            '45ff1c2e220db587171952c0592d5f5ebe103f1561a2614e38f2ffd47e99e3f8'),
      );
    });

    test('Seal reproduces the sequence-0 ciphertext', () async {
      final context = await setupBaseSender(
        pkRm: pkRm,
        info: info,
        ephemeral: await deriveKeyPair(ikmE),
      );

      final ciphertext = await context.seal(
        _hex('436f756e742d30'), // aad: "Count-0"
        _hex('4265617574792069732074727574682c20747275746820626561757479'),
      );

      expect(
        _toHex(ciphertext),
        equals('f938558b5d72f1a23810b4be2ab4f84331acc02fc97babc53a52ae8218a3'
            '55a96d8770ac83d07bea87e13c512a'),
      );
    });

    test('the sequence number advances between seals', () async {
      final context = await setupBaseSender(
        pkRm: pkRm,
        info: info,
        ephemeral: await deriveKeyPair(ikmE),
      );

      final first = await context.seal(const [], _hex('00'));
      final second = await context.seal(const [], _hex('00'));

      // Same plaintext, different nonce, so the ciphertexts must differ.
      expect(_toHex(first), isNot(equals(_toHex(second))));
    });
  });

  group('security checks', () {
    test('rejects an all-zero peer public key', () async {
      // A low-order point yields an all-zero shared secret. RFC 9180 section
      // 7.1.4 requires rejecting it, and neither Dart crypto library does.
      await expectLater(
        setupBaseSender(pkRm: Uint8List(32), info: const []),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a public key of the wrong length', () async {
      await expectLater(
        setupBaseSender(pkRm: Uint8List(31), info: const []),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('two setups against the same key produce different enc values',
        () async {
      final pkRm = _hex(
          '3948cfe0ad1ddb695d780e59077195da6c56506b027329794ab02bca80815c4d');
      final a = await setupBaseSender(pkRm: pkRm, info: const []);
      final b = await setupBaseSender(pkRm: pkRm, info: const []);

      // The ephemeral key is fresh per request. If these ever matched, every
      // request from this client would be linkable.
      expect(_toHex(a.enc), isNot(equals(_toHex(b.enc))));
    });
  });

  group('aeadOpen', () {
    test('round-trips against a seal', () async {
      final key = _hex('4531685d41d65f03dc48f6b8302c05b0');
      final nonce = _hex('56d890e5accaaf011cff4b7d');
      final plaintext = _hex('deadbeef');

      final gcm = DartAesGcm.with128bits(nonceLength: 12);
      final box = await gcm.encrypt(
        plaintext,
        secretKey: SecretKey(key),
        nonce: nonce,
        aad: const [],
      );

      final opened = await aeadOpen(
        key: key,
        nonce: nonce,
        aad: const [],
        ciphertextAndTag: Uint8List.fromList(box.concatenation(nonce: false)),
      );
      expect(_toHex(opened), equals(_toHex(plaintext)));
    });

    test('rejects a tampered tag', () async {
      final key = _hex('4531685d41d65f03dc48f6b8302c05b0');
      final nonce = _hex('56d890e5accaaf011cff4b7d');

      final gcm = DartAesGcm.with128bits(nonceLength: 12);
      final box = await gcm.encrypt(
        _hex('deadbeef'),
        secretKey: SecretKey(key),
        nonce: nonce,
        aad: const [],
      );
      final bytes = Uint8List.fromList(box.concatenation(nonce: false));
      bytes[bytes.length - 1] ^= 0x01;

      await expectLater(
        aeadOpen(
          key: key,
          nonce: nonce,
          aad: const [],
          ciphertextAndTag: bytes,
        ),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects input shorter than the tag', () async {
      await expectLater(
        aeadOpen(
          key: Uint8List(16),
          nonce: Uint8List(12),
          aad: const [],
          ciphertextAndTag: Uint8List(8),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
