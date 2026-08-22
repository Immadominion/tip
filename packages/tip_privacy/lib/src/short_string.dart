/// Cairo short string encoding.
library;

/// Encodes a Cairo short string literal as a felt.
///
/// ASCII bytes packed big-endian, so `'A'` becomes `0x41` and
/// `'CHANNEL_KEY_TAG:V1'` becomes `0x4348414e4e454c5f4b45595f5441473a5631`.
///
/// Every hash in the protocol is domain-separated by one of these tags. Getting
/// this encoding wrong produces a wrong but entirely plausible-looking felt,
/// with no error until on-chain verification rejects the proof, so it is worth
/// keeping isolated and directly tested.
BigInt shortStringToFelt(String value) {
  if (value.length > 31) {
    throw ArgumentError.value(
      value,
      'value',
      'Cairo short strings are at most 31 characters, got ${value.length}',
    );
  }
  var result = BigInt.zero;
  for (final unit in value.codeUnits) {
    // Cairo short strings are 7-bit ASCII. Rejecting anything above that is
    // stricter than the reference implementation, which would happily pack a
    // Latin-1 byte, but a loud failure beats silently encoding a tag that no
    // Cairo contract would ever produce.
    if (unit > 0x7f) {
      throw ArgumentError.value(
        value,
        'value',
        'Cairo short strings must be ASCII',
      );
    }
    result = (result << 8) | BigInt.from(unit);
  }
  return result;
}
