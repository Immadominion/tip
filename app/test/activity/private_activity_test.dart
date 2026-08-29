/// Private operations in the activity log.
///
/// They were not in it. `ActivityKind` had send, deploy, tip and claim, and the
/// four pool operations wrote nothing at all — which made the one class of
/// transaction that cannot be recovered the one class the log omitted.
///
/// Starknet's RPC cannot be asked which transactions involved an address; that
/// is why this log exists. For a private transfer it is worse than that, since
/// nothing on chain is legible about it in the first place. If the device does
/// not record it, no record of it exists anywhere.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/activity/activity_entry.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/network.dart';

final _token = TipNetwork.sepolia.feeToken;

void main() {
  test('every pool operation has a kind of its own', () {
    // Four distinct operations. Collapsing any two would make the log lie about
    // which one happened.
    expect(
      {
        ActivityKind.register,
        ActivityKind.shield,
        ActivityKind.privateSend,
        ActivityKind.unshield,
      },
      hasLength(4),
    );
  });

  test('the private kinds are marked private and the public ones are not', () {
    expect(ActivityKind.register.isPrivate, isTrue);
    expect(ActivityKind.shield.isPrivate, isTrue);
    expect(ActivityKind.privateSend.isPrivate, isTrue);
    expect(ActivityKind.unshield.isPrivate, isTrue);

    expect(ActivityKind.send.isPrivate, isFalse);
    expect(ActivityKind.deploy.isPrivate, isFalse);
    expect(ActivityKind.tip.isPrivate, isFalse);
    expect(ActivityKind.claim.isPrivate, isFalse);
  });

  test('a pool entry round trips through JSON', () {
    // The kind is stored by name, so a new value has to survive being written
    // and read back or the log silently reclassifies old rows as sends.
    final entry = ActivityEntry.pool(
      txHash: '0xabc',
      kind: ActivityKind.privateSend,
      submittedAt: DateTime.utc(2026, 8, 29, 12),
      amount: TokenAmount.parse('1.5', _token),
      counterparty: '0xdef',
    );

    final back = ActivityEntry.fromJson(entry.toJson());
    expect(back, isNotNull, reason: 'a pool entry must decode at all');
    expect(back?.kind, ActivityKind.privateSend);
    expect(back?.txHash, '0xabc');
    expect(back?.counterparty, '0xdef');
    expect(back?.amountLabel, contains('1.5'));
    expect(back?.status, ActivityStatus.pending);
  });

  test('every kind round trips, not just the one', () {
    for (final kind in ActivityKind.values) {
      final entry = ActivityEntry.pool(
        txHash: '0x1',
        kind: kind,
        submittedAt: DateTime.utc(2026, 8, 29),
      );
      expect(
        ActivityEntry.fromJson(entry.toJson())?.kind,
        kind,
        reason: '$kind must survive a round trip',
      );
    }
  });

  test('a register entry carries no amount, because it moves none', () {
    final entry = ActivityEntry.pool(
      txHash: '0x1',
      kind: ActivityKind.register,
      submittedAt: DateTime.utc(2026, 8, 29),
    );
    expect(entry.amountLabel, isNull);
    // It still has to be pending, so the status sweep picks it up.
    expect(entry.isPending, isTrue);
  });

  test('a shield names no counterparty, because there is nobody to name', () {
    final entry = ActivityEntry.pool(
      txHash: '0x1',
      kind: ActivityKind.shield,
      submittedAt: DateTime.utc(2026, 8, 29),
      amount: TokenAmount.parse('2', _token),
    );
    expect(entry.counterparty, isNull);
    expect(entry.amountLabel, isNotNull);
  });
}
