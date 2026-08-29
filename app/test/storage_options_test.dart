/// The one storage option that decides whether a wallet can delete itself.
///
/// flutter_secure_storage defaults `resetOnError` to true, and honours it in
/// the native layer: a failed read goes to `handleStorageError`, which calls
/// `delete(key)` and retries. For the seed that turns a transient Keystore
/// error — an OS update invalidating a key, an app-data restore onto a device
/// without the wrapping key — into permanent loss of funds.
///
/// The bare `AndroidOptions()` that caused this was written under a comment
/// stating that the defaults were correct and that resetOnError was
/// deliberately not set. Both halves were wrong, which is why this asserts the
/// serialized map the plugin actually sends rather than trusting a comment.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/activity/activity_store.dart';
import 'package:tip/src/claim/pending_tips.dart';
import 'package:tip/src/security/app_lock.dart';
import 'package:tip/src/wallet/wallet_store.dart';

void main() {
  final stores = <String, AndroidOptions>{
    'the seed': WalletStore.androidOptionsForTest,
    'the activity log': ActivityStore.androidOptionsForTest,
    'the lock preference': AppLock.androidOptionsForTest,
    'unclaimed tip links': PendingTipsStore.androidOptionsForTest,
  };

  stores.forEach((what, options) {
    test('$what is never deleted on a failed read', () {
      expect(
        options.toMap()['resetOnError'],
        'false',
        reason: '$what would be destroyed by a transient decrypt failure',
      );
    });
  });

  test('the plugin default really is the dangerous one', () {
    // If this ever fails, the plugin changed its default and the comments
    // above can be relaxed. Until then it documents why the explicit false is
    // load-bearing rather than decorative.
    expect(const AndroidOptions().toMap()['resetOnError'], 'true');
  });
}
