/// Keeping a tip link that has been funded.
///
/// A tip link is a bearer instrument: the secret in the URL is the money, and
/// it is the only way to reach it. It used to live in a single `setState` on
/// the tip screen and nowhere else — the activity log stored the claim
/// account's *address*, which names the link but cannot open it. An app killed
/// between funding and copying destroyed the money for everyone, permanently.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/claim/pending_tips.dart';

/// An in-memory stand-in for the keystore, overriding only the two raw
/// accessors so the add/remove/dedupe logic below is the real thing.
class _MemoryStore extends PendingTipsStore {
  String? raw;

  @override
  Future<String?> readRaw() async => raw;

  @override
  Future<void> writeRaw(String value) async => raw = value;
}

PendingTip _tip(String address, {String? link}) => PendingTip(
      link: link ?? 'https://usetip.xyz/claim#secret-for-$address',
      address: address,
      createdAt: DateTime.utc(2026, 8, 29),
      amountLabel: '1 STRK',
    );

void main() {
  late _MemoryStore store;

  setUp(() => store = _MemoryStore());

  test('an empty store reads as empty rather than throwing', () async {
    expect(await store.read(), isEmpty);
  });

  test('a saved link comes back whole, secret included', () async {
    await store.add(_tip('0xaaa'));
    final back = await store.read();
    expect(back, hasLength(1));
    // The secret is the point. An entry that loses it is an entry that names
    // money nobody can reach.
    expect(back.single.link, contains('secret-for-0xaaa'));
    expect(back.single.address, '0xaaa');
    expect(back.single.amountLabel, '1 STRK');
  });

  test('several links are kept, newest first', () async {
    await store.add(_tip('0xaaa'));
    await store.add(_tip('0xbbb'));
    final back = await store.read();
    expect(back.map((t) => t.address).toList(), ['0xbbb', '0xaaa']);
  });

  test('re-adding the same address replaces rather than duplicates', () async {
    // A retried funding must not leave two rows for one tip.
    await store.add(_tip('0xaaa', link: 'first'));
    await store.add(_tip('0xaaa', link: 'second'));
    final back = await store.read();
    expect(back, hasLength(1));
    expect(back.single.link, 'second');
  });

  test('forgetting one leaves the others alone', () async {
    await store.add(_tip('0xaaa'));
    await store.add(_tip('0xbbb'));
    await store.remove('0xaaa');
    final back = await store.read();
    expect(back.map((t) => t.address).toList(), ['0xbbb']);
  });

  test('forgetting something absent is not an error', () async {
    await store.add(_tip('0xaaa'));
    await store.remove('0xzzz');
    expect(await store.read(), hasLength(1));
  });

  test('unreadable stored data reads as empty, not as a crash', () async {
    // A screen that is only trying to list links should not be handed an
    // exception because one byte went wrong.
    store.raw = 'not json at all';
    expect(await store.read(), isEmpty);
  });

  test('it never turns resetOnError back on', () async {
    // The plugin default deletes the entry on a failed read, and this entry is
    // the only copy of a spendable secret.
    expect(PendingTipsStore.androidOptionsForTest.toMap()['resetOnError'],
        'false');
  });
}
