/// Note and channel encryption.
///
/// STRK20 does not use an AEAD anywhere on the client-visible surface. Every
/// encrypted field is masked additively:
///
///     ciphertext = (Poseidon(domain_tag, shared_secret, ...) + plaintext) mod M
///
/// where `M` is the STARK field prime for most fields, but `2^128` for note
/// amounts specifically. Decryption subtracts the same mask.
///
/// This means reaching for a general-purpose crypto library here would be
/// wrong: the scheme has to be reproduced exactly, modulus included, or notes
/// silently fail to decrypt against the live pool.
///
/// Ported from `sdk/src/utils/encryptions.ts` (which mirrors Cairo's
/// `utils.cairo`) in starkware-libs/starknet-privacy.
library;

import 'ecdh.dart';
import 'field.dart';
import 'hashes.dart';

/// `2^128`, the modulus used for note-amount masking.
final BigInt twoPow128 = BigInt.one << 128;

/// Channel info as stored on chain, encrypted to the recipient.
class EncChannelInfo {
  const EncChannelInfo({
    required this.ephemeralPubkey,
    required this.encChannelKey,
    required this.encSenderAddr,
  });

  final BigInt ephemeralPubkey;
  final BigInt encChannelKey;
  final BigInt encSenderAddr;
}

/// Channel info after decryption.
class ChannelInfo {
  const ChannelInfo({required this.channelKey, required this.senderAddr});

  final BigInt channelKey;
  final BigInt senderAddr;
}

/// Subchannel info as stored on chain.
class EncSubchannelInfo {
  const EncSubchannelInfo({required this.salt, required this.encToken});

  final BigInt salt;
  final BigInt encToken;
}

/// Subchannel info after decryption.
class SubchannelInfo {
  const SubchannelInfo({required this.token, required this.salt});

  final BigInt token;
  final BigInt salt;
}

/// Outgoing channel info as stored on chain, readable by the sender.
class EncOutgoingChannelInfo {
  const EncOutgoingChannelInfo({
    required this.salt,
    required this.encRecipientAddr,
  });

  final BigInt salt;
  final BigInt encRecipientAddr;
}

/// Outgoing channel info after decryption.
class OutgoingChannelInfo {
  const OutgoingChannelInfo({required this.recipientAddr, required this.salt});

  final BigInt recipientAddr;
  final BigInt salt;
}

/// A value encrypted to the auditor's key, with the ephemeral public key needed
/// to reproduce the shared secret.
class EncToAuditor {
  const EncToAuditor({required this.ephemeralPubkey, required this.value});

  final BigInt ephemeralPubkey;
  final BigInt value;
}

/// A decrypted note amount together with the salt recovered from its packing.
class NoteAmount {
  const NoteAmount({required this.amount, required this.salt});

  final BigInt amount;
  final BigInt salt;
}

/// Encrypts a channel key and sender address to [recipientPublicKey].
EncChannelInfo encryptChannelInfo({
  required BigInt ephemeralSecret,
  required BigInt recipientPublicKey,
  required BigInt channelKey,
  required BigInt senderAddr,
}) {
  final sharedX = sharedSecretX(ephemeralSecret, recipientPublicKey);
  return EncChannelInfo(
    ephemeralPubkey: derivePublicKey(ephemeralSecret),
    encChannelKey: addMod(computeEncChannelKeyHash(sharedX), channelKey),
    encSenderAddr: addMod(computeEncSenderAddrHash(sharedX), senderAddr),
  );
}

/// Recovers a channel key and sender address using the recipient's private key.
ChannelInfo decryptChannelInfo({
  required EncChannelInfo encrypted,
  required BigInt recipientPrivateKey,
}) {
  final sharedX = sharedSecretX(recipientPrivateKey, encrypted.ephemeralPubkey);
  return ChannelInfo(
    channelKey:
        subMod(encrypted.encChannelKey, computeEncChannelKeyHash(sharedX)),
    senderAddr:
        subMod(encrypted.encSenderAddr, computeEncSenderAddrHash(sharedX)),
  );
}

/// Encrypts the token address of a subchannel.
///
/// Unlike channel info this is a symmetric operation: both sides already hold
/// the channel key, so no ECDH is involved.
EncSubchannelInfo encryptSubchannelInfo({
  required BigInt channelKey,
  required int index,
  required BigInt token,
  required BigInt salt,
}) {
  final mask =
      computeEncTokenHash(channelKey: channelKey, index: index, salt: salt);
  return EncSubchannelInfo(salt: salt, encToken: addMod(mask, token));
}

/// Recovers the token address of a subchannel.
SubchannelInfo decryptSubchannelInfo({
  required EncSubchannelInfo encrypted,
  required BigInt channelKey,
  required int index,
}) {
  final mask = computeEncTokenHash(
    channelKey: channelKey,
    index: index,
    salt: encrypted.salt,
  );
  return SubchannelInfo(
    token: subMod(encrypted.encToken, mask),
    salt: encrypted.salt,
  );
}

/// Encrypts the recipient address of an outgoing channel, readable by the
/// sender so they can reconstruct who they paid.
EncOutgoingChannelInfo encryptOutgoingChannelInfo({
  required BigInt senderAddr,
  required BigInt senderPrivateKey,
  required int index,
  required BigInt salt,
  required BigInt recipientAddr,
}) {
  final mask = computeEncRecipientAddrHash(
    senderAddr: senderAddr,
    senderPrivateKey: senderPrivateKey,
    index: index,
    salt: salt,
  );
  return EncOutgoingChannelInfo(
    salt: salt,
    encRecipientAddr: addMod(mask, recipientAddr),
  );
}

/// Recovers the recipient address of an outgoing channel.
OutgoingChannelInfo decryptOutgoingChannelInfo({
  required EncOutgoingChannelInfo encrypted,
  required BigInt senderAddr,
  required BigInt senderPrivateKey,
  required int index,
}) {
  final mask = computeEncRecipientAddrHash(
    senderAddr: senderAddr,
    senderPrivateKey: senderPrivateKey,
    index: index,
    salt: encrypted.salt,
  );
  return OutgoingChannelInfo(
    recipientAddr: subMod(encrypted.encRecipientAddr, mask),
    salt: encrypted.salt,
  );
}

/// Encrypts a note amount and packs it as `(salt << 128) | enc_amount`.
///
/// Note the modulus: amounts are masked mod `2^128`, not mod the field prime,
/// because the packed felt has to carry the salt in its upper bits.
BigInt encryptNoteAmount({
  required BigInt channelKey,
  required BigInt token,
  required int index,
  required BigInt salt,
  required BigInt amount,
}) {
  final mask = computeEncAmountHash(
    channelKey: channelKey,
    token: token,
    index: index,
    salt: salt,
  );
  final encAmount = (mask + amount) % twoPow128;
  return salt * twoPow128 + encAmount;
}

/// Unpacks and decrypts a note amount, recovering the salt alongside it.
NoteAmount decryptNoteAmount({
  required BigInt encNoteValue,
  required BigInt channelKey,
  required BigInt token,
  required int index,
}) {
  final salt = encNoteValue ~/ twoPow128;
  final encAmount = encNoteValue % twoPow128;
  final mask = computeEncAmountHash(
        channelKey: channelKey,
        token: token,
        index: index,
        salt: salt,
      ) %
      twoPow128;
  final amount = (encAmount + twoPow128 - mask) % twoPow128;
  return NoteAmount(amount: amount, salt: salt);
}

/// Encrypts a private key to the auditor, for the compliance escrow path.
EncToAuditor encryptPrivateKeyToAuditor({
  required BigInt ephemeralSecret,
  required BigInt auditorPublicKey,
  required BigInt privateKey,
}) {
  final sharedX = sharedSecretX(ephemeralSecret, auditorPublicKey);
  return EncToAuditor(
    ephemeralPubkey: derivePublicKey(ephemeralSecret),
    value: addMod(computeEncPrivateKeyHash(sharedX), privateKey),
  );
}

/// Recovers a private key from the auditor escrow, using the auditor's key.
BigInt decryptPrivateKeyFromAuditor({
  required EncToAuditor encrypted,
  required BigInt auditorPrivateKey,
}) {
  final sharedX = sharedSecretX(auditorPrivateKey, encrypted.ephemeralPubkey);
  return subMod(encrypted.value, computeEncPrivateKeyHash(sharedX));
}

/// Encrypts a user address to the auditor, used on withdrawals.
EncToAuditor encryptUserAddrToAuditor({
  required BigInt ephemeralSecret,
  required BigInt auditorPublicKey,
  required BigInt userAddr,
}) {
  final sharedX = sharedSecretX(ephemeralSecret, auditorPublicKey);
  return EncToAuditor(
    ephemeralPubkey: derivePublicKey(ephemeralSecret),
    value: addMod(computeEncUserAddrHash(sharedX), userAddr),
  );
}

/// Recovers a user address from the auditor escrow.
BigInt decryptUserAddrFromAuditor({
  required EncToAuditor encrypted,
  required BigInt auditorPrivateKey,
}) {
  final sharedX = sharedSecretX(auditorPrivateKey, encrypted.ephemeralPubkey);
  return subMod(encrypted.value, computeEncUserAddrHash(sharedX));
}
