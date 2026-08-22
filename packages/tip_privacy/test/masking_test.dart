/// Verifies additive masking against reference values generated from the Cairo
/// implementation, and round-trips every encrypt/decrypt pair.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/cairo-reference-data.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  final inputs = fixture['inputs'] as Map<String, dynamic>;
  final outputs = fixture['outputs'] as Map<String, dynamic>;

  final sender = _felt(inputs['sender'] as String);
  final recipient = _felt(inputs['recipient'] as String);
  final senderPrivateKey = _felt(inputs['senderPrivateKey'] as String);
  final channelKey = _felt(inputs['channelKey'] as String);
  final token = _felt(inputs['token'] as String);
  final index = inputs['index'] as int;
  final salt = _felt(inputs['salt'] as String);
  final amount = BigInt.from(inputs['amount'] as int);
  final ephemeralSecret = _felt(inputs['ephemeralSecret'] as String);
  final recipientPrivateKey = _felt(inputs['recipientPrivateKey'] as String);
  final recipientPublicKey =
      _felt(inputs['recipientPublicKeyDerived'] as String);
  final auditorPrivateKey = _felt(inputs['auditorPrivateKey'] as String);
  final auditorPublicKey = _felt(inputs['auditorPublicKey'] as String);
  final userAddr = _felt(inputs['userAddr'] as String);
  final userPrivateKey = _felt(inputs['userPrivateKey'] as String);

  group('channel info matches the Cairo reference', () {
    final encrypted = encryptChannelInfo(
      ephemeralSecret: ephemeralSecret,
      recipientPublicKey: recipientPublicKey,
      channelKey: channelKey,
      senderAddr: sender,
    );

    test('ephemeral public key', () {
      expect(
        encrypted.ephemeralPubkey,
        equals(_felt(outputs['encChannelEphemeralPubkey'] as String)),
      );
    });

    test('encrypted channel key', () {
      expect(
        encrypted.encChannelKey,
        equals(_felt(outputs['encChannelKey'] as String)),
      );
    });

    test('encrypted sender address', () {
      expect(
        encrypted.encSenderAddr,
        equals(_felt(outputs['encChannelSenderAddr'] as String)),
      );
    });

    test('round-trips back to the plaintext', () {
      final decrypted = decryptChannelInfo(
        encrypted: encrypted,
        recipientPrivateKey: recipientPrivateKey,
      );
      expect(decrypted.channelKey, equals(channelKey));
      expect(decrypted.senderAddr, equals(sender));
    });
  });

  group('subchannel info matches the Cairo reference', () {
    final encrypted = encryptSubchannelInfo(
      channelKey: channelKey,
      index: index,
      token: token,
      salt: salt,
    );

    test('salt is carried through unchanged', () {
      expect(encrypted.salt,
          equals(_felt(outputs['encSubchannelSalt'] as String)));
    });

    test('encrypted token', () {
      expect(
        encrypted.encToken,
        equals(_felt(outputs['encSubchannelToken'] as String)),
      );
    });

    test('round-trips back to the plaintext', () {
      final decrypted = decryptSubchannelInfo(
        encrypted: encrypted,
        channelKey: channelKey,
        index: index,
      );
      expect(decrypted.token, equals(token));
      expect(decrypted.salt, equals(salt));
    });
  });

  group('outgoing channel info matches the Cairo reference', () {
    final encrypted = encryptOutgoingChannelInfo(
      senderAddr: sender,
      senderPrivateKey: senderPrivateKey,
      index: index,
      salt: salt,
      recipientAddr: recipient,
    );

    test('encrypted recipient address', () {
      expect(
        encrypted.encRecipientAddr,
        equals(_felt(outputs['encOutgoingRecipientAddr'] as String)),
      );
    });

    test('round-trips back to the plaintext', () {
      final decrypted = decryptOutgoingChannelInfo(
        encrypted: encrypted,
        senderAddr: sender,
        senderPrivateKey: senderPrivateKey,
        index: index,
      );
      expect(decrypted.recipientAddr, equals(recipient));
      expect(decrypted.salt, equals(salt));
    });
  });

  group('note amount matches the Cairo reference', () {
    final packed = encryptNoteAmount(
      channelKey: channelKey,
      token: token,
      index: index,
      salt: salt,
      amount: amount,
    );

    test('packed encrypted value', () {
      expect(packed, equals(_felt(outputs['encNoteAmount'] as String)));
    });

    test('round-trips back to the plaintext amount and salt', () {
      final decrypted = decryptNoteAmount(
        encNoteValue: packed,
        channelKey: channelKey,
        token: token,
        index: index,
      );
      expect(decrypted.amount, equals(amount));
      expect(decrypted.salt, equals(salt));
    });

    test('masks modulo 2^128, not the field prime', () {
      // A near-max 128-bit amount must still round-trip. If the modulus were
      // the field prime the packing would overflow into the salt bits.
      final big = twoPow128 - BigInt.from(3);
      final packedBig = encryptNoteAmount(
        channelKey: channelKey,
        token: token,
        index: index,
        salt: salt,
        amount: big,
      );
      final decrypted = decryptNoteAmount(
        encNoteValue: packedBig,
        channelKey: channelKey,
        token: token,
        index: index,
      );
      expect(decrypted.amount, equals(big));
      expect(decrypted.salt, equals(salt));
    });

    test('salt occupies the upper bits of the packed value', () {
      expect(packed ~/ twoPow128, equals(salt));
    });
  });

  group('auditor escrow matches the Cairo reference', () {
    test('encrypted private key', () {
      final encrypted = encryptPrivateKeyToAuditor(
        ephemeralSecret: ephemeralSecret,
        auditorPublicKey: auditorPublicKey,
        privateKey: userPrivateKey,
      );
      expect(
        encrypted.ephemeralPubkey,
        equals(_felt(outputs['encPrivateKeyEphemeralPubkey'] as String)),
      );
      expect(
        encrypted.value,
        equals(_felt(outputs['encPrivateKeyValue'] as String)),
      );
    });

    test('private key round-trips for the auditor', () {
      final encrypted = encryptPrivateKeyToAuditor(
        ephemeralSecret: ephemeralSecret,
        auditorPublicKey: auditorPublicKey,
        privateKey: userPrivateKey,
      );
      expect(
        decryptPrivateKeyFromAuditor(
          encrypted: encrypted,
          auditorPrivateKey: auditorPrivateKey,
        ),
        equals(userPrivateKey),
      );
    });

    test('encrypted user address', () {
      final encrypted = encryptUserAddrToAuditor(
        ephemeralSecret: ephemeralSecret,
        auditorPublicKey: auditorPublicKey,
        userAddr: userAddr,
      );
      expect(
        encrypted.ephemeralPubkey,
        equals(_felt(outputs['encUserAddrEphemeralPubkey'] as String)),
      );
      expect(
        encrypted.value,
        equals(_felt(outputs['encUserAddrValue'] as String)),
      );
    });

    test('user address round-trips for the auditor', () {
      final encrypted = encryptUserAddrToAuditor(
        ephemeralSecret: ephemeralSecret,
        auditorPublicKey: auditorPublicKey,
        userAddr: userAddr,
      );
      expect(
        decryptUserAddrFromAuditor(
          encrypted: encrypted,
          auditorPrivateKey: auditorPrivateKey,
        ),
        equals(userAddr),
      );
    });
  });
}
