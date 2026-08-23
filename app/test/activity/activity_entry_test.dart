/// The activity log's data model.
///
/// Almost all of this is about surviving bad input. The log is read on every
/// launch, and a single unparseable entry must not cost the user the rest of
/// their history.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/activity/activity_entry.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/token.dart';

final _strk = TipTokens.strk;
final _usdc = TipTokens.usdcMainnet;
final _at = DateTime.utc(2026, 8, 23, 14, 30);

ActivityEntry _send({String amount = '1.5'}) => ActivityEntry.send(
      txHash: '0xabc',
      amount: TokenAmount.parse(amount, _strk),
      counterparty: '0xdef',
      submittedAt: _at,
    );

void main() {
  group('round trip', () {
    test('a send survives encoding and decoding', () {
      final decoded = ActivityEntry.decodeAll(
        ActivityEntry.encodeAll([_send()]),
      ).single;

      expect(decoded.txHash, equals('0xabc'));
      expect(decoded.kind, equals(ActivityKind.send));
      expect(decoded.counterparty, equals('0xdef'));
      expect(decoded.status, equals(ActivityStatus.pending));
      expect(decoded.submittedAt.toUtc(), equals(_at));
      expect(decoded.amountLabel, equals('1.5 STRK'));
    });

    test('a deploy survives, with no amount', () {
      final decoded = ActivityEntry.decodeAll(
        ActivityEntry.encodeAll([
          ActivityEntry.deploy(txHash: '0x1', submittedAt: _at),
        ]),
      ).single;

      expect(decoded.kind, equals(ActivityKind.deploy));
      expect(decoded.amountLabel, isNull);
      expect(decoded.counterparty, isNull);
    });

    test('an exact amount is not rounded by the trip through JSON', () {
      // One wei. A double could not hold this, which is why it is a string.
      final entry = ActivityEntry.send(
        txHash: '0x1',
        amount: TokenAmount(BigInt.one, _strk),
        counterparty: '0x2',
        submittedAt: _at,
      );
      final decoded =
          ActivityEntry.decodeAll(ActivityEntry.encodeAll([entry])).single;
      expect(decoded.rawAmount, equals('1'));
    });

    test('decimals are stored per entry, not looked up later', () {
      // If the registry ever changed USDC's decimals, this old entry must
      // still format the way it did when it was written.
      final entry = ActivityEntry.send(
        txHash: '0x1',
        amount: TokenAmount.parse('2.5', _usdc),
        counterparty: '0x2',
        submittedAt: _at,
      );
      final decoded =
          ActivityEntry.decodeAll(ActivityEntry.encodeAll([entry])).single;
      expect(decoded.tokenDecimals, equals(6));
      expect(decoded.amountLabel, equals('2.5 USDC'));
    });
  });

  group('bad input', () {
    test('one corrupt entry does not take the rest with it', () {
      final good = _send();
      final raw = '[{"nonsense": true}, ${_jsonOf(good)}]';
      expect(ActivityEntry.decodeAll(raw), hasLength(1));
    });

    test('nothing at all decodes to nothing', () {
      expect(ActivityEntry.decodeAll(null), isEmpty);
      expect(ActivityEntry.decodeAll(''), isEmpty);
    });

    test('a garbled blob decodes to nothing rather than throwing', () {
      expect(ActivityEntry.decodeAll('not json'), isEmpty);
      expect(ActivityEntry.decodeAll('{"not": "a list"}'), isEmpty);
    });

    test('an unrecognised status reads as unknown, not as succeeded', () {
      final raw = '[{"tx":"0x1","at":"2026-08-23T14:30:00Z","status":"weird"}]';
      expect(
        ActivityEntry.decodeAll(raw).single.status,
        equals(ActivityStatus.unknown),
      );
    });

    test('an unparseable timestamp drops the entry', () {
      final raw = '[{"tx":"0x1","at":"yesterday"}]';
      expect(ActivityEntry.decodeAll(raw), isEmpty);
    });
  });

  group('status', () {
    test('pending and unknown both count as in flight', () {
      for (final status in ActivityStatus.values) {
        expect(
          _send().copyWith(status: status).isPending,
          equals(
            status == ActivityStatus.pending ||
                status == ActivityStatus.unknown,
          ),
          reason: status.name,
        );
      }
    });

    test('copyWith keeps everything it was not asked to change', () {
      final updated = _send().copyWith(
        status: ActivityStatus.reverted,
        failureReason: 'out of gas',
      );
      expect(updated.txHash, equals('0xabc'));
      expect(updated.amountLabel, equals('1.5 STRK'));
      expect(updated.failureReason, equals('out of gas'));
    });
  });
}

String _jsonOf(ActivityEntry entry) {
  final encoded = ActivityEntry.encodeAll([entry]);
  return encoded.substring(1, encoded.length - 1);
}
