/// Persistence for the wallet seed.
///
/// This is the most dangerous file in the app. The seed here is the only thing
/// standing between the user and losing both their money and the ability to
/// read their own transaction history, so the choices below are deliberate and
/// each one is explained.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Reads and writes the wallet seed to platform-encrypted storage.
class WalletStore {
  WalletStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _seedKey = 'tip.seed.v1';

  /// iOS Keychain options.
  ///
  /// `unlocked_this_device` rather than the default `unlocked`: the default
  /// syncs through iCloud Keychain and is restored onto a new device, which for
  /// a wallet seed means the user's key silently propagating to hardware they
  /// may not control. This keeps it on the device it was created on, readable
  /// only while unlocked.
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  );

  /// Android options.
  ///
  /// The Keystore-backed RSA-OAEP + AES-GCM envelope, with `resetOnError`
  /// turned off explicitly.
  ///
  /// It has to be explicit. This comment previously said the defaults were
  /// correct and left the constructor bare; they are not. `resetOnError`
  /// defaults to **true**, and the plugin honours it in the native layer:
  /// `FlutterSecureStorage.java` routes a failed read into `handleStorageError`,
  /// which calls `delete(key)` and retries. A Keystore key invalidated by an OS
  /// update, or an app-data restore onto a device without the wrapping key,
  /// would delete the seed and drop the user into onboarding to create a new
  /// wallet — a transient error turned into permanent loss of funds, which is
  /// the exact outcome the old comment claimed to be avoiding.
  ///
  /// A read that fails now throws, and the caller reports it. That is
  /// recoverable. Deletion is not.
  ///
  /// Biometric gating stays off for a different reason: it would tie the key to
  /// enrolled biometrics, and Android permanently invalidates such keys when the
  /// user adds or removes a fingerprint, which would strand the wallet.
  static const _androidOptions = AndroidOptions(resetOnError: false);

  Future<bool> hasSeed() async =>
      await _storage.read(
        key: _seedKey,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      ) !=
      null;

  Future<String?> readSeedPhrase() => _storage.read(
    key: _seedKey,
    iOptions: _iosOptions,
    aOptions: _androidOptions,
  );

  Future<void> writeSeedPhrase(String mnemonic) => _storage.write(
    key: _seedKey,
    value: mnemonic,
    iOptions: _iosOptions,
    aOptions: _androidOptions,
  );

  /// Erases the seed.
  ///
  /// Must be called explicitly on sign-out. Uninstalling the app does not
  /// reliably clear an iOS Keychain entry, so "delete the app" is not a way for
  /// a user to erase their wallet and the UI should never imply that it is.
  Future<void> deleteSeedPhrase() => _storage.delete(
    key: _seedKey,
    iOptions: _iosOptions,
    aOptions: _androidOptions,
  );
}
