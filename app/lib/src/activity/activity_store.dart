/// Where the activity log lives.
///
/// In the same encrypted keystore as the seed, not in shared preferences. The
/// log is a list of who this wallet paid and when, which is exactly the thing
/// the rest of the product exists to keep private; writing it to plaintext
/// app storage would undo that locally while hiding it on chain.
///
/// It is capped. An unbounded list in a single keystore entry gets slow to
/// read on every launch, and the oldest entries are the least useful.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'activity_entry.dart';

/// How many entries to keep. Roughly a year of ordinary use.
const activityLimit = 200;

class ActivityStore {
  ActivityStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _key = 'tip.activity.v1';

  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  );
  static const _androidOptions = AndroidOptions();

  Future<List<ActivityEntry>> read() async => ActivityEntry.decodeAll(
        await _storage.read(
          key: _key,
          iOptions: _iosOptions,
          aOptions: _androidOptions,
        ),
      );

  Future<void> write(List<ActivityEntry> entries) {
    final capped =
        entries.length <= activityLimit ? entries : entries.sublist(0, activityLimit);
    return _storage.write(
      key: _key,
      value: ActivityEntry.encodeAll(capped),
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  Future<void> clear() => _storage.delete(
        key: _key,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
}
