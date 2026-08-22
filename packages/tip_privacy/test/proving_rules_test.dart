/// The submission conventions, and the failures each one prevents.
library;

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

void main() {
  group('provingBlockFor', () {
    test('backs off ten blocks from the head', () {
      expect(provingBlockFor(1000), equals(990));
      expect(provingBlockFor(10), equals(0));
    });

    test('never returns a block at or near the head', () {
      // Proving at the head is what produces "Note not mature".
      for (final head in [10, 50, 999, 1000000]) {
        expect(head - provingBlockFor(head), equals(provingBlockLag));
      }
    });

    test('refuses a chain too young to have matured notes', () {
      expect(() => provingBlockFor(9), throwsA(isA<ProtocolException>()));
      expect(() => provingBlockFor(0), throwsA(isA<ProtocolException>()));
    });
  });

  group('isProofStillValid', () {
    test('accepts a fresh proof', () {
      expect(
        isProofStillValid(provingBlock: 990, currentBlock: 1000),
        isTrue,
      );
    });

    test('accepts a proof exactly at the validity limit', () {
      expect(
        isProofStillValid(provingBlock: 1000, currentBlock: 1000 + 450),
        isTrue,
      );
    });

    test('rejects a proof one block past the limit', () {
      expect(
        isProofStillValid(provingBlock: 1000, currentBlock: 1000 + 451),
        isFalse,
      );
    });

    test('the standard lag leaves plenty of margin', () {
      // Ten back against a 450 ceiling is deliberately conservative.
      expect(provingBlockLag, lessThan(proofValidityBlocks));
    });
  });

  group('proofFields', () {
    test('omits both keys entirely when there are no facts', () {
      // Passing proof_facts: [] serialises an invalid v3 transaction, so the
      // keys must be absent rather than empty.
      expect(proofFields(proofFacts: const [], proof: 'abc'), isEmpty);
    });

    test('includes both keys when facts are present', () {
      final fields = proofFields(proofFacts: const ['0x1'], proof: 'abc');
      expect(fields['proof_facts'], equals(['0x1']));
      expect(fields['proof'], equals('abc'));
    });

    test('an empty proof string with facts is still included', () {
      // The facts decide, not the proof blob.
      expect(
        proofFields(proofFacts: const ['0x1'], proof: ''),
        containsPair('proof', ''),
      );
    });
  });

  group('requiredTip', () {
    test('is zero but present', () {
      // Zero is valid; absent is not.
      expect(requiredTip, equals('0x0'));
    });
  });

  group('requiresNonceCacheReset', () {
    test('catches the documented failures', () {
      for (final message in [
        'INVALID_NONCE',
        'Transaction execution has failed: INVALID_NONCE',
        'Replacement transaction underpriced',
        'Transaction reverted',
      ]) {
        expect(
          requiresNonceCacheReset(message),
          isTrue,
          reason: '"$message" should force a nonce cache reset',
        );
      }
    });

    test('is case insensitive', () {
      expect(requiresNonceCacheReset('invalid_nonce'), isTrue);
      expect(requiresNonceCacheReset('Revert with reason'), isTrue);
    });

    test('leaves unrelated failures alone', () {
      expect(requiresNonceCacheReset('Service busy'), isFalse);
      expect(requiresNonceCacheReset('Note not mature'), isFalse);
    });
  });
}
