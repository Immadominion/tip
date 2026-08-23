/// Address parsing.
///
/// Every case here is one where a user loses money if the wallet is lenient.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/chain/address.dart';

const _real =
    '0x30a7cef4289ca32268279642bfb19fcf924a8b34a919210f79920b366e1d0cc';

void main() {
  group('parse', () {
    test('accepts a real address', () {
      expect(
        StarknetAddress.parse(_real),
        equals(Felt.fromHexString(_real)),
      );
    });

    test('accepts a padded address and a short one alike', () {
      expect(
        StarknetAddress.parse('0x${'0' * 62}ff'),
        equals(Felt.fromInt(255)),
      );
      expect(StarknetAddress.parse('0xff'), equals(Felt.fromInt(255)));
    });

    test('accepts uppercase hex and a 0X prefix', () {
      expect(StarknetAddress.parse('0XFF'), equals(Felt.fromInt(255)));
    });

    test('tolerates surrounding and embedded whitespace from a paste', () {
      expect(
        StarknetAddress.parse('  0x30a7cef4289ca322 68279642bfb19fcf'
            '924a8b34a919210f79920b366e1d0cc  '),
        equals(Felt.fromHexString(_real)),
      );
    });

    test('rejects an empty address', () {
      for (final input in ['', '   ', '0x']) {
        expect(
          () => StarknetAddress.parse(input),
          throwsA(isA<AddressFormatException>()),
          reason: 'accepted "$input"',
        );
      }
    });

    test('rejects a missing 0x, which is how a truncated paste arrives', () {
      expect(
        () => StarknetAddress.parse(
          '30a7cef4289ca32268279642bfb19fcf924a8b34a919210f79920b366e1d0cc',
        ),
        throwsA(isA<AddressFormatException>()),
      );
    });

    test('rejects non-hex characters', () {
      expect(
        () => StarknetAddress.parse('0xdeadbeeg'),
        throwsA(isA<AddressFormatException>()),
      );
    });

    test('rejects an Ethereum address, which is otherwise valid hex', () {
      // This is the one that costs someone money. It parses, it fits in a
      // felt, and nothing on chain will ever give the funds back.
      final vitalik = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
      expect(
        () => StarknetAddress.parse(vitalik),
        throwsA(
          predicate(
            (e) => e is AddressFormatException && e.message.contains('Ethereum'),
          ),
        ),
      );
    });

    test('rejects the zero address', () {
      expect(
        () => StarknetAddress.parse('0x0'),
        throwsA(isA<AddressFormatException>()),
      );
      expect(
        () => StarknetAddress.parse('0x${'0' * 64}'),
        throwsA(isA<AddressFormatException>()),
      );
    });

    test('rejects anything at or above the protocol address bound', () {
      final atBound = '0x${addressUpperBound.toRadixString(16)}';
      expect(
        () => StarknetAddress.parse(atBound),
        throwsA(isA<AddressFormatException>()),
      );
      expect(
        StarknetAddress.parse(
          '0x${(addressUpperBound - BigInt.one).toRadixString(16)}',
        ),
        isNotNull,
      );
    });

    test('rejects more than 64 hex digits', () {
      expect(
        () => StarknetAddress.parse('0x${'1' * 65}'),
        throwsA(isA<AddressFormatException>()),
      );
    });
  });

  group('problemWith', () {
    test('is null for a usable address', () {
      expect(StarknetAddress.problemWith(_real), isNull);
    });

    test('explains what is wrong, in words a user can act on', () {
      expect(StarknetAddress.problemWith('nope'), contains('0x'));
      expect(StarknetAddress.problemWith('0x0'), contains('zero'));
    });
  });

  group('display', () {
    test('canonical pads to the full 64 digits', () {
      final canonical = StarknetAddress.canonical(Felt.fromInt(255));
      expect(canonical.length, equals(66));
      expect(canonical, endsWith('ff'));
      expect(canonical, startsWith('0x0000'));
    });

    test('short keeps both ends, so two addresses cannot look alike', () {
      final a = Felt.fromHexString('0xaaaa000000000000000000000000000000001111');
      final b = Felt.fromHexString('0xaaaa000000000000000000000000000000002222');
      expect(StarknetAddress.short(a), isNot(equals(StarknetAddress.short(b))));
      expect(StarknetAddress.short(a), contains('...'));
    });

    test('canonical round-trips through parse', () {
      final address = Felt.fromHexString(_real);
      expect(
        StarknetAddress.parse(StarknetAddress.canonical(address)),
        equals(address),
      );
    });
  });
}
