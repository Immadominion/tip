/// The STRK20 domain-separated Poseidon hash suite.
///
/// Ported from `packages/privacy/src/hashes.cairo` in starkware-libs/starknet-privacy,
/// and cross-checked against that repo's Cairo-generated reference vectors.
///
/// Two details are load-bearing and easy to get wrong:
///
/// 1. The protocol hash is a *single* `poseidon_hash_span`, not a double hash.
/// 2. Every signature taking an `index` carries a literal `0` immediately after
///    it, since the index occupies a u256-style low/high pair on the Cairo side.
///
/// Both are reproduced exactly below and covered by tests.
library;

import 'package:starknet/starknet.dart';

import 'short_string.dart';

/// Domain-separation tags, verbatim from the Cairo `domain_separation` module.
class HashTags {
  HashTags._();

  static const channelMarker = 'CHANNEL_MARKER_TAG:V1';
  static const channelKey = 'CHANNEL_KEY_TAG:V1';
  static const subchannelMarker = 'SUBCHANNEL_MARKER_TAG:V1';
  static const subchannelId = 'SUBCHANNEL_ID_TAG:V1';
  static const nullifier = 'NULLIFIER_TAG:V1';
  static const encChannelKey = 'ENC_CHANNEL_KEY_TAG:V1';
  static const encSenderAddr = 'ENC_SENDER_ADDR_TAG:V1';
  static const noteId = 'NOTE_ID_TAG:V1';
  static const encAmount = 'ENC_AMOUNT_TAG:V1';
  static const encToken = 'ENC_TOKEN_TAG:V1';
  static const encPrivateKey = 'ENC_PRIVATE_KEY_TAG:V1';
  static const encUserAddr = 'ENC_USER_ADDR_TAG:V1';
  static const encRecipientAddr = 'ENC_RECIPIENT_ADDR_TAG:V1';
  static const outgoingChannelId = 'OUTGOING_CHANNEL_ID_TAG:V1';
  static const identityKey = 'IDENTITY_KEY_TAG:V1';
}

/// Poseidon hash over a list of felts, matching Cairo's `poseidon_hash_span`.
///
/// Accepts [BigInt], [int], and [String]. Strings are encoded as Cairo short
/// strings, which is how the domain tags enter each hash.
BigInt poseidonHash(List<Object> values) {
  final felts = values.map<BigInt>((value) {
    if (value is BigInt) return value;
    if (value is int) return BigInt.from(value);
    if (value is String) return shortStringToFelt(value);
    throw ArgumentError.value(
      value,
      'values',
      'Expected BigInt, int, or String, got ${value.runtimeType}',
    );
  }).toList();
  return poseidonHasher.hashMany(felts);
}

/// `h(IDENTITY_KEY_TAG, user_addr, user_private_key, contract_address)`
///
/// A pseudonymous handle a helper contract can derive shadow accounts from
/// without learning who the user is.
BigInt computeIdentityKey({
  required BigInt userAddr,
  required BigInt userPrivateKey,
  required BigInt contractAddress,
}) =>
    poseidonHash(
        [HashTags.identityKey, userAddr, userPrivateKey, contractAddress]);

/// `h(CHANNEL_KEY_TAG, sender_addr, sender_private_key, recipient_addr, recipient_public_key)`
BigInt computeChannelKey({
  required BigInt senderAddr,
  required BigInt senderPrivateKey,
  required BigInt recipientAddr,
  required BigInt recipientPublicKey,
}) =>
    poseidonHash([
      HashTags.channelKey,
      senderAddr,
      senderPrivateKey,
      recipientAddr,
      recipientPublicKey,
    ]);

/// `h(CHANNEL_MARKER_TAG, channel_key, sender_addr, recipient_addr, recipient_public_key)`
BigInt computeChannelMarker({
  required BigInt channelKey,
  required BigInt senderAddr,
  required BigInt recipientAddr,
  required BigInt recipientPublicKey,
}) =>
    poseidonHash([
      HashTags.channelMarker,
      channelKey,
      senderAddr,
      recipientAddr,
      recipientPublicKey,
    ]);

/// `h(OUTGOING_CHANNEL_ID_TAG, sender_addr, sender_private_key, index, 0)`
BigInt computeOutgoingChannelId({
  required BigInt senderAddr,
  required BigInt senderPrivateKey,
  required int index,
}) =>
    poseidonHash([
      HashTags.outgoingChannelId,
      senderAddr,
      senderPrivateKey,
      index,
      0,
    ]);

/// `h(SUBCHANNEL_ID_TAG, channel_key, index, 0)`
BigInt computeSubchannelId({
  required BigInt channelKey,
  required int index,
}) =>
    poseidonHash([HashTags.subchannelId, channelKey, index, 0]);

/// `h(SUBCHANNEL_MARKER_TAG, channel_key, recipient_addr, recipient_public_key, token)`
BigInt computeSubchannelMarker({
  required BigInt channelKey,
  required BigInt recipientAddr,
  required BigInt recipientPublicKey,
  required BigInt token,
}) =>
    poseidonHash([
      HashTags.subchannelMarker,
      channelKey,
      recipientAddr,
      recipientPublicKey,
      token,
    ]);

/// `h(NOTE_ID_TAG, channel_key, token, index, 0)`
BigInt computeNoteId({
  required BigInt channelKey,
  required BigInt token,
  required int index,
}) =>
    poseidonHash([HashTags.noteId, channelKey, token, index, 0]);

/// `h(NULLIFIER_TAG, channel_key, token, index, 0, owner_private_key)`
///
/// Spending a note publishes its nullifier, which is what prevents the same
/// note being spent twice without revealing which note it was.
BigInt computeNullifier({
  required BigInt channelKey,
  required BigInt token,
  required int index,
  required BigInt ownerPrivateKey,
}) =>
    poseidonHash([
      HashTags.nullifier,
      channelKey,
      token,
      index,
      0,
      ownerPrivateKey,
    ]);

/// `h(ENC_AMOUNT_TAG, channel_key, token, index, 0, salt)`
BigInt computeEncAmountHash({
  required BigInt channelKey,
  required BigInt token,
  required int index,
  required BigInt salt,
}) =>
    poseidonHash([
      HashTags.encAmount,
      channelKey,
      token,
      index,
      0,
      salt,
    ]);

/// `h(ENC_TOKEN_TAG, channel_key, index, 0, salt)`
BigInt computeEncTokenHash({
  required BigInt channelKey,
  required int index,
  required BigInt salt,
}) =>
    poseidonHash([HashTags.encToken, channelKey, index, 0, salt]);

/// `h(ENC_RECIPIENT_ADDR_TAG, sender_addr, sender_private_key, index, 0, salt)`
BigInt computeEncRecipientAddrHash({
  required BigInt senderAddr,
  required BigInt senderPrivateKey,
  required int index,
  required BigInt salt,
}) =>
    poseidonHash([
      HashTags.encRecipientAddr,
      senderAddr,
      senderPrivateKey,
      index,
      0,
      salt,
    ]);

/// `h(ENC_PRIVATE_KEY_TAG, shared_x)`
BigInt computeEncPrivateKeyHash(BigInt sharedX) =>
    poseidonHash([HashTags.encPrivateKey, sharedX]);

/// `h(ENC_USER_ADDR_TAG, shared_x)`
BigInt computeEncUserAddrHash(BigInt sharedX) =>
    poseidonHash([HashTags.encUserAddr, sharedX]);

/// `h(ENC_CHANNEL_KEY_TAG, shared_x)`
BigInt computeEncChannelKeyHash(BigInt sharedX) =>
    poseidonHash([HashTags.encChannelKey, sharedX]);

/// `h(ENC_SENDER_ADDR_TAG, shared_x)`
BigInt computeEncSenderAddrHash(BigInt sharedX) =>
    poseidonHash([HashTags.encSenderAddr, sharedX]);
