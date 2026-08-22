/// QUIC variable-length integers (RFC 9000 section 16).
///
/// Binary HTTP encodes every length and every numeric field this way, so this
/// is the foundation of the whole OHTTP payload path.
library;

import 'dart:typed_data';

import '../errors.dart';

/// Largest value a varint can carry: 2^62 - 1.
final BigInt maxVarint = (BigInt.one << 62) - BigInt.one;

/// Encodes [value] using the shortest form that fits.
///
/// The top two bits of the first byte give log2 of the total encoded length,
/// so the payload occupies the remaining 6, 14, 30, or 62 bits.
Uint8List encodeVarint(int value) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value', 'Varints cannot be negative');
  }
  if (value <= 63) {
    return Uint8List.fromList([value]);
  }
  if (value <= 16383) {
    return Uint8List.fromList([0x40 | (value >> 8), value & 0xff]);
  }
  if (value <= 1073741823) {
    return Uint8List.fromList([
      0x80 | ((value >> 24) & 0x3f),
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
  }
  if (value <= 4611686018427387903) {
    final out = Uint8List(8);
    var remaining = value;
    for (var i = 7; i >= 0; i--) {
      out[i] = remaining & 0xff;
      remaining >>= 8;
    }
    out[0] |= 0xc0;
    return out;
  }
  throw ArgumentError.value(
    value,
    'value',
    'Varints hold at most 2^62 - 1',
  );
}

/// A decoded varint and the offset just past it.
class VarintRead {
  const VarintRead(this.value, this.offset);

  final int value;
  final int offset;
}

/// Reads a varint from [bytes] starting at [offset].
///
/// Non-minimal encodings are accepted deliberately. RFC 9292 section 3 states
/// that integers need not use the fewest possible bytes, so `0x4025` and `0x25`
/// both decode to 37 and a strict decoder would reject valid messages.
VarintRead decodeVarint(Uint8List bytes, int offset) {
  if (offset >= bytes.length) {
    throw const ProtocolException('Truncated varint: no bytes remaining');
  }
  final first = bytes[offset];
  final length = 1 << (first >> 6);
  if (offset + length > bytes.length) {
    throw ProtocolException(
      'Truncated varint: need $length bytes at offset $offset, '
      'only ${bytes.length - offset} remain',
    );
  }
  var value = first & 0x3f;
  for (var i = 1; i < length; i++) {
    value = (value << 8) | bytes[offset + i];
  }
  return VarintRead(value, offset + length);
}

/// Appends the varint encoding of [value] to [sink].
void writeVarint(BytesBuilder sink, int value) => sink.add(encodeVarint(value));

/// Appends [bytes] prefixed by its varint length.
void writeVarintBytes(BytesBuilder sink, List<int> bytes) {
  writeVarint(sink, bytes.length);
  sink.add(bytes);
}
