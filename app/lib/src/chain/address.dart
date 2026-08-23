/// Reading an address a person pasted in.
///
/// The failure this guards against is not a malformed string: those are easy.
/// It is a string that parses cleanly and points somewhere the money cannot
/// come back from. An Ethereum address is valid hex and a valid felt, and a
/// wallet that accepts one sends funds to a Starknet contract that does not
/// exist and never will.
library;

import 'package:starknet/starknet.dart';

class AddressFormatException implements Exception {
  const AddressFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Upper bound for a Starknet contract address, from the protocol.
///
/// Addresses are `2^251 - 256` at most, not the full felt range. A value above
/// this is not an address the sequencer will ever accept.
final addressUpperBound = BigInt.two.pow(251) - BigInt.from(256);

class StarknetAddress {
  StarknetAddress._();

  /// Parses [input], rejecting anything that is not a spendable destination.
  static Felt parse(String input) {
    final cleaned = input.trim().replaceAll(' ', '');

    if (cleaned.isEmpty) {
      throw const AddressFormatException('Enter an address');
    }
    if (!cleaned.startsWith('0x') && !cleaned.startsWith('0X')) {
      throw const AddressFormatException('A Starknet address starts with 0x');
    }

    final digits = cleaned.substring(2);
    if (digits.isEmpty) {
      throw const AddressFormatException('Enter an address');
    }
    if (!_isHex(digits)) {
      throw const AddressFormatException(
        'That address has characters in it that are not hex',
      );
    }
    if (digits.length > 64) {
      throw const AddressFormatException('That address is too long');
    }

    // Exactly forty hex digits is the canonical Ethereum form. A Starknet
    // address that short would need its top twenty-four digits to all be zero
    // by chance, so this is a paste from the wrong chain, not a real address.
    if (digits.length == 40) {
      throw const AddressFormatException(
        'That looks like an Ethereum address. Starknet addresses are longer.',
      );
    }

    final value = BigInt.parse(digits, radix: 16);
    if (value == BigInt.zero) {
      throw const AddressFormatException(
        'The zero address cannot receive anything',
      );
    }
    if (value >= addressUpperBound) {
      throw const AddressFormatException('That is not a Starknet address');
    }

    return Felt(value);
  }

  static Felt? tryParse(String input) {
    try {
      return parse(input);
    } on AddressFormatException {
      return null;
    }
  }

  /// Why [input] is not usable, or null if it is.
  ///
  /// For live validation under a text field, where showing the reason as the
  /// user types is kinder than a rejection at the moment they press send.
  static String? problemWith(String input) {
    try {
      parse(input);
      return null;
    } on AddressFormatException catch (error) {
      return error.message;
    }
  }

  /// Full 64-digit form, which is what explorers and the RPC canonicalise to.
  static String canonical(Felt address) =>
      '0x${address.toBigInt().toRadixString(16).padLeft(64, '0')}';

  /// Shortened for display, keeping both ends.
  ///
  /// Both ends, always. Truncating only the tail lets two different addresses
  /// look identical on screen, which is exactly what an address-substitution
  /// attack needs.
  static String short(Felt address, {int lead = 6, int tail = 4}) {
    final hex = canonical(address);
    return '${hex.substring(0, lead + 2)}...${hex.substring(hex.length - tail)}';
  }
}

bool _isHex(String value) {
  for (final unit in value.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLower = unit >= 0x61 && unit <= 0x66;
    final isUpper = unit >= 0x41 && unit <= 0x46;
    if (!isDigit && !isLower && !isUpper) return false;
  }
  return true;
}
