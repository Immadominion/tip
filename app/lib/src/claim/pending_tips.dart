/// Tip links this wallet has funded, kept until they are known to be claimed.
///
/// A tip link is a bearer instrument: the secret in the URL *is* the money, and
/// it is the only way to reach it. It used to live in a single `setState` on the
/// tip screen and nowhere else. The activity log recorded the claim account's
/// address, which identifies the link but cannot open it, so an app killed
/// between funding the link and copying it destroyed the money with no way back
/// — not for the sender, not for anyone.
///
/// This is written *before* the funding transaction is sent, which is the only
/// ordering that helps. Writing it afterwards leaves the same window open, just
/// narrower.
///
/// The platform keystore, for the same reason the seed is there: the secret
/// here spends money, and it deserves the storage the recovery phrase gets
/// rather than the storage a cache gets.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PendingTip {
  const PendingTip({
    required this.link,
    required this.address,
    required this.createdAt,
    this.amountLabel,
  });

  factory PendingTip.fromJson(Map<String, Object?> json) => PendingTip(
        link: json['link']! as String,
        address: json['address']! as String,
        createdAt: DateTime.parse(json['createdAt']! as String),
        amountLabel: json['amountLabel'] as String?,
      );

  /// The whole claim URL, secret included. This is the part that matters.
  final String link;

  /// The claim account, so an entry can be matched against the chain and
  /// retired once the money has moved.
  final String address;

  final DateTime createdAt;

  /// For display only. Never used to decide anything.
  final String? amountLabel;

  Map<String, Object?> toJson() => {
        'link': link,
        'address': address,
        'createdAt': createdAt.toIso8601String(),
        if (amountLabel != null) 'amountLabel': amountLabel,
      };
}

class PendingTipsStore {
  PendingTipsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _key = 'tip.pending_tips.v1';

  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  );

  /// `resetOnError: false`, like every other store here. The plugin's default
  /// deletes the entry on a failed read, and this entry is the only copy of a
  /// spendable secret.
  static const _androidOptions = AndroidOptions(resetOnError: false);

  /// The raw stored string. Overridden in tests so the list logic below is
  /// exercised for real rather than mocked past.
  @protected
  Future<String?> readRaw() => _storage.read(
        key: _key,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );

  @protected
  Future<void> writeRaw(String value) => _storage.write(
        key: _key,
        value: value,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );

  /// The Android options this store uses, so a test can assert that
  /// `resetOnError` has not drifted back to the plugin's dangerous default.
  static AndroidOptions get androidOptionsForTest => _androidOptions;

  Future<List<PendingTip>> read() async {
    final raw = await readRaw();
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<Object?>;
      return [
        for (final entry in list)
          PendingTip.fromJson(entry! as Map<String, Object?>),
      ];
    } catch (_) {
      // A list that will not parse is not a reason to lose the rest, but there
      // is nothing here to salvage it with either. Report empty rather than
      // throwing into a screen that is only trying to show a list.
      return const [];
    }
  }

  Future<void> _write(List<PendingTip> tips) =>
      writeRaw(jsonEncode([for (final tip in tips) tip.toJson()]));

  /// Records a link before its funding transaction is sent.
  Future<void> add(PendingTip tip) async {
    final tips = await read();
    // Same address means the same link. Replacing rather than appending keeps a
    // retry from leaving two rows for one tip.
    await _write([
      tip,
      ...tips.where((t) => t.address != tip.address),
    ]);
  }

  /// Drops a link once it is known to be claimed or reclaimed.
  Future<void> remove(String address) async {
    final tips = await read();
    await _write(tips.where((t) => t.address != address).toList());
  }

  Future<void> clear() => _storage.delete(
        key: _key,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
}
