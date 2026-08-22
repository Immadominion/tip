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
  /// Defaults are correct on v11: the Keystore-backed RSA-OAEP + AES-GCM
  /// envelope. Two things are deliberately *not* set. `resetOnError` would wipe
  /// storage on a decryption failure, turning a transient error into permanent
  /// loss of funds. Biometric gating would tie the key to enrolled biometrics,
  /// and Android permanently invalidates such keys when the user adds or
  /// removes a fingerprint, which would strand the wallet.
  static const _androidOptions = AndroidOptions();

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
