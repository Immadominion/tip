/// What a claim status means.
///
/// The service around it is network-bound and is checked by
/// tool/test_claim_flow.dart against Sepolia. What can be pinned here is the
/// reading of the numbers, and in particular that a link short of its own
/// fees never reports itself as claimable.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/claim/claim_service.dart';

final _strk = TipNetwork.sepolia.feeToken;

TokenAmount _strkOf(String value) => TokenAmount.parse(value, _strk);

void main() {
  test('an empty link is empty and not claimable', () {
    final status = ClaimStatus(
      balance: TokenAmount.zero(_strk),
      deployed: false,
      claimable: TokenAmount.zero(_strk),
    );
    expect(status.isEmpty, isTrue);
    expect(status.canClaim, isFalse);
  });

  test('a funded link with something left over is claimable', () {
    final status = ClaimStatus(
      balance: _strkOf('0.47'),
      deployed: false,
      claimable: _strkOf('0.22'),
    );
    expect(status.isEmpty, isFalse);
    expect(status.canClaim, isTrue);
  });

  test('a link that cannot cover its own fees is not claimable', () {
    // The failure this prevents: telling someone they have money, then
    // reverting when they reach for it.
    final status = ClaimStatus(
      balance: _strkOf('0.01'),
      deployed: false,
      claimable: TokenAmount.zero(_strk),
      shortfall: _strkOf('0.16'),
    );
    expect(status.isEmpty, isFalse);
    expect(status.canClaim, isFalse);
    expect(status.shortfall!.format(), equals('0.16'));
  });

  test('an already deployed account means a claim was interrupted', () {
    final status = ClaimStatus(
      balance: _strkOf('0.3'),
      deployed: true,
      claimable: _strkOf('0.24'),
    );
    expect(status.deployed, isTrue);
    expect(status.canClaim, isTrue);
  });
}
